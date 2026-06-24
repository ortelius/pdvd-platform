#!/usr/bin/env bash
# deploy.sh — Consolidates secret management, infrastructure provisioning, and DNS setup
set -euo pipefail

CLUSTER="${1:-}"
ACTION="${2:-apply}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || echo "$SCRIPT_DIR")"

usage() {
  echo "Usage: $0 <gke|gke-2|eks> [plan|apply|destroy]"
  echo "       Any cluster directory named gke* is treated as a GKE cluster."
  exit 1
}

is_gke_cluster() {
  [[ "$CLUSTER" == gke* ]]
}

[[ -z "$CLUSTER" ]] && usage
[[ "$CLUSTER" != "eks" ]] && ! is_gke_cluster && usage
[[ -z "${TF_VAR_github_token:-}" ]] && { echo "ERROR: TF_VAR_github_token is not set"; exit 1; }

WORKDIR="$SCRIPT_DIR/$CLUSTER"
[[ ! -d "$WORKDIR" ]] && { echo "ERROR: Cluster directory not found: $WORKDIR"; exit 1; }
CLUSTER_NAME=$(grep 'cluster_name' "$WORKDIR/terraform.tfvars" | cut -d'"' -f2)
SECRETS_REL="clusters/$CLUSTER/ortelius/secrets.enc.yaml"
SECRETS_OUT="$REPO_ROOT/$SECRETS_REL"
SOPS_CONFIG="$REPO_ROOT/clusters/.sops.yaml"

tfvar_from_dir() {
  local cluster_dir="$1"
  local key="$2"
  grep -E "^[[:space:]]*${key}[[:space:]]*=" "$SCRIPT_DIR/$cluster_dir/terraform.tfvars" 2>/dev/null | tail -n 1 | cut -d'"' -f2
}

tfvar() {
  local key="$1"
  tfvar_from_dir "$CLUSTER" "$key"
}

gcp_kms_for_dir() {
  local cluster_dir="$1"
  local gcp_project cluster_name kms_location kms_keyring kms_key

  if [[ -n "${SOPS_GCP_KMS:-}" ]]; then
    echo "$SOPS_GCP_KMS"
    return 0
  fi

  gcp_project="$(tfvar_from_dir "$cluster_dir" project_id)"
  cluster_name="$(tfvar_from_dir "$cluster_dir" cluster_name)"
  kms_location="${SOPS_GCP_KMS_LOCATION:-${SOPS_KMS_LOCATION:-global}}"
  kms_keyring="${SOPS_GCP_KMS_KEYRING:-${SOPS_KMS_KEYRING:-sops}}"
  kms_key="${SOPS_GCP_KMS_KEY:-${SOPS_KMS_KEY:-${cluster_name}-secrets}}"

  echo "projects/${gcp_project}/locations/${kms_location}/keyRings/${kms_keyring}/cryptoKeys/${kms_key}"
}

ensure_gcp_sops_kms() {
  # KMS is persistent bootstrap infrastructure. KeyRings cannot be deleted,
  # and CryptoKey names cannot be quickly reused after destruction is scheduled,
  # so keep KMS outside the disposable cluster lifecycle.
  is_gke_cluster || return 0

  if ! command -v gcloud &>/dev/null; then
    echo "ERROR: gcloud is required to bootstrap GCP KMS for SOPS."
    exit 1
  fi

  local gcp_project cluster_name kms_location kms_keyring kms_key active_account enabled_versions scheduled_versions

  gcp_project="$(tfvar project_id)"
  cluster_name="$(tfvar cluster_name)"
  kms_location="${SOPS_GCP_KMS_LOCATION:-${SOPS_KMS_LOCATION:-global}}"
  kms_keyring="${SOPS_GCP_KMS_KEYRING:-${SOPS_KMS_KEYRING:-sops}}"
  kms_key="${SOPS_GCP_KMS_KEY:-${SOPS_KMS_KEY:-${cluster_name}-secrets}}"

  if [[ -z "$gcp_project" || -z "$cluster_name" ]]; then
    echo "ERROR: project_id and cluster_name must be set in $WORKDIR/terraform.tfvars"
    exit 1
  fi

  if ! gcloud kms keyrings describe "$kms_keyring" \
      --project "$gcp_project" \
      --location "$kms_location" >/dev/null 2>&1; then
    echo "Creating GCP KMS keyring: $kms_keyring"
    gcloud kms keyrings create "$kms_keyring" \
      --project "$gcp_project" \
      --location "$kms_location"
  else
    echo "✓ GCP KMS keyring exists: $kms_keyring"
  fi

  if ! gcloud kms keys describe "$kms_key" \
      --project "$gcp_project" \
      --location "$kms_location" \
      --keyring "$kms_keyring" >/dev/null 2>&1; then
    echo "Creating GCP KMS crypto key: $kms_key"
    gcloud kms keys create "$kms_key" \
      --project "$gcp_project" \
      --location "$kms_location" \
      --keyring "$kms_keyring" \
      --purpose encryption \
      --rotation-period 90d
  else
    echo "✓ GCP KMS crypto key exists: $kms_key"
  fi

  enabled_versions="$(gcloud kms keys versions list \
    --project "$gcp_project" \
    --location "$kms_location" \
    --keyring "$kms_keyring" \
    --key "$kms_key" \
    --filter 'state=ENABLED' \
    --format 'value(name)' 2>/dev/null || true)"

  if [[ -z "$enabled_versions" ]]; then
    scheduled_versions="$(gcloud kms keys versions list \
      --project "$gcp_project" \
      --location "$kms_location" \
      --keyring "$kms_keyring" \
      --key "$kms_key" \
      --filter 'state=DESTROY_SCHEDULED' \
      --format 'value(name)' 2>/dev/null || true)"

    if [[ -n "$scheduled_versions" ]]; then
      echo "⚠  KMS key '$kms_key' has no ENABLED versions; restoring DESTROY_SCHEDULED versions..."
      while IFS= read -r version_name; do
        [[ -z "$version_name" ]] && continue
        gcloud kms keys versions restore "$(basename "$version_name")" \
          --project "$gcp_project" \
          --location "$kms_location" \
          --keyring "$kms_keyring" \
          --key "$kms_key"
      done <<< "$scheduled_versions"
    else
      echo "ERROR: KMS key '$kms_key' exists but has no ENABLED key versions."
      echo "       Create a new key name with SOPS_GCP_KMS_KEY or inspect the key in GCP."
      exit 1
    fi
  fi

  # Best-effort: grant the active gcloud user encrypt/decrypt permission so SOPS can run
  # before Terraform has applied IAM bindings.
  active_account="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | head -n 1 || true)"
  if [[ -n "$active_account" ]]; then
    gcloud kms keys add-iam-policy-binding "$kms_key" \
      --project "$gcp_project" \
      --location "$kms_location" \
      --keyring "$kms_keyring" \
      --member "user:${active_account}" \
      --role roles/cloudkms.cryptoKeyEncrypterDecrypter >/dev/null 2>&1 || true
  fi

  export SOPS_GCP_KMS="projects/${gcp_project}/locations/${kms_location}/keyRings/${kms_keyring}/cryptoKeys/${kms_key}"
  echo "✓ SOPS_GCP_KMS=$SOPS_GCP_KMS"
}

ensure_tools() {
  if ! command -v sops &>/dev/null; then
    echo "Installing sops..."
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
    VERSION=$(curl -fsSL https://api.github.com/repos/getsops/sops/releases/latest | grep tag_name | cut -d'"' -f4)
    sudo curl -fsSL "https://github.com/getsops/sops/releases/download/$VERSION/sops-$VERSION.$OS.$ARCH" -o /usr/local/bin/sops
    sudo chmod +x /usr/local/bin/sops
  fi
}

resolve_sops_kms() {
  SOPS_ENCRYPT_ARGS=()
  SOPS_RULE_KEY=""
  SOPS_RULE_VALUE=""

  if is_gke_cluster; then
    # Override with the full resource ID when your KMS key is managed elsewhere.
    # Example: projects/my-project/locations/global/keyRings/sops/cryptoKeys/ortelius-gke-secrets
    SOPS_GCP_KMS="$(gcp_kms_for_dir "$CLUSTER")"

    SOPS_ENCRYPT_ARGS=(--gcp-kms "$SOPS_GCP_KMS")
    SOPS_RULE_KEY="gcp_kms"
    SOPS_RULE_VALUE="$SOPS_GCP_KMS"

  else
    local aws_region aws_account kms_alias
    aws_region="$(tfvar aws_region)"
    kms_alias="${SOPS_AWS_KMS_ALIAS:-alias/${CLUSTER_NAME}-sops}"

    # Prefer a full KMS ARN. If not set, try to derive an alias ARN from AWS STS.
    SOPS_AWS_KMS_ARN="${SOPS_AWS_KMS_ARN:-${SOPS_AWS_KMS:-}}"
    if [[ -z "$SOPS_AWS_KMS_ARN" ]] && command -v aws &>/dev/null; then
      aws_account=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)
      if [[ -n "$aws_account" && "$aws_account" != "None" ]]; then
        SOPS_AWS_KMS_ARN="arn:aws:kms:${aws_region}:${aws_account}:${kms_alias}"
      fi
    fi

    if [[ -z "$SOPS_AWS_KMS_ARN" ]]; then
      echo "ERROR: SOPS_AWS_KMS_ARN is required for EKS KMS encryption."
      echo "       Example: export SOPS_AWS_KMS_ARN=arn:aws:kms:${aws_region}:123456789012:alias/${CLUSTER_NAME}-sops"
      exit 1
    fi

    SOPS_ENCRYPT_ARGS=(--kms "$SOPS_AWS_KMS_ARN")
    SOPS_RULE_KEY="kms"
    SOPS_RULE_VALUE="$SOPS_AWS_KMS_ARN"
  fi
}

write_sops_config() {
  # Keep SOPS pointed at cloud KMS instead of local age keys.
  # Write rules for every local gke* directory so gke and gke-2 can coexist.
  mkdir -p "$(dirname "$SOPS_CONFIG")"

  {
    echo "creation_rules:"

    local cluster_dir kms_value
    shopt -s nullglob
    for cluster_path in "$SCRIPT_DIR"/gke*; do
      cluster_dir="$(basename "$cluster_path")"
      [[ -f "$cluster_path/terraform.tfvars" ]] || continue
      kms_value="$(gcp_kms_for_dir "$cluster_dir")"
      cat <<SOPS
  - path_regex: clusters/${cluster_dir}/.*\.yaml$
    gcp_kms: ${kms_value}
SOPS
    done
    shopt -u nullglob

    if [[ "$CLUSTER" == "eks" ]]; then
      cat <<SOPS
  - path_regex: clusters/eks/.*\.yaml$
    kms: ${SOPS_RULE_VALUE}
SOPS
    fi
  } > "$SOPS_CONFIG"

  echo "✓ Wrote SOPS config: $SOPS_CONFIG"
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

ensure_app_manifests() {
  # Static + per-cluster GitOps manifests for the ortelius HelmRelease.
  # Idempotent: only writes files that don't already exist, so hand-edited
  # manifests in an existing cluster directory are never overwritten.
  local ORTELIUS_DIR="$REPO_ROOT/clusters/$CLUSTER/ortelius"
  local KUSTOMIZE_REL="clusters/$CLUSTER/ortelius/kustomization.yaml"
  local HELMREPO_REL="clusters/$CLUSTER/ortelius/helmrepository.yaml"
  local HELMRELEASE_REL="clusters/$CLUSTER/ortelius/helmrelease.yaml"
  local DOMAIN
  DOMAIN="$(tfvar domain)"
  [[ -z "$DOMAIN" ]] && { echo "ERROR: domain must be set in $WORKDIR/terraform.tfvars"; exit 1; }

  mkdir -p "$ORTELIUS_DIR"
  local WROTE_ANY=false

  if [[ ! -f "$REPO_ROOT/$KUSTOMIZE_REL" ]]; then
    cat > "$REPO_ROOT/$KUSTOMIZE_REL" <<'YAML'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - helmrepository.yaml
  - helmrelease.yaml
  - secrets.enc.yaml
YAML
    echo "  ✓ Wrote $KUSTOMIZE_REL"
    WROTE_ANY=true
  fi

  if [[ ! -f "$REPO_ROOT/$HELMREPO_REL" ]]; then
    cat > "$REPO_ROOT/$HELMREPO_REL" <<'YAML'
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: helmcharts
  namespace: flux-system
spec:
  interval: 5m
  url: https://ortelius.github.io/helmcharts
YAML
    echo "  ✓ Wrote $HELMREPO_REL"
    WROTE_ANY=true
  fi

  if [[ ! -f "$REPO_ROOT/$HELMRELEASE_REL" ]]; then
    # appId/clientId/clientSecret/baseUrl/etc. live ONLY in the encrypted
    # secret (valuesFrom below) — not duplicated here as plaintext.
    cat > "$REPO_ROOT/$HELMRELEASE_REL" <<YAML
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: ortelius
  namespace: flux-system
spec:
  interval: 5m
  targetNamespace: ortelius
  install:
    createNamespace: true
  chart:
    spec:
      chart: ortelius
      version: ">=12.0.0"
      sourceRef:
        kind: HelmRepository
        name: helmcharts
        namespace: flux-system
      interval: 5m
  values:
    frontend:
      graphqlEndpoint: "https://${DOMAIN}/api/v1/graphql"
      restapiEndpoint: "https://${DOMAIN}/api/v1"
      ingress:
        type: glb
        host: "${DOMAIN}"
    ortelius:
      ingress:
        type: glb
        host: "${DOMAIN}"
      rbac_repo: "https://github.com/ortelius/rbac.git"
    arangodb: {}
  valuesFrom:
    - kind: Secret
      name: ortelius-secrets
YAML
    echo "  ✓ Wrote $HELMRELEASE_REL"
    WROTE_ANY=true
  fi

  if [[ "$WROTE_ANY" == true ]]; then
    cd "$REPO_ROOT"
    git add "$KUSTOMIZE_REL" "$HELMREPO_REL" "$HELMRELEASE_REL"
    if ! git diff --cached --quiet; then
      git commit -m "chore($CLUSTER): add ortelius GitOps manifests (kustomization/helmrepository/helmrelease)"
      git push
      echo "✓ App manifests committed and pushed"
    fi
    cd "$WORKDIR"
  else
    echo "  ✓ App manifests already present for $CLUSTER — skipping"
  fi
}

ensure_secrets() {
  ensure_tools
  ensure_gcp_sops_kms
  resolve_sops_kms
  write_sops_config

  if [[ ! -s "$SECRETS_OUT" ]]; then
    if [[ -f "$SECRETS_OUT" ]]; then
      echo "⚠  Existing secrets file is empty: $SECRETS_OUT"
      echo "   Regenerating it now."
    fi
    echo "--- Interactive Secret Setup for $CLUSTER ---"

    read -rp "  smtp.username                : " SMTP_USER
    read -rp "  arangodb.arangodb_pass  : " DB_PASS
    read -rp "  ortelius.rbac_repo_token : " RBAC_TOKEN
    read -rp "  ortelius.clientSecret    : " GH_SECRET
    read -rp "  ortelius.appId           : " GH_APP_ID
    read -rp "  ortelius.clientId        : " GH_CLIENT_ID
    read -rp "  ortelius.baseUrl         : " BASE_URL
    read -rp "  smtp.password                : " SMTP_PASS
    echo "  ortelius.privateKey (Paste PEM block, then press Ctrl-D on a new line):"
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
    ortelius:
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

    # 3. Encrypt the combined file safely.
    # Do not redirect sops directly into $SECRETS_OUT; shell redirection truncates
    # the destination before sops runs, which can leave a zero-byte secrets file
    # if encryption fails.
    mkdir -p "$(dirname "$SECRETS_OUT")"
    ENC_TMP="$(mktemp --suffix=.enc.yaml)"

    if ! sops --encrypt \
      --config "$SOPS_CONFIG" \
      --input-type yaml \
      --output-type yaml \
      --filename-override "$SECRETS_REL" \
      "${SOPS_ENCRYPT_ARGS[@]}" \
      --encrypted-regex '^(data|stringData)$' \
      "$TMP" > "$ENC_TMP"; then
      echo "ERROR: sops encryption failed; leaving $SECRETS_OUT unchanged."
      rm -f "$TMP" "$ENC_TMP"
      exit 1
    fi

    if [[ ! -s "$ENC_TMP" ]]; then
      echo "ERROR: sops produced an empty encrypted file; leaving $SECRETS_OUT unchanged."
      rm -f "$TMP" "$ENC_TMP"
      exit 1
    fi

    mv "$ENC_TMP" "$SECRETS_OUT"
    rm "$TMP"

    # Verify the output has plaintext metadata before committing
    echo "Verifying encryption (apiVersion should be plaintext):"
    head -4 "$SECRETS_OUT"

    cd "$REPO_ROOT"
    git add "$SOPS_CONFIG" "$SECRETS_OUT"
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

  elif is_gke_cluster; then
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
  ensure_app_manifests
  ensure_secrets
fi

if [[ "$CLUSTER" == "eks" && ! -f "$WORKDIR/alb-controller-iam-policy.json" ]]; then
  echo "Downloading ALB controller IAM policy..."
  curl -fsSL -o "$WORKDIR/alb-controller-iam-policy.json" \
    https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json
fi

ensure_gcp_sops_kms

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


    echo ""
    echo "════════ Destroying infrastructure ════════"
    terraform destroy -auto-approve
    echo "✓ Destroy completed successfully."

    ;;
  *) usage ;;
esac