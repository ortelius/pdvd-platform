#!/usr/bin/env bash
# deploy.sh — deploy GKE or EKS independently
#
# Usage:
#   ./deploy.sh gke [plan|apply|destroy]
#   ./deploy.sh eks [plan|apply|destroy]
#
# Requires:
#   export TF_VAR_github_token="ghp_..."
#
# GKE also requires:  gcloud auth application-default login
# EKS also requires:  aws configure  (or AWS_* env vars set)

set -euo pipefail

CLUSTER="${1:-}"
ACTION="${2:-apply}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  echo "Usage: $0 <gke|eks> [plan|apply|destroy]"
  exit 1
}

[[ -z "$CLUSTER" ]] && usage
[[ "$CLUSTER" != "gke" && "$CLUSTER" != "eks" ]] && usage
[[ -z "${TF_VAR_github_token:-}" ]] && { echo "ERROR: TF_VAR_github_token is not set"; exit 1; }

WORKDIR="$SCRIPT_DIR/$CLUSTER"

# ── Secrets Setup (Replaces make-secrets.sh) ──────────────────────────────────
setup_secrets() {
  local CLUSTER_NAME
  CLUSTER_NAME=$(grep 'cluster_name' "$WORKDIR/terraform.tfvars" | cut -d'"' -f2)
  local KEY_FILE="$HOME/.ssh/${CLUSTER_NAME}.sops.key"
  local SECRETS_OUT="$SCRIPT_DIR/../clusters/$CLUSTER/pdvd/secrets.enc.yaml"
  local SOPS_YAML="$SCRIPT_DIR/../clusters/.sops.yaml"

  echo ""
  echo "╔══════════════════════════════════════════════════════════════╗"
  echo "║           pdvd-platform Secrets Setup                       ║"
  echo "╠══════════════════════════════════════════════════════════════╣"
  printf "║  Cluster env : %-45s║\n" "$CLUSTER"
  printf "║  Cluster name: %-45s║\n" "$CLUSTER_NAME"
  printf "║  Key file    : %-45s║\n" "$KEY_FILE"
  echo "╚══════════════════════════════════════════════════════════════╝"
  echo ""

  # Install age
  if ! command -v age-keygen &>/dev/null; then
    echo "Installing age..."
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
    AGE_VERSION=$(curl -fsSL https://api.github.com/repos/FiloSottile/age/releases/latest | grep tag_name | cut -d'"' -f4)
    curl -fsSL "https://github.com/FiloSottile/age/releases/download/$AGE_VERSION/age-$AGE_VERSION-$OS-$ARCH.tar.gz" -o /tmp/age.tar.gz
    tar -xzf /tmp/age.tar.gz -C /tmp
    sudo mv /tmp/age/age /usr/local/bin/age
    sudo mv /tmp/age/age-keygen /usr/local/bin/age-keygen
    rm -rf /tmp/age.tar.gz /tmp/age
    echo "✓ age installed"
  else
    echo "✓ age: $(age-keygen --version 2>/dev/null || echo 'installed')"
  fi

  # Install sops
  if ! command -v sops &>/dev/null; then
    echo "Installing sops..."
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
    SOPS_VERSION=$(curl -fsSL https://api.github.com/repos/getsops/sops/releases/latest | grep tag_name | cut -d'"' -f4)
    curl -fsSL "https://github.com/getsops/sops/releases/download/$SOPS_VERSION/sops-$SOPS_VERSION.$OS.$ARCH" -o /tmp/sops
    chmod +x /tmp/sops
    sudo mv /tmp/sops /usr/local/bin/sops
    echo "✓ sops installed"
  else
    echo "✓ sops: $(sops --version 2>/dev/null || echo 'installed')"
  fi

  echo ""

  # Generate age keypair
  if [ -f "$KEY_FILE" ]; then
    echo "✓ Age key already exists: $KEY_FILE"
  else
    echo "Generating age keypair..."
    mkdir -p "$HOME/.ssh"
    age-keygen -o "$KEY_FILE"
    chmod 600 "$KEY_FILE"
    echo ""
    echo "  ┌─────────────────────────────────────────────────────────┐"
    echo "  │  IMPORTANT: Back up this file securely!                 │"
    echo "  │  $KEY_FILE"
    echo "  │  Losing it means losing access to all encrypted secrets │"
    echo "  └─────────────────────────────────────────────────────────┘"
    echo ""
  fi

  AGE_PUBKEY=$(grep "^# public key:" "$KEY_FILE" | awk '{print $4}')
  echo "  Public key: $AGE_PUBKEY"
  echo ""

  # Update .sops.yaml
  cat > "$SOPS_YAML" <<SOPS
creation_rules:
  - path_regex: clusters/eks/.*\.yaml$
    age: $AGE_PUBKEY
  - path_regex: clusters/gke/.*\.yaml$
    age: $AGE_PUBKEY
SOPS
  echo "✓ clusters/.sops.yaml written"
  echo ""

  # Collect and Encrypt Secrets
  if [ ! -f "$SECRETS_OUT" ]; then
    echo "Enter secret values."
    echo "Press Enter after each value."
    echo ""

    read -rp  "  smtp.username                       : " SMTP_USERNAME
    read -rp  "  pdvd-arangodb.arangodb_pass         : " ARANGODB_PASS 
    read -rp  "  pdvd-backend.rbac_repo_token        : " RBAC_REPO_TOKEN
    read -rp  "  pdvd-backend.github.clientSecret    : " GITHUB_CLIENT_SECRET
    read -rp  "  smtp.password                       : " SMTP_PASSWORD

    echo ""
    echo "  pdvd-backend.github.privateKey"
    echo "  Paste the full PEM block, then press Ctrl-D on a new empty line:"
    echo ""
    GITHUB_PRIVATE_KEY=$(cat)
    echo ""

    TMPFILE=$(mktemp /tmp/secrets-XXXXXX.yaml)
    cat > "$TMPFILE" <<YAML
pdvd-arangodb:
    arangodb_pass: "$${ARANGODB_PASS}"
pdvd-backend:
    rbac_repo_token: "$${RBAC_REPO_TOKEN}"
    github:
        clientSecret: "$${GITHUB_CLIENT_SECRET}"
        privateKey: |
$(echo "$GITHUB_PRIVATE_KEY" | sed 's/^/            /')
smtp:
    username: "$${SMTP_USERNAME}"
    password: "$${SMTP_PASSWORD}"
YAML

    echo "Encrypting..."
    SOPS_AGE_RECIPIENTS="$AGE_PUBKEY" sops --encrypt --age "$AGE_PUBKEY" "$TMPFILE" > "$SECRETS_OUT"
    rm -f "$TMPFILE"
    echo "✓ Written: $SECRETS_OUT"
    echo ""

    echo "Verifying decryption..."
    if SOPS_AGE_KEY_FILE="$KEY_FILE" sops --decrypt "$SECRETS_OUT" > /dev/null 2>&1; then
      echo "✓ Decryption verified"
    else
      echo "ERROR: Decryption failed"
      exit 1
    fi
  fi
}

# Run secrets setup immediately before applying
if [[ "$ACTION" == "apply" ]]; then
  setup_secrets
fi

# ── EKS Pre-flight ────────────────────────────────────────────────────────────
if [[ "$CLUSTER" == "eks" && ! -f "$WORKDIR/alb-controller-iam-policy.json" ]]; then
  echo "Downloading ALB controller IAM policy..."
  curl -fsSL -o "$WORKDIR/alb-controller-iam-policy.json" \
    https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json
fi

echo ""
echo "══════════════════════════════════════════"
echo "  Cluster : $CLUSTER"
echo "  Action  : $ACTION"
echo "  Dir     : $WORKDIR"
echo "══════════════════════════════════════════"
echo ""

cd "$WORKDIR"

terraform init -upgrade

case "$ACTION" in
  plan)
    terraform plan
    ;;
  apply)
    terraform apply -auto-approve
    echo ""
    echo "── Outputs ──────────────────────────────"
    terraform output

    if [[ "$CLUSTER" == "eks" ]]; then
      DOMAIN=$(grep 'domain' "$WORKDIR/main.tf" | grep 'default' | cut -d'"' -f2 || echo "app.deployhub.com")
      CLUSTER_NAME=$(grep 'cluster_name' "$WORKDIR/terraform.tfvars" | cut -d'"' -f2)
      REGION=$(grep 'aws_region' "$WORKDIR/terraform.tfvars" | cut -d'"' -f2)

      echo ""
      echo "══════════════════════════════════════════════════════════════"
      echo "  Waiting for ALB hostname (Flux may still be reconciling)..."
      echo "══════════════════════════════════════════════════════════════"

      aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION"

      ALB_HOST=""
      for i in $(seq 1 30); do
        ALB_HOST=$(kubectl get ingress -n pdvd pdvd-frontend-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
        if [[ -n "$ALB_HOST" ]]; then
          break
        fi
        echo "  Attempt $i/30 — ALB not ready yet, retrying in 10s..."
        sleep 10
      done

      echo ""
      if [[ -n "$ALB_HOST" ]]; then
        echo "╔══════════════════════════════════════════════════════════════╗"
        echo "║  DNS Setup                                                   ║"
        echo "╠══════════════════════════════════════════════════════════════╣"
        echo "║  Create a CNAME record in your DNS provider:                 ║"
        echo "║                                                              ║"
        printf "║  Name : %-53s║\n" "$DOMAIN"
        printf "║  Type : %-53s║\n" "CNAME"
        printf "║  Value: %-53s║\n" "$ALB_HOST"
        echo "╠══════════════════════════════════════════════════════════════╣"
        echo "║  Once DNS propagates, open:                                  ║"
        printf "║    https://%-50s║\n" "$DOMAIN"
        echo "║                                                              ║"
        echo "║  To test before DNS propagates:                              ║"
        printf "║    curl -sk -H 'Host: %s'\n" "$DOMAIN"
        printf "║         https://%-45s║\n" "$ALB_HOST"
        echo "╚══════════════════════════════════════════════════════════════╝"
      else
        echo "╔══════════════════════════════════════════════════════════════╗"
        echo "║  ALB hostname not yet assigned — Flux may still be syncing. ║"
        echo "║  Check ingress status with:                                  ║"
        echo "║    kubectl get ingress -n pdvd pdvd-frontend-ingress         ║"
        echo "╚══════════════════════════════════════════════════════════════╝"
      fi
    fi
    ;;
  destroy)
    # lifecycle.prevent_destroy cannot use variables in Terraform, so we
    # temporarily patch sops.tf to allow KMS key deletion, then restore it.
    SOPS_TF="$WORKDIR/sops.tf"
    if [[ -f "$SOPS_TF" ]]; then
      sed -i.bak 's/prevent_destroy = true/prevent_destroy = false/' "$SOPS_TF"
      trap 'sed -i.bak "s/prevent_destroy = false/prevent_destroy = true/" "$SOPS_TF" && rm -f "$SOPS_TF.bak"' EXIT
    fi
    terraform destroy -auto-approve
    ;;
  *)
    usage
    ;;
esac