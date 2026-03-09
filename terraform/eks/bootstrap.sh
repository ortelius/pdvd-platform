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
echo "║  Cluster : pdvd-eks                                      ║"
echo "║  Region  : us-east-1                                        ║"
echo "║  Repo    : ortelius/pdvd-platform                           ║"
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
  curl -fsSL "https://github.com/fluxcd/flux2/releases/download/v$FLUX_VERSION/flux_${FLUX_VERSION}_${OS}_${ARCH_AMD}.tar.gz" -o /tmp/flux.tar.gz
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
aws eks update-kubeconfig --name pdvd-eks --region us-east-1

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
  --owner=ortelius \
  --repository=pdvd-platform \
  --branch=main \
  --path=clusters/eks \
  --personal \
  --components-extra=image-reflector-controller,image-automation-controller
