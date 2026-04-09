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
SECRETS_OUT="$SCRIPT_DIR/../clusters/$CLUSTER/ortelius/secrets.enc.yaml"
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

ensure_flux_cli() {
  if ! command -v flux &>/dev/null; then
    echo "Installing flux CLI..."
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
    FLUX_VERSION=$(curl -fsSL https://api.github.com/repos/fluxcd/flux2/releases/latest | grep tag_name | cut -d'"' -f4 | tr -d v)
    curl -fsSL "https://github.com/fluxcd/flux2/releases/download/v${FLUX_VERSION}/flux_${FLUX_VERSION}_${OS}_${ARCH}.tar.gz" -o /tmp/flux.tar.gz
    tar -xzf /tmp/flux.tar.gz -C /tmp flux && sudo mv /tmp/flux /usr/local/bin/flux && rm /tmp/flux.tar.gz
  fi
}

ensure_secrets() {
  ensure_tools

  if [ ! -f "$KEY_FILE" ]; then
    EKS_KEY=$(ls "$HOME"/.ssh/*eks*.sops.key 2>/dev/null | head -n 1)
    if [ -n "$EKS_KEY" ]; then
      echo "Found existing AWS age key ($EKS_KEY). Copying to $KEY_FILE..."
      cp "$EKS_KEY" "$KEY_FILE"
    else
      echo "Generating age key: $KEY_FILE"
      mkdir -p "$HOME/.ssh" && age-keygen -o "$KEY_FILE" && chmod 600 "$KEY_FILE"
    fi
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
    read -rp "  arangodb.arangodb_pass  : " DB_PASS
    read -rp "  prtelius.rbac_repo_token : " RBAC_TOKEN
    read -rp "  prtelius.clientSecret    : " GH_SECRET
    read -rp "  prtelius.appId           : " GH_APP_ID
    read -rp "  prtelius.clientId        : " GH_CLIENT_ID
    read -rp "  prtelius.baseUrl         : " BASE_URL
    read -rp "  smtp.password                : " SMTP_PASS
    echo "  prtelius.privateKey (Paste PEM block, then press Ctrl-D on a new line):"
    GH_KEY=$(cat)

    TMP=$(mktemp --suffix=.yaml)

    # 1. Base secrets for the application (always created)
    cat > "$TMP" <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: ortelius-secrets
  namespace: flux-system
stringData:
  values.yaml: |
    arangodb:
      arangodb_pass: "${DB_PASS}"
    prtelius:
      baseUrl: "${BASE_URL}"
      rbac_repo_token: "${RBAC_TOKEN}"
      github:
        appId: "${GH_APP_ID}"
        clientId: "${GH_CLIENT_ID}"
        clientSecret: "${GH_SECRET}"
        privateKey: |
$(echo "$GH_KEY" | sed 's/^/          /')
    smtp:
      username: "${SMTP_USER}"
      password: "${SMTP_PASS}"
YAML

    # 2. Conditionally append Cloudflare token for ExternalDNS
    DNS_PROVIDER=$(grep 'dns_provider' "$WORKDIR/terraform.tfvars" | cut -d'"' -f2 || echo "route53")

    if [[ "$DNS_PROVIDER" == "cloudflare" ]]; then
      # Prefer the env var; fall back to interactive prompt — never allow an empty token
      CF_TOKEN="${TF_VAR_cloudflare_api_token:-}"
      if [[ -z "$CF_TOKEN" ]]; then
        read -rp "  cloudflare.apiToken (required for ExternalDNS): " CF_TOKEN
      fi
      if [[ -z "$CF_TOKEN" ]]; then
        echo "ERROR: Cloudflare API token is required when dns_provider=cloudflare but was not provided."
        rm "$TMP"
        exit 1
      fi

      cat >> "$TMP" <<YAML
---
apiVersion: v1
kind: Secret
metadata:
  name: ortelius-secrets
  namespace: kube-system
stringData:
  cloudflare.apiToken: "${CF_TOKEN}"
YAML
    fi

    # 3. Encrypt the combined file
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

drain_flux_workloads() {
  echo ""
  echo "════════ Pre-destroy: draining Flux workloads ($CLUSTER_NAME) ════════"

  # Disable errexit for the entire drain — every error is handled explicitly.
  set +e

  ensure_flux_cli
  local FLUX_CLI_OK=$?
  if [[ $FLUX_CLI_OK -ne 0 ]]; then
    echo "  ⚠  Could not install flux CLI. Skipping Flux drain."
    set -e
    return 0
  fi

  # ── 1. Resolve cloud credentials & verify the cluster exists ────────────────
  local AWS_REGION GCP_REGION GCP_PROJECT
  local CLUSTER_REACHABLE=false

  if [[ "$CLUSTER" == "eks" ]]; then
    AWS_REGION=$(grep 'aws_region' "$WORKDIR/terraform.tfvars" | cut -d'"' -f2)

    # Check the cluster even exists in AWS before touching kubeconfig
    local CLUSTER_STATUS
    CLUSTER_STATUS=$(aws eks describe-cluster \
      --name "$CLUSTER_NAME" \
      --region "$AWS_REGION" \
      --query 'cluster.status' \
      --output text 2>/dev/null)

    if [[ -z "$CLUSTER_STATUS" ]]; then
      echo "  ⚠  EKS cluster '$CLUSTER_NAME' not found in AWS — already destroyed or never created."
      echo "     Skipping Flux drain."
      set -e; return 0
    fi

    if [[ "$CLUSTER_STATUS" != "ACTIVE" ]]; then
      echo "  ⚠  EKS cluster '$CLUSTER_NAME' is in state '$CLUSTER_STATUS' — cannot drain."
      echo "     Skipping Flux drain and proceeding to terraform destroy."
      set -e; return 0
    fi

    echo "  EKS cluster '$CLUSTER_NAME' is ACTIVE. Fetching kubeconfig..."
    aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION" 2>/dev/null
    if [[ $? -ne 0 ]]; then
      echo "  ⚠  update-kubeconfig failed (credentials issue?). Skipping Flux drain."
      set -e; return 0
    fi

  else
    GCP_REGION=$(grep 'region'      "$WORKDIR/terraform.tfvars" | cut -d'"' -f2)
    GCP_PROJECT=$(grep 'project_id' "$WORKDIR/terraform.tfvars" | cut -d'"' -f2)

    local CLUSTER_EXISTS
    CLUSTER_EXISTS=$(gcloud container clusters list \
      --project "$GCP_PROJECT" \
      --filter "name=$CLUSTER_NAME" \
      --format "value(name)" 2>/dev/null)

    if [[ -z "$CLUSTER_EXISTS" ]]; then
      echo "  ⚠  GKE cluster '$CLUSTER_NAME' not found — already destroyed or never created."
      echo "     Skipping Flux drain."
      set -e; return 0
    fi

    echo "  GKE cluster '$CLUSTER_NAME' found. Fetching kubeconfig..."
    gcloud container clusters get-credentials "$CLUSTER_NAME" \
      --region "$GCP_REGION" --project "$GCP_PROJECT" 2>/dev/null
    if [[ $? -ne 0 ]]; then
      echo "  ⚠  get-credentials failed. Skipping Flux drain."
      set -e; return 0
    fi
  fi

  # ── 2. Verify the API server is actually responding ─────────────────────────
  echo "  Verifying Kubernetes API server is reachable..."
  local API_CHECK
  kubectl cluster-info 2>/dev/null | grep -q "Kubernetes control plane"
  if [[ $? -ne 0 ]]; then
    echo "  ⚠  Kubernetes API server is not responding (cluster may be degraded)."
    echo "     Skipping Flux drain and proceeding to terraform destroy."
    set -e; return 0
  fi

  # ── 3. Verify Flux is installed ──────────────────────────────────────────────
  kubectl get namespace flux-system &>/dev/null
  if [[ $? -ne 0 ]]; then
    echo "  ⚠  flux-system namespace not found — Flux is not installed or was already removed."
    echo "     Skipping Flux drain and proceeding to terraform destroy."
    set -e; return 0
  fi

  # ── 4. Suspend all Kustomizations ───────────────────────────────────────────
  echo "  Suspending all Kustomizations..."
  flux suspend kustomization --all --namespace flux-system 2>/dev/null
  [[ $? -ne 0 ]] && echo "  ⚠  Could not suspend Kustomizations (may already be suspended or missing)."

  if [[ "$CLUSTER" == "eks" ]]; then
    echo ""
    echo "  Force-deleting ALBs via AWS CLI..."

    local HOSTNAMES
    HOSTNAMES=$(kubectl get ingress --all-namespaces --no-headers \
      -o custom-columns="HOST:.status.loadBalancer.ingress[0].hostname" 2>/dev/null \
      | grep -v '<none>' | grep -v '^$' || true)

    if [[ -n "$HOSTNAMES" ]]; then
      while IFS= read -r HOSTNAME; do
        [[ -z "$HOSTNAME" ]] && continue
        local ALB_NAME
        ALB_NAME=$(echo "$HOSTNAME" | cut -d'-' -f1-4)
        local ARN
        ARN=$(aws elbv2 describe-load-balancers \
          --region "$AWS_REGION" \
          --query "LoadBalancers[?contains(DNSName, '${ALB_NAME}')].LoadBalancerArn" \
          --output text 2>/dev/null)
        if [[ -n "$ARN" && "$ARN" != "None" ]]; then
          echo "    Deleting ALB: $ARN"
          aws elbv2 delete-load-balancer --load-balancer-arn "$ARN" --region "$AWS_REGION" 2>/dev/null
          [[ $? -ne 0 ]] && echo "    ⚠  Failed to delete $ARN — continuing."
        fi
      done <<< "$HOSTNAMES"
    fi

    local REMAINING_ARNS
    REMAINING_ARNS=$(aws elbv2 describe-load-balancers \
      --region "$AWS_REGION" \
      --query "LoadBalancers[?contains(LoadBalancerName, 'k8s-')].LoadBalancerArn" \
      --output text 2>/dev/null)
    if [[ -n "$REMAINING_ARNS" && "$REMAINING_ARNS" != "None" ]]; then
      for ARN in $REMAINING_ARNS; do
        echo "    Deleting remaining ALB: $ARN"
        aws elbv2 delete-load-balancer --load-balancer-arn "$ARN" --region "$AWS_REGION" 2>/dev/null
        [[ $? -ne 0 ]] && echo "    ⚠  Failed to delete $ARN — continuing."
      done
    fi

    echo "  Waiting for ALB deletions to complete..."
    local MAX_WAIT=120 INTERVAL=10 ELAPSED=0
    while true; do
      local TOTAL
      TOTAL=$(aws elbv2 describe-load-balancers \
        --region "$AWS_REGION" \
        --query "length(LoadBalancers[?contains(LoadBalancerName, 'k8s-')])" \
        --output text 2>/dev/null)
      [[ -z "$TOTAL" || "$TOTAL" == "None" ]] && TOTAL=0
      [[ "$TOTAL" -eq 0 ]] && { echo "  ✓ All ALBs deleted."; break; }
      if [[ "$ELAPSED" -ge "$MAX_WAIT" ]]; then
        echo "  ⚠  Timed out — ${TOTAL} ALB(s) still deleting. Proceeding anyway."
        break
      fi
      echo "  ${TOTAL} ALB(s) still deleting — retrying in ${INTERVAL}s (${ELAPSED}/${MAX_WAIT}s elapsed)..."
      sleep "$INTERVAL"
      ELAPSED=$(( ELAPSED + INTERVAL ))
    done

  elif [[ "$CLUSTER" == "gke" ]]; then
    TOTAL=$(gcloud compute forwarding-rules list \
      --project "$GCP_PROJECT" \
      --filter "description~$CLUSTER_NAME" \
      --format "value(name)" 2>/dev/null | wc -l | tr -d ' ')
    [[ -z "$TOTAL" ]] && TOTAL=0
    if [[ "$TOTAL" -gt 0 ]]; then
      echo "  ⚠  ${TOTAL} GCP forwarding rule(s) still present — remove manually if terraform destroy fails."
    else
      echo "  ✓ No GCP forwarding rules found."
    fi
  fi

  echo "  ✓ Flux workloads fully drained. Proceeding to terraform destroy."
  echo ""

  set -e
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
    drain_flux_workloads

    [[ -f "sops.tf" ]] && sed -i.bak 's/prevent_destroy = true/prevent_destroy = false/' sops.tf || true

    echo ""
    echo "════════ Destroying infrastructure ════════"
    terraform destroy -auto-approve
    echo "✓ Destroy completed successfully."

    [[ -f "sops.tf.bak" ]] && mv sops.tf.bak sops.tf || true
    ;;
  *) usage ;;
esac