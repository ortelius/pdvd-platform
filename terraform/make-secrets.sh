#!/usr/bin/env bash
# make-secrets.sh — create and encrypt secrets for pdvd-platform
# Run this directly in your terminal BEFORE running deploy.sh
#
# Usage: ./terraform/make-secrets.sh eks
#        ./terraform/make-secrets.sh gke

set -euo pipefail

CLUSTER_ENV="${1:-}"
if [[ -z "$CLUSTER_ENV" || ( "$CLUSTER_ENV" != "eks" && "$CLUSTER_ENV" != "gke" ) ]]; then
  echo "Usage: $0 <eks|gke>"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_NAME=$(grep 'cluster_name' "$SCRIPT_DIR/$CLUSTER_ENV/terraform.tfvars" | cut -d'"' -f2)
KEY_FILE="$HOME/.ssh/${CLUSTER_NAME}.sops.key"
SECRETS_OUT="$SCRIPT_DIR/../clusters/$CLUSTER_ENV/pdvd/secrets.enc.yaml"
SOPS_YAML="$SCRIPT_DIR/../clusters/.sops.yaml"

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║           pdvd-platform Secrets Setup                       ║"
echo "╠══════════════════════════════════════════════════════════════╣"
printf "║  Cluster env : %-45s║\n" "$CLUSTER_ENV"
printf "║  Cluster name: %-45s║\n" "$CLUSTER_NAME"
printf "║  Key file    : %-45s║\n" "$KEY_FILE"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# ── Install age ────────────────────────────────────────────────────────────────
if ! command -v age-keygen &>/dev/null; then
  echo "Installing age..."
  OS=$(uname -s | tr '[:upper:]' '[:lower:]')
  ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
  AGE_VERSION=$(curl -fsSL https://api.github.com/repos/FiloSottile/age/releases/latest \
    | grep tag_name | cut -d'"' -f4)
  curl -fsSL "https://github.com/FiloSottile/age/releases/download/$AGE_VERSION/age-$AGE_VERSION-$OS-$ARCH.tar.gz" \
    -o /tmp/age.tar.gz
  tar -xzf /tmp/age.tar.gz -C /tmp
  sudo mv /tmp/age/age /usr/local/bin/age
  sudo mv /tmp/age/age-keygen /usr/local/bin/age-keygen
  rm -rf /tmp/age.tar.gz /tmp/age
  echo "✓ age installed"
else
  echo "✓ age: $(age-keygen --version 2>/dev/null || echo 'installed')"
fi

# ── Install sops ───────────────────────────────────────────────────────────────
if ! command -v sops &>/dev/null; then
  echo "Installing sops..."
  OS=$(uname -s | tr '[:upper:]' '[:lower:]')
  ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
  SOPS_VERSION=$(curl -fsSL https://api.github.com/repos/getsops/sops/releases/latest \
    | grep tag_name | cut -d'"' -f4)
  curl -fsSL "https://github.com/getsops/sops/releases/download/$SOPS_VERSION/sops-$SOPS_VERSION.$OS.$ARCH" \
    -o /tmp/sops
  chmod +x /tmp/sops
  sudo mv /tmp/sops /usr/local/bin/sops
  echo "✓ sops installed"
else
  echo "✓ sops: $(sops --version 2>/dev/null || echo 'installed')"
fi

echo ""

# ── Generate age keypair ───────────────────────────────────────────────────────
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

# ── Update .sops.yaml ──────────────────────────────────────────────────────────
cat > "$SOPS_YAML" <<SOPS
creation_rules:
  - path_regex: clusters/eks/.*\.yaml$
    age: $AGE_PUBKEY
  - path_regex: clusters/gke/.*\.yaml$
    age: $AGE_PUBKEY
SOPS
echo "✓ clusters/.sops.yaml written"
echo ""

# ── Collect secrets ────────────────────────────────────────────────────────────
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

# ── Write temp plaintext + encrypt ────────────────────────────────────────────
TMPFILE=$(mktemp /tmp/secrets-XXXXXX.yaml)
trap 'rm -f "$TMPFILE"' EXIT

cat > "$TMPFILE" <<YAML
pdvd-arangodb:
    arangodb_pass: "${ARANGODB_PASS}"
pdvd-backend:
    rbac_repo_token: "${RBAC_REPO_TOKEN}"
    github:
        clientSecret: "${GITHUB_CLIENT_SECRET}"
        privateKey: |
$(echo "$GITHUB_PRIVATE_KEY" | sed 's/^/            /')
smtp:
    username: "${SMTP_USERNAME}"
    password: "${SMTP_PASSWORD}"
YAML

echo "Encrypting..."
SOPS_AGE_RECIPIENTS="$AGE_PUBKEY" sops --encrypt --age "$AGE_PUBKEY" "$TMPFILE" > "$SECRETS_OUT"
echo "✓ Written: $SECRETS_OUT"
echo ""

# ── Verify ─────────────────────────────────────────────────────────────────────
echo "Verifying decryption..."
if SOPS_AGE_KEY_FILE="$KEY_FILE" sops --decrypt "$SECRETS_OUT" > /dev/null 2>&1; then
  echo "✓ Decryption verified"
else
  echo "ERROR: Decryption failed"
  exit 1
fi

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Done! Next steps:                                          ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  1. git add clusters/.sops.yaml                             ║"
printf "║     git add clusters/%s/pdvd/secrets.enc.yaml          ║\n" "$CLUSTER_ENV"
echo "║     git commit -m 'chore: add encrypted secrets'            ║"
echo "║     git push origin main                                     ║"
echo "║                                                              ║"
printf "║  2. export TF_VAR_github_token='ghp_...'                    ║\n"
printf "║     ./deploy.sh %s apply                                    ║\n" "$CLUSTER_ENV"
echo "║                                                              ║"
printf "║  Backup: ~/.ssh/%s.sops.key        ║\n" "$CLUSTER_NAME"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
