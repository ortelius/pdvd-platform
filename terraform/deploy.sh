#!/usr/bin/env bash
# deploy.sh — Consolidates secret management, infrastructure provisioning, and DNS setup
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
CLUSTER_NAME=$(grep 'cluster_name' "$WORKDIR/terraform.tfvars" | cut -d'"' -f2)
SECRETS_OUT="$SCRIPT_DIR/../clusters/$CLUSTER/pdvd/secrets.enc.yaml"
KEY_FILE="$HOME/.ssh/${CLUSTER_NAME}.sops.key"

ensure_tools() {
  if ! command -v age-keygen &>/dev/null; then
    echo "Installing age..."
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
    VERSION=$(curl -fsSL https://api.github.com/repos/FiloSottile/age/releases/latest | grep tag_name | cut -d'"' -f4)
    curl -fsSL "https://github.com/FiloSottile/age/releases/download/$VERSION/age-$VERSION-$OS-$ARCH.tar.gz" -o /tmp/age.tar.gz
    tar -xzf /tmp/age.tar.gz -C /tmp && sudo mv /tmp/age/age* /usr/local/bin/ && rm -rf /tmp/age*
  fi
  if ! command -v sops &>/dev/null; then
    echo "Installing sops..."
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
    VERSION=$(curl -fsSL https://api.github.com/repos/getsops/sops/releases/latest | grep tag_name | cut -d'"' -f4)
    sudo curl -fsSL "https://github.com/getsops/sops/releases/download/$VERSION/sops-$VERSION.$OS.$ARCH" -o /usr/local/bin/sops
    sudo chmod +x /usr/local/bin/sops
  fi
}

ensure_secrets() {
  ensure_tools

  if [ ! -f "$KEY_FILE" ]; then
    echo "Generating age key: $KEY_FILE"
    mkdir -p "$HOME/.ssh" && age-keygen -o "$KEY_FILE" && chmod 600 "$KEY_FILE"
  fi

  AGE_PUBKEY=$(grep "^# public key:" "$KEY_FILE" | awk '{print $4}')

  # Always write .sops.yaml so it stays in sync with the current key
  cat > "$SCRIPT_DIR/../clusters/.sops.yaml" <<SOPS
creation_rules:
  - path_regex: clusters/eks/.*\\.yaml$
    age: $AGE_PUBKEY
  - path_regex: clusters/gke/.*\\.yaml$
    age: $AGE_PUBKEY
SOPS

  if [ ! -f "$SECRETS_OUT" ]; then
    echo "--- Interactive Secret Setup for $CLUSTER ---"

    read -rp "  smtp.username                : " SMTP_USER
    read -rp "  pdvd-arangodb.arangodb_pass  : " DB_PASS
    read -rp "  pdvd-backend.rbac_repo_token : " RBAC_TOKEN
    read -rp "  pdvd-backend.clientSecret    : " GH_SECRET
    read -rp "  smtp.password                : " SMTP_PASS
    echo "  pdvd-backend.privateKey (Paste PEM block, then press Ctrl-D on a new line):"
    GH_KEY=$(cat)

    TMP=$(mktemp --suffix=.yaml)

    cat > "$TMP" <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: pdvd-secrets
  namespace: flux-system
stringData:
  values.yaml: |
    pdvd-arangodb:
      arangodb_pass: "${DB_PASS}"
    pdvd-backend:
      rbac_repo_token: "${RBAC_TOKEN}"
      github:
        clientSecret: "${GH_SECRET}"
        privateKey: |
$(echo "$GH_KEY" | sed 's/^/          /')
    smtp:
      username: "${SMTP_USER}"
      password: "${SMTP_PASS}"
YAML

    sops --encrypt \
      --input-type yaml \
      --output-type yaml \
      --age "$AGE_PUBKEY" \
      --encrypted-regex '^(data|stringData)$' \
      "$TMP" > "$SECRETS_OUT"
    rm "$TMP"

    # Verify the output has plaintext metadata before committing
    echo "Verifying encryption (apiVersion should be plaintext):"
    head -4 "$SECRETS_OUT"

    REPO_ROOT=$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)
    cd "$REPO_ROOT"
    git add clusters/.sops.yaml "$SECRETS_OUT"
    if ! git diff --cached --quiet; then
      git commit -m "chore($CLUSTER): add encrypted secrets and sops config"
      git push --set-upstream origin main
      echo "✓ Secrets committed and pushed"
    fi

    echo "✓ Secrets encrypted and written to $SECRETS_OUT"
  fi
}

if [[ "$ACTION" == "apply" ]]; then
  ensure_secrets
fi

if [[ "$CLUSTER" == "eks" && ! -f "$WORKDIR/alb-controller-iam-policy.json" ]]; then
  echo "Downloading ALB controller IAM policy..."
  curl -fsSL -o "$WORKDIR/alb-controller-iam-policy.json" \
    https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json
fi

echo "════════ Cluster: $CLUSTER | Action: $ACTION ════════"
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
      DOMAIN=$(grep 'domain' "$WORKDIR/terraform.tfvars" | cut -d'"' -f2)
      echo "╔══════════════════════════════════════════════════════════════╗"
      echo "║  DNS & ACM Setup Complete                                    ║"
      echo "╠══════════════════════════════════════════════════════════════╣"
      echo "║  ExternalDNS will now map ALB to: https://$DOMAIN"
      echo "╚══════════════════════════════════════════════════════════════╝"
    fi
    ;;
  destroy)
    [[ -f "sops.tf" ]] && sed -i.bak 's/prevent_destroy = true/prevent_destroy = false/' sops.tf || true
    terraform destroy -auto-approve
    [[ -f "sops.tf.bak" ]] && mv sops.tf.bak sops.tf || true
    ;;
  *) usage ;;
esac