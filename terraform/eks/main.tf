terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    github = {
      source  = "integrations/github"
      version = "~> 6.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

# ── Variables ─────────────────────────────────────────────────────────────────
variable "aws_region"   { default = "us-east-1" }
variable "cluster_name" { default = "pdvd-eks" }
variable "vpc_cidr"     { default = "10.0.0.0/16" }
variable "domain"       { default = "app.deployhub.com" }

variable "github_org"  { default = "ortelius" }
variable "github_repo" { default = "pdvd-platform" }
variable "github_token" {
  description = "GitHub PAT with repo + admin:public_key scopes"
  type        = string
  sensitive   = true
}

# ── Providers ─────────────────────────────────────────────────────────────────
provider "aws" {
  region = var.aws_region
}

provider "github" {
  owner = var.github_org
  token = var.github_token
}

# Get the current IAM user/role running Terraform
data "aws_caller_identity" "current" {}

# ── Check if cluster already exists via AWS CLI ───────────────────────────────
data "external" "cluster_check" {
  program = ["bash", "-c", <<-CMD
    STATUS=$(aws eks describe-cluster --name ${var.cluster_name} --region ${var.aws_region} \
      --query 'cluster.status' --output text 2>/dev/null || echo "NOT_FOUND")
    if [ "$STATUS" = "ACTIVE" ]; then
      echo '{"exists":"true"}'
    else
      echo '{"exists":"false"}'
    fi
  CMD
  ]
}

# ── Existing cluster data sources (only queried when cluster exists) ───────────
data "aws_eks_cluster" "existing" {
  count = data.external.cluster_check.result.exists == "true" ? 1 : 0
  name  = var.cluster_name
}

data "aws_vpc" "existing" {
  count = data.external.cluster_check.result.exists == "true" ? 1 : 0
  tags  = { Name = "${var.cluster_name}-vpc" }
}

data "aws_subnets" "existing_public" {
  count = data.external.cluster_check.result.exists == "true" ? 1 : 0
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.existing[0].id]
  }
  tags = { "kubernetes.io/role/elb" = "1" }
}

# ── Locals to unify references regardless of whether cluster pre-existed ───────
locals {
  cluster_exists    = data.external.cluster_check.result.exists == "true"
  cluster_endpoint  = local.cluster_exists ? data.aws_eks_cluster.existing[0].endpoint                      : module.eks[0].cluster_endpoint
  cluster_ca        = local.cluster_exists ? data.aws_eks_cluster.existing[0].certificate_authority[0].data : module.eks[0].cluster_certificate_authority_data
  cluster_oidc_url  = local.cluster_exists ? data.aws_eks_cluster.existing[0].identity[0].oidc[0].issuer    : module.eks[0].cluster_oidc_issuer_url
  vpc_id            = local.cluster_exists ? data.aws_vpc.existing[0].id                                    : module.vpc[0].vpc_id
  public_subnet_ids = local.cluster_exists ? data.aws_subnets.existing_public[0].ids                        : module.vpc[0].public_subnets

  oidc_provider_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${replace(local.cluster_oidc_url, "https://", "")}"

  bootstrap_script = <<-SCRIPT
    #!/usr/bin/env bash
    set -euo pipefail

    REPO_ROOT=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
    cd "$REPO_ROOT"

    # Detect OS and architecture
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    ARCH=$(uname -m)
    case "$ARCH" in
      x86_64)        ARCH_AMD="amd64" ;;
      arm64|aarch64) ARCH_AMD="arm64" ;;
      *) echo "Unsupported architecture: $ARCH"; exit 1 ;;
    esac

    # ── Banner ────────────────────────────────────────────────────────────
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║           pdvd-platform EKS Bootstrap                       ║"
    echo "╠══════════════════════════════════════════════════════════════╣"
    echo "║  Cluster : CLUSTER_NAME                                      ║"
    echo "║  Region  : AWS_REGION                                        ║"
    echo "║  Repo    : GITHUB_ORG/GITHUB_REPO                           ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""

    # ── Validate secrets.enc.yaml ─────────────────────────────────────────
    SECRETS_FILE="$REPO_ROOT/clusters/eks/pdvd/secrets.enc.yaml"
    if [ ! -f "$SECRETS_FILE" ]; then
      echo "ERROR: $SECRETS_FILE not found."
      exit 1
    fi
    if ! grep -q "^sops:" "$SECRETS_FILE"; then
      echo "ERROR: $SECRETS_FILE exists but does not appear to be SOPS-encrypted."
      exit 1
    fi

    # ── Install missing CLI tools ─────────────────────────────────────────
    echo "Platform: $OS/$ARCH_AMD"
    if ! command -v aws &>/dev/null; then
      echo "Installing aws CLI..."
      curl -fsSL "https://awscli.amazonaws.com/awscli-exe-$OS-$ARCH_AMD.zip" -o /tmp/awscliv2.zip
      unzip -q /tmp/awscliv2.zip -d /tmp && sudo /tmp/aws/install && rm -rf /tmp/awscliv2.zip /tmp/aws
    fi

    if ! command -v kubectl &>/dev/null; then
      echo "Installing kubectl..."
      KUBECTL_VERSION=$(curl -fsSL https://dl.k8s.io/release/stable.txt)
      curl -fsSL "https://dl.k8s.io/release/$KUBECTL_VERSION/bin/$OS/$ARCH_AMD/kubectl" -o /tmp/kubectl
      chmod +x /tmp/kubectl && sudo mv /tmp/kubectl /usr/local/bin/kubectl
    fi

    if ! command -v flux &>/dev/null; then
      echo "Installing flux CLI..."
      FLUX_VERSION=$(curl -fsSL https://api.github.com/repos/fluxcd/flux2/releases/latest | grep tag_name | cut -d '"' -f4 | tr -d v)
      curl -fsSL "https://github.com/fluxcd/flux2/releases/download/v$FLUX_VERSION/flux_$${FLUX_VERSION}_$${OS}_$${ARCH_AMD}.tar.gz" -o /tmp/flux.tar.gz
      tar -xzf /tmp/flux.tar.gz -C /tmp flux && sudo mv /tmp/flux /usr/local/bin/flux && rm /tmp/flux.tar.gz
    fi

    # ── Commit and push values.yaml ───────────────────────────────────────
    git add .
    if ! git diff --cached --quiet; then
      git commit -m "chore(eks): update pdvd values with infrastructure outputs"
      git push origin main
      echo "Pushed values.yaml updates"
    fi

    # ── Update kubeconfig ─────────────────────────────────────────────────
    echo "Updating kubeconfig..."
    aws eks update-kubeconfig --name CLUSTER_NAME --region AWS_REGION

    # ── Wait for API & Auth to sync ───────────────────────────────────────
    echo "Waiting for EKS IAM Authenticator to sync..."
    for i in $(seq 1 20); do
      if kubectl get namespace kube-system &>/dev/null; then
        echo "✓ API reachable and authenticated."
        break
      fi
      echo "Attempt $i/20 — API unauthorized or unreachable, retrying in 10s..."
      sleep 10
    done

    # ── Wait for nodes ────────────────────────────────────────────────────
    echo "Waiting for nodes to be ready..."
    for i in $(seq 1 30); do
      if kubectl wait --for=condition=Ready nodes --all --timeout=30s 2>/dev/null; then
        echo "✓ Nodes ready."
        break
      fi
      echo "Attempt $i/30 — nodes not ready yet, retrying in 10s..."
      sleep 10
    done

    # ── Bootstrap Flux ────────────────────────────────────────────────────
    flux bootstrap github \
      --owner=GITHUB_ORG \
      --repository=GITHUB_REPO \
      --branch=main \
      --path=clusters/eks \
      --personal \
      --components-extra=image-reflector-controller,image-automation-controller
  SCRIPT
}

# ── VPC (skipped when cluster already exists) ─────────────────────────────────
module "vpc" {
  count   = local.cluster_exists ? 0 : 1
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr

  azs             = ["${var.aws_region}a", "${var.aws_region}c"]
  public_subnets  = ["10.0.1.0/24", "10.0.2.0/24"]
  private_subnets = ["10.0.10.0/24", "10.0.12.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  public_subnet_tags = {
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

# ── EKS (skipped when cluster already exists) ─────────────────────────────────
module "eks" {
  count   = local.cluster_exists ? 0 : 1
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = "1.35"

  vpc_id                         = module.vpc[0].vpc_id
  subnet_ids                     = module.vpc[0].private_subnets
  cluster_endpoint_public_access = true

  # Natively ensures your IAM caller receives K8s Admin permissions
  enable_cluster_creator_admin_permissions = true
  authentication_mode                      = "API_AND_CONFIG_MAP"

  eks_managed_node_groups = {
    default = {
      instance_types = ["t3.small"]
      capacity_type  = "SPOT"
      min_size       = 2
      max_size       = 4
      desired_size   = 2
    }
  }
}

# ── OIDC provider (for ALB controller IRSA role) ─────────────────────────────
data "tls_certificate" "eks" {
  url = local.cluster_oidc_url
}

resource "aws_iam_openid_connect_provider" "eks" {
  count           = local.cluster_exists ? 0 : 1 # Only create if cluster is fresh
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = local.cluster_oidc_url
}

# ── IAM: AWS Load Balancer Controller ─────────────────────────────────────────
resource "aws_iam_policy" "alb_controller" {
  name   = "${var.cluster_name}-alb-controller-policy"
  policy = file("${path.module}/alb-controller-iam-policy.json")
}

data "aws_iam_policy_document" "alb_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${replace(local.cluster_oidc_url, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }
  }
}

resource "aws_iam_role" "alb_controller" {
  name               = "${var.cluster_name}-alb-controller"
  assume_role_policy = data.aws_iam_policy_document.alb_assume.json
}

resource "aws_iam_role_policy_attachment" "alb_controller" {
  role       = aws_iam_role.alb_controller.name
  policy_arn = aws_iam_policy.alb_controller.arn
}

# ── ACM Certificate ───────────────────────────────────────────────────────────
resource "aws_acm_certificate" "app" {
  domain_name       = var.domain
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

# ── Flux Bootstrap ────────────────────────────────────────────────────────────
resource "tls_private_key" "flux" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P384"
}

resource "github_repository_deploy_key" "flux_eks" {
  title      = "flux-eks"
  repository = var.github_repo
  key        = tls_private_key.flux.public_key_openssh
  read_only  = false
}

resource "null_resource" "git_pull" {
  triggers = { always = timestamp() }

  provisioner "local-exec" {
    command = <<-CMD
      REPO_ROOT=$(git -C "${path.module}" rev-parse --show-toplevel)
      cd "$REPO_ROOT"
      git stash || true
      git pull --rebase origin main
      git stash pop || true
    CMD
    environment = { GITHUB_TOKEN = var.github_token }
  }
}

# ── Write clusters/eks/pdvd/values.yaml with resolved infrastructure values ────
resource "local_file" "pdvd_values" {
  filename = "${path.module}/../../clusters/eks/pdvd/values.yaml"
  content  = <<-YAML
    # Auto-generated by Terraform — do not edit manually
    pdvd-frontend:
      ingress:
        enabled: true
        type: alb
        host: ${var.domain}
        certificateArn: ${aws_acm_certificate.app.arn}
        subnets: "${join(",", local.public_subnet_ids)}"

    pdvd-backend:
      ingress:
        enabled: true
        type: alb
        host: ${var.domain}
        certificateArn: ${aws_acm_certificate.app.arn}
        subnets: "${join(",", local.public_subnet_ids)}"
      rbac_repo: https://github.com/${var.github_org}/pdvd-rbac
      apiBaseUrl: https://${var.domain}/api
      github:
        appName: pdvd
        clientId: ""
        org: ${var.github_org}
  YAML

  depends_on = [aws_acm_certificate.app, null_resource.git_pull]
}

resource "local_file" "bootstrap_script" {
  filename        = "${path.module}/bootstrap.sh"
  content         = replace(replace(replace(replace(
    local.bootstrap_script,
    "CLUSTER_NAME", var.cluster_name),
    "AWS_REGION",   var.aws_region),
    "GITHUB_ORG",   var.github_org),
    "GITHUB_REPO",  var.github_repo)
  file_permission = "0755"
}

resource "null_resource" "flux_bootstrap" {
  triggers = {
    cluster_name = var.cluster_name
    github_org   = var.github_org
    github_repo  = var.github_repo
  }

  provisioner "local-exec" {
    command     = local_file.bootstrap_script.filename
    environment = {
      GITHUB_TOKEN       = var.github_token
      AWS_DEFAULT_REGION = var.aws_region
    }
  }

  depends_on = [
    module.eks,
    github_repository_deploy_key.flux_eks,
    local_file.bootstrap_script,
    local_file.pdvd_values,
  ]
}

# ── Outputs ───────────────────────────────────────────────────────────────────
output "cluster_name"            { value = var.cluster_name }
output "cluster_endpoint"        { value = local.cluster_endpoint }
output "vpc_id"                  { value = local.vpc_id }
output "public_subnet_ids"       { value = local.public_subnet_ids }
output "alb_controller_role_arn" { value = aws_iam_role.alb_controller.arn }
output "acm_certificate_arn"     { value = aws_acm_certificate.app.arn }