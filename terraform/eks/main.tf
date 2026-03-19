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
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
  }
}

# ── Variables ─────────────────────────────────────────────────────────────────
variable "aws_region" { type = string }
variable "cluster_name" { type = string }
variable "vpc_cidr" { type = string }
variable "domain" { type = string }
variable "github_org" { type = string }
variable "github_repo" { type = string }
variable "github_token" {
  type      = string
  sensitive = true
}

variable "dns_provider" { type = string }
variable "dns_zone_name" { type = string }
variable "cloudflare_api_token" {
  type      = string
  default   = ""
  sensitive = true
}

# ── Providers ─────────────────────────────────────────────────────────────────
provider "aws" {
  region = var.aws_region
}

provider "github" {
  owner = var.github_org
  token = var.github_token
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

# ── VPC ───────────────────────────────────────────────────────────────────────
module "vpc" {
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

# ── IAM: EBS CSI Driver ───────────────────────────────────────────────────────
module "ebs_csi_irsa_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name             = "${var.cluster_name}-ebs-csi"
  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }
}

# ── EKS ───────────────────────────────────────────────────────────────────────
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = "1.35"

  vpc_id                         = module.vpc.vpc_id
  subnet_ids                     = module.vpc.private_subnets
  cluster_endpoint_public_access = true

  enable_cluster_creator_admin_permissions = true
  authentication_mode                      = "API_AND_CONFIG_MAP"

  # Explicit SG rule management so Terraform revokes cross-references
  # before deleting security groups on destroy — prevents DependencyViolation.
  create_cluster_security_group        = true
  cluster_security_group_additional_rules = {}
  node_security_group_additional_rules    = {}

  cluster_addons = {
    aws-ebs-csi-driver = {
      service_account_role_arn = module.ebs_csi_irsa_role.iam_role_arn
      most_recent              = true
    }
  }

  eks_managed_node_groups = {
    # Single-AZ node group for stateful workloads (ArangoDB).
    # Pinned to private_subnets[0] so EBS volumes always colocate with pods.
    stateful = {
      instance_types = ["t4g.medium", "t4g.large", "m6g.medium"]
      ami_type       = "BOTTLEROCKET_ARM_64"
      capacity_type  = "ON_DEMAND"
      min_size       = 1
      max_size       = 1
      desired_size   = 1

      subnet_ids = [module.vpc.private_subnets[0]]

      labels = {
        workload-type = "stateful"
      }
    }

    # Multi-AZ node group for stateless workloads (frontend, backend, controllers).
    # Spread across both AZs for better Spot availability.
    stateless = {
      instance_types = ["t4g.medium", "t4g.large", "m6g.medium"]
      ami_type       = "BOTTLEROCKET_ARM_64"
      capacity_type  = "SPOT"
      min_size       = 2
      max_size       = 4
      desired_size   = 2

      subnet_ids = module.vpc.private_subnets
    }
  }
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
      identifiers = [module.eks.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:sub"
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

# ── IAM: ExternalDNS (Only for Route 53) ──────────────────────────────────────
data "aws_route53_zone" "this" {
  count        = var.dns_provider == "route53" ? 1 : 0
  name         = var.dns_zone_name
  private_zone = false
}

module "external_dns_irsa_role" {
  count   = var.dns_provider == "route53" ? 1 : 0
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name                     = "${var.cluster_name}-external-dns"
  attach_external_dns_policy    = true
  external_dns_hosted_zone_arns = [data.aws_route53_zone.this[0].arn]

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:external-dns"]
    }
  }
}

# ── ACM Certificate & Validation ──────────────────────────────────────────────
resource "aws_acm_certificate" "app" {
  domain_name       = var.domain
  validation_method = "DNS"
  lifecycle { create_before_destroy = true }
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.app.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    } if var.dns_provider == "route53"
  }

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = data.aws_route53_zone.this[0].zone_id
}

data "cloudflare_zone" "this" {
  count = var.dns_provider == "cloudflare" ? 1 : 0
  name  = var.dns_zone_name
}

resource "cloudflare_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.app.domain_validation_options : dvo.domain_name => {
      name   = trimsuffix(dvo.resource_record_name, ".")
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    } if var.dns_provider == "cloudflare"
  }

  zone_id = data.cloudflare_zone.this[0].id
  name    = each.value.name
  content = each.value.record
  type    = each.value.type
  proxied = false
}

resource "aws_acm_certificate_validation" "app" {
  certificate_arn = aws_acm_certificate.app.arn
  validation_record_fqdns = var.dns_provider == "route53" ? [
    for record in aws_route53_record.cert_validation : record.fqdn
  ] : [
    for record in cloudflare_record.cert_validation : record.hostname
  ]
}

# ── ExternalDNS HelmRelease Generator ─────────────────────────────────────────
locals {
  ext_dns_r53 = <<-YAML
    apiVersion: helm.toolkit.fluxcd.io/v2
    kind: HelmRelease
    metadata:
      name: external-dns
      namespace: flux-system
    spec:
      interval: 5m
      targetNamespace: kube-system
      chart:
        spec:
          chart: external-dns
          version: ">=1.14.0"
          sourceRef:
            kind: HelmRepository
            name: external-dns
            namespace: flux-system
      install:
        createNamespace: true
      values:
        provider: aws
        aws:
          zoneType: public
        txtOwnerId: ${var.cluster_name}
        serviceAccount:
          create: true
          name: external-dns
          annotations:
            eks.amazonaws.com/role-arn: ${try(module.external_dns_irsa_role[0].iam_role_arn, "")}
  YAML

  ext_dns_cf = <<-YAML
    apiVersion: helm.toolkit.fluxcd.io/v2
    kind: HelmRelease
    metadata:
      name: external-dns
      namespace: flux-system
    spec:
      interval: 5m
      targetNamespace: kube-system
      chart:
        spec:
          chart: external-dns
          version: ">=1.14.0"
          sourceRef:
            kind: HelmRepository
            name: external-dns
            namespace: flux-system
      install:
        createNamespace: true
      values:
        provider: cloudflare
        txtOwnerId: ${var.cluster_name}
        env:
          - name: CF_API_TOKEN
            valueFrom:
              secretKeyRef:
                name: pdvd-secrets
                key: cloudflare.apiToken
  YAML
}

resource "local_file" "external_dns_helmrelease" {
  filename = "${path.module}/../../clusters/eks/flux-system/external-dns-helmrelease.yaml"
  content  = var.dns_provider == "route53" ? local.ext_dns_r53 : local.ext_dns_cf
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

# ── pdvd values.yaml — non-sensitive fields only ──────────────────────────────
# Sensitive fields (baseUrl, github.appId, github.clientId, github.clientSecret,
# github.privateKey, rbac_repo_token, smtp.*) are injected via valuesFrom in
# the HelmRelease referencing the SOPS-decrypted pdvd-secrets Secret.
resource "local_file" "pdvd_values" {
  filename = "${path.module}/../../clusters/eks/pdvd/values.yaml"
  content  = <<-YAML
    # Auto-generated by Terraform — non-sensitive values only.
    # Sensitive values are merged at runtime from the pdvd-secrets SOPS secret
    # via valuesFrom in clusters/eks/pdvd/helmrelease.yaml.
    pdvd-arangodb:
      cloudProvider: "eks"

    pdvd-frontend:
      ingress:
        enabled: true
        type: alb
        host: ${var.domain}
        certificateArn: ${aws_acm_certificate_validation.app.certificate_arn}
        subnets: "${join(",", module.vpc.public_subnets)}"
      graphqlEndpoint: "https://${var.domain}/api/v1/graphql"
      restapiEndpoint: "https://${var.domain}/api/v1"

    pdvd-backend:
      ingress:
        enabled: true
        type: alb
        host: ${var.domain}
        certificateArn: ${aws_acm_certificate_validation.app.certificate_arn}
        subnets: "${join(",", module.vpc.public_subnets)}"
      rbac_repo: https://github.com/${var.github_org}/pdvd-rbac
      apiBaseUrl: https://${var.domain}/api
      github:
        appName: pdvd
        org: ${var.github_org}
  YAML

  depends_on = [aws_acm_certificate_validation.app, null_resource.git_pull]
}

# ── pdvd HelmRelease — wires valuesFrom to the SOPS-decrypted secret ─────────
resource "local_file" "pdvd_helmrelease" {
  filename = "${path.module}/../../clusters/eks/pdvd/helmrelease.yaml"
  content  = <<-YAML
    # Auto-generated by Terraform
    apiVersion: helm.toolkit.fluxcd.io/v2
    kind: HelmRelease
    metadata:
      name: pdvd
      namespace: flux-system
    spec:
      interval: 5m
      chart:
        spec:
          chart: ./chart/pdvd
          sourceRef:
            kind: GitRepository
            name: flux-system
            namespace: flux-system
      valuesFrom:
        # Sensitive values: baseUrl, rbac_repo_token, github.appId,
        # github.clientId, github.clientSecret, github.privateKey, smtp.*
        - kind: Secret
          name: pdvd-secrets
          valuesKey: values.yaml
      values:
        # Non-sensitive values written here take lower precedence than valuesFrom,
        # but are listed explicitly so the chart's required fields are always visible.
        pdvd-frontend:
          ingress:
            enabled: true
            type: alb
            host: ${var.domain}
            certificateArn: ${aws_acm_certificate_validation.app.certificate_arn}
            subnets: "${join(",", module.vpc.public_subnets)}"
          graphqlEndpoint: "https://${var.domain}/api/v1/graphql"
          restapiEndpoint: "https://${var.domain}/api/v1"

        pdvd-backend:
          ingress:
            enabled: true
            type: alb
            host: ${var.domain}
            certificateArn: ${aws_acm_certificate_validation.app.certificate_arn}
            subnets: "${join(",", module.vpc.public_subnets)}"
          rbac_repo: https://github.com/${var.github_org}/pdvd-rbac
          apiBaseUrl: https://${var.domain}/api
          github:
            appName: pdvd
            org: ${var.github_org}
  YAML

  depends_on = [aws_acm_certificate_validation.app, null_resource.git_pull]
}

locals {
  bootstrap_script = <<-SCRIPT
    #!/usr/bin/env bash
    set -euo pipefail

    REPO_ROOT=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
    cd "$REPO_ROOT"

    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    ARCH=$(uname -m)
    case "$ARCH" in
      x86_64)        ARCH_AMD="amd64" ;;
      arm64|aarch64) ARCH_AMD="arm64" ;;
      *) echo "Unsupported architecture: $ARCH"; exit 1 ;;
    esac

    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║           pdvd-platform EKS Bootstrap                        ║"
    echo "╠══════════════════════════════════════════════════════════════╣"
    echo "║  Cluster : ${var.cluster_name}                               ║"
    echo "║  Region  : ${var.aws_region}                                 ║"
    echo "║  Repo    : ${var.github_org}/${var.github_repo}              ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""

    SECRETS_FILE="$REPO_ROOT/clusters/eks/pdvd/secrets.enc.yaml"
    if [ ! -f "$SECRETS_FILE" ]; then
      echo "ERROR: $SECRETS_FILE not found. Run deploy.sh first to encrypt secrets."
      exit 1
    fi

    if ! head -1 "$SECRETS_FILE" | grep -q "^apiVersion:"; then
      echo "ERROR: $SECRETS_FILE appears to be fully encrypted (missing plaintext apiVersion)."
      echo "Delete it and re-run deploy.sh to re-encrypt with --encrypted-regex."
      exit 1
    fi

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

    git add .
    if ! git diff --cached --quiet; then
      git commit -m "chore(eks): update pdvd values and helmrelease with infrastructure outputs"
      git push --set-upstream origin main
      echo "Pushed values.yaml and helmrelease.yaml updates"
    fi

    echo "Updating kubeconfig..."
    aws eks update-kubeconfig --name ${var.cluster_name} --region ${var.aws_region}

    echo "Waiting for EKS IAM Authenticator to sync..."
    for i in $(seq 1 20); do
      if kubectl get namespace kube-system &>/dev/null; then
        echo "✓ API reachable and authenticated."
        break
      fi
      echo "Attempt $i/20 — API unauthorized or unreachable, retrying in 10s..."
      sleep 10
    done

    echo "Waiting for nodes to be ready..."
    for i in $(seq 1 30); do
      if kubectl wait --for=condition=Ready nodes --all --timeout=30s 2>/dev/null; then
        echo "✓ Nodes ready."
        break
      fi
      echo "Attempt $i/30 — nodes not ready yet, retrying in 10s..."
      sleep 10
    done

    flux bootstrap github \
      --owner=${var.github_org} \
      --repository=${var.github_repo} \
      --branch=main \
      --path=clusters/eks \
      --personal \
      --components-extra=image-reflector-controller,image-automation-controller
  SCRIPT
}

resource "local_file" "bootstrap_script" {
  filename        = "${path.module}/bootstrap.sh"
  content         = local.bootstrap_script
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
    local_file.pdvd_helmrelease,
    local_file.external_dns_helmrelease,
    null_resource.sops_age_secret_pre_bootstrap,
    module.ebs_csi_irsa_role
  ]
}


# ── Outputs ───────────────────────────────────────────────────────────────────
output "cluster_name"            { value = var.cluster_name }
output "cluster_endpoint"        { value = module.eks.cluster_endpoint }
output "vpc_id"                  { value = module.vpc.vpc_id }
output "public_subnet_ids"       { value = module.vpc.public_subnets }
output "alb_controller_role_arn" { value = aws_iam_role.alb_controller.arn }
output "acm_certificate_arn"     { value = aws_acm_certificate_validation.app.certificate_arn }

output "external_dns_role_arn" {
  value = var.dns_provider == "route53" ? module.external_dns_irsa_role[0].iam_role_arn : null
}