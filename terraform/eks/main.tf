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

# ── Destroy-time: sweep orphaned VPC dependencies ─────────────────────────────
#
# In the destroy graph (reverse of create):
#   1. module.eks is destroyed first
#   2. This resource is destroyed — the when=destroy provisioner sweeps orphans
#   3. module.vpc is destroyed (clean, no DependencyViolation)
#
resource "terraform_data" "vpc_dependency_sweep" {
  input = module.vpc.vpc_id

  triggers_replace = {
    cluster_name = var.cluster_name
    aws_region   = var.aws_region
    vpc_name_tag = "${var.cluster_name}-vpc"
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["/bin/bash", "-c"]
    command = <<-CMD
      set +e
      REGION="${self.triggers_replace.aws_region}"
      VPC_NAME="${self.triggers_replace.vpc_name_tag}"
      echo ""
      echo "════════ Destroy-time VPC dependency sweep ════════"

      VPC_ID=$(aws ec2 describe-vpcs \
        --region "$REGION" \
        --filters "Name=tag:Name,Values=$VPC_NAME" \
        --query 'Vpcs[0].VpcId' \
        --output text 2>/dev/null)

      if [ -z "$VPC_ID" ] || [ "$VPC_ID" = "None" ]; then
        echo "  VPC not found — nothing to sweep."
        exit 0
      fi
      echo "  VPC: $VPC_ID"

      # ── Pass 1: Detach & delete orphaned ENIs ──────────────────────────────
      echo ""
      echo "  ── Pass 1: ENI cleanup ──"
      ENI_IDS=$(aws ec2 describe-network-interfaces \
        --region "$REGION" \
        --filters "Name=vpc-id,Values=$VPC_ID" \
        --query 'NetworkInterfaces[].NetworkInterfaceId' \
        --output text 2>/dev/null)

      if [ -n "$ENI_IDS" ] && [ "$ENI_IDS" != "None" ]; then
        for ENI_ID in $ENI_IDS; do
          ATTACH_ID=$(aws ec2 describe-network-interfaces \
            --region "$REGION" \
            --network-interface-ids "$ENI_ID" \
            --query 'NetworkInterfaces[0].Attachment.AttachmentId' \
            --output text 2>/dev/null)
          ATTACH_STATUS=$(aws ec2 describe-network-interfaces \
            --region "$REGION" \
            --network-interface-ids "$ENI_ID" \
            --query 'NetworkInterfaces[0].Attachment.Status' \
            --output text 2>/dev/null)

          if [ -n "$ATTACH_ID" ] && [ "$ATTACH_ID" != "None" ] && [ "$ATTACH_STATUS" = "attached" ]; then
            echo "    Detaching $ENI_ID (attachment: $ATTACH_ID)..."
            aws ec2 detach-network-interface \
              --region "$REGION" \
              --attachment-id "$ATTACH_ID" \
              --force 2>/dev/null \
              || echo "      ⚠  Could not detach $ENI_ID"
          fi
        done

        echo "    Waiting 20s for ENI detachments to settle..."
        sleep 20

        for ENI_ID in $ENI_IDS; do
          STATUS=$(aws ec2 describe-network-interfaces \
            --region "$REGION" \
            --network-interface-ids "$ENI_ID" \
            --query 'NetworkInterfaces[0].Status' \
            --output text 2>/dev/null)
          if [ "$STATUS" = "available" ]; then
            echo "    Deleting $ENI_ID..."
            aws ec2 delete-network-interface \
              --region "$REGION" \
              --network-interface-id "$ENI_ID" 2>/dev/null \
              || echo "      ⚠  Could not delete $ENI_ID"
          elif [ -n "$STATUS" ] && [ "$STATUS" != "None" ]; then
            echo "    Skipping $ENI_ID (status: $STATUS)"
          fi
        done
      else
        echo "    No ENIs found."
      fi

      # ── Pass 2: Revoke all SG rules (clears cross-SG references) ──────────
      echo ""
      echo "  ── Pass 2: Revoke SG rules ──"
      ALL_SGS=$(aws ec2 describe-security-groups \
        --region "$REGION" \
        --filters "Name=vpc-id,Values=$VPC_ID" \
        --query 'SecurityGroups[?GroupName!=`default`].GroupId' \
        --output text 2>/dev/null)

      if [ -n "$ALL_SGS" ] && [ "$ALL_SGS" != "None" ]; then
        for SG_ID in $ALL_SGS; do
          echo "    Revoking rules on $SG_ID..."
          INGRESS=$(aws ec2 describe-security-groups \
            --region "$REGION" \
            --group-ids "$SG_ID" \
            --query 'SecurityGroups[0].IpPermissions' \
            --output json 2>/dev/null)
          if [ -n "$INGRESS" ] && [ "$INGRESS" != "[]" ] && [ "$INGRESS" != "null" ]; then
            aws ec2 revoke-security-group-ingress \
              --region "$REGION" \
              --group-id "$SG_ID" \
              --ip-permissions "$INGRESS" 2>/dev/null \
              || echo "      ⚠  Could not revoke ingress on $SG_ID"
          fi

          EGRESS=$(aws ec2 describe-security-groups \
            --region "$REGION" \
            --group-ids "$SG_ID" \
            --query 'SecurityGroups[0].IpPermissionsEgress' \
            --output json 2>/dev/null)
          if [ -n "$EGRESS" ] && [ "$EGRESS" != "[]" ] && [ "$EGRESS" != "null" ]; then
            aws ec2 revoke-security-group-egress \
              --region "$REGION" \
              --group-id "$SG_ID" \
              --ip-permissions "$EGRESS" 2>/dev/null \
              || echo "      ⚠  Could not revoke egress on $SG_ID"
          fi
        done
      else
        echo "    No non-default SGs found."
      fi

      # ── Pass 3: Delete all non-default SGs (with retry) ───────────────────
      echo ""
      echo "  ── Pass 3: Delete SGs ──"
      if [ -n "$ALL_SGS" ] && [ "$ALL_SGS" != "None" ]; then
        MAX_ATTEMPTS=5
        ATTEMPT=1
        REMAINING="$ALL_SGS"

        while [ -n "$REMAINING" ] && [ "$ATTEMPT" -le "$MAX_ATTEMPTS" ]; do
          STILL_REMAINING=""
          for SG_ID in $REMAINING; do
            aws ec2 delete-security-group \
              --region "$REGION" \
              --group-id "$SG_ID" 2>/dev/null
            if [ $? -ne 0 ]; then
              STILL_REMAINING="$STILL_REMAINING $SG_ID"
            else
              echo "    ✓ Deleted $SG_ID"
            fi
          done
          REMAINING=$(echo "$STILL_REMAINING" | xargs)
          if [ -n "$REMAINING" ]; then
            echo "    Attempt $ATTEMPT/$MAX_ATTEMPTS: $(echo $REMAINING | wc -w | tr -d ' ') SGs remaining — retrying in 15s..."
            sleep 15
          fi
          ATTEMPT=$((ATTEMPT + 1))
        done

        if [ -n "$REMAINING" ]; then
          echo "    ⚠  Could not delete: $REMAINING"
          echo "       These may need manual removal before VPC can be deleted."
        fi
      fi

      echo ""
      echo "  ✓ VPC dependency sweep complete."
    CMD

    environment = {
      AWS_DEFAULT_REGION = self.triggers_replace.aws_region
    }
  }
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
  create_cluster_security_group           = true
  cluster_security_group_additional_rules = {}
  node_security_group_additional_rules    = {}

  cluster_addons = {
    aws-ebs-csi-driver = {
      service_account_role_arn = module.ebs_csi_irsa_role.iam_role_arn
      most_recent              = true
    }
  }

  eks_managed_node_groups = {
    default = {
      instance_types = ["t4g.medium"]
      ami_type       = "BOTTLEROCKET_ARM_64"
      capacity_type  = "ON_DEMAND"
      min_size       = 1
      max_size       = 3
      desired_size   = 1

      subnet_ids = module.vpc.private_subnets
    }

    stateful = {
      instance_types = ["t4g.medium"]
      ami_type       = "BOTTLEROCKET_ARM_64"
      capacity_type  = "ON_DEMAND"
      min_size       = 1
      max_size       = 2
      desired_size   = 1

      subnet_ids = [module.vpc.private_subnets[0]]  # us-east-1a only

      labels = {
        "ortelius/workload" = "stateful"
      }
    }
  }

  # Dependency inversion to force EKS to be destroyed before the sweep resource
  depends_on = [terraform_data.vpc_dependency_sweep]
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

  lifecycle {
    create_before_destroy = true
  }
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
      dependsOn:
        - name: aws-load-balancer-controller
          namespace: flux-system
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
      dependsOn:
        - name: aws-load-balancer-controller
          namespace: flux-system
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
                name: ortelius-secrets
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

resource "local_file" "ortelius_values" {
  filename = "${path.module}/../../clusters/eks/ortelius/values.yaml"
  content  = <<-YAML
<<<<<<< Updated upstream
=======
    # Auto-generated by Terraform — non-sensitive values only.
    # Sensitive values are merged at runtime from the ortelius-secrets SOPS secret
    # via valuesFrom in clusters/eks/ortelius/helmrelease.yaml.
>>>>>>> Stashed changes
    arangodb:
      cloudProvider: "eks"
      nodeSelector:
        topology.kubernetes.io/zone: ${var.aws_region}a
      resources:
        requests:
          memory: "512Mi"
          cpu: "250m"
        limits:
          memory: "1.5Gi"
          cpu: "1000m"

    frontend:
      ingress:
        enabled: true
        type: alb
        host: ${var.domain}
        certificateArn: ${aws_acm_certificate_validation.app.certificate_arn}
        subnets: "${join(",", module.vpc.public_subnets)}"
      graphqlEndpoint: "https://${var.domain}/api/v1/graphql"
      restapiEndpoint: "https://${var.domain}/api/v1"

    prtelius:
      ingress:
        enabled: true
        type: alb
        host: ${var.domain}
        certificateArn: ${aws_acm_certificate_validation.app.certificate_arn}
        subnets: "${join(",", module.vpc.public_subnets)}"
      rbac_repo: https://github.com/${var.github_org}/rbac
      apiBaseUrl: https://${var.domain}/api
      github:
        appName: ortelius
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
    echo "║           platform-iac EKS Bootstrap                        ║"
    echo "╠══════════════════════════════════════════════════════════════╣"
    echo "║  Cluster : ${var.cluster_name}                               ║"
    echo "║  Region  : ${var.aws_region}                                 ║"
    echo "║  Repo    : ${var.github_org}/${var.github_repo}              ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""

    SECRETS_FILE="$REPO_ROOT/clusters/eks/ortelius/secrets.enc.yaml"
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
      git commit -m "chore(eks): update ortelius values and helmrelease with infrastructure outputs"
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
    local_file.ortelius_values,
    local_file.external_dns_helmrelease,
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
