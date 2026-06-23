/*
  sops.tf — deployhub SOPS decryption via Cloud KMS + Workload Identity

  No key material is generated or stored anywhere — Flux's kustomize-controller
  and helm-controller authenticate to Cloud KMS using their Kubernetes
  ServiceAccount's Workload Identity binding to a dedicated GCP service account.
  SOPS picks up these ambient credentials automatically; nothing is mounted
  into the pod and there is no secret to back up or rotate by hand.

  Resources here are named after var.cluster_name (deployhub) and are
  intentionally independent of cluster-2's existing "ortelius-keyring" /
  "flux-sops" resources, so this can be applied without importing or
  colliding with anything already running.
*/

# ── Existing persistent KMS keyring + key ──────────────────────────────────────
# deploy.sh bootstraps these if they do not exist. Terraform only reads them so
# cluster destroy/recreate testing does not schedule KMS key material destruction.
data "google_kms_key_ring" "flux" {
  name     = "sops"
  location = "global"
  project  = var.project_id
}

data "google_kms_crypto_key" "sops" {
  name     = "${var.cluster_name}-secrets"
  key_ring = data.google_kms_key_ring.flux.id
}

# ── GCP Service Account for Flux ──────────────────────────────────────────────
resource "google_service_account" "flux_sops" {
  account_id   = "${var.cluster_name}-sops"
  display_name = "Flux SOPS KMS decryption (${var.cluster_name})"
  project      = var.project_id
}

# Decrypt-only — Flux never encrypts, only reads secrets at reconcile time
resource "google_kms_crypto_key_iam_member" "flux_sops_decrypter" {
  crypto_key_id = data.google_kms_crypto_key.sops.id
  role          = "roles/cloudkms.cryptoKeyDecrypter"
  member        = "serviceAccount:${google_service_account.flux_sops.email}"
}

# ── Workload Identity bindings ────────────────────────────────────────────────
# Both controllers can decrypt: kustomize-controller via Kustomization.spec.decryption,
# helm-controller via HelmRelease valuesFrom/postRenderers that reference SOPS-encrypted
# Secrets. These require the target KSAs to already exist, which only happens after
# flux_bootstrap_git has run.
resource "google_service_account_iam_member" "kustomize_controller_wi" {
  service_account_id = google_service_account.flux_sops.name
  role                = "roles/iam.workloadIdentityUser"
  member              = "serviceAccount:${var.project_id}.svc.id.goog[flux-system/kustomize-controller]"

  depends_on = [flux_bootstrap_git.gke]
}

resource "google_service_account_iam_member" "helm_controller_wi" {
  service_account_id = google_service_account.flux_sops.name
  role                = "roles/iam.workloadIdentityUser"
  member              = "serviceAccount:${var.project_id}.svc.id.goog[flux-system/helm-controller]"

  depends_on = [flux_bootstrap_git.gke]
}

# ── Add a clusters/gke-2 rule to .sops.yaml (does not touch eks or gke rules) ──
resource "null_resource" "sops_yaml_post_bootstrap" {
  triggers = {
    cluster_name = var.cluster_name
    kms_key_id   = data.google_kms_crypto_key.sops.id
  }

  provisioner "local-exec" {
    command = <<-CMD
      REPO_ROOT=$(git -C "${path.module}" rev-parse --show-toplevel)
      SOPS_FILE="$REPO_ROOT/clusters/.sops.yaml"

      cd "$REPO_ROOT"
      git stash || true
      git pull --rebase origin main
      git stash pop || true

      if [ -f "$SOPS_FILE" ] && grep -q "path_regex: clusters/gke-2" "$SOPS_FILE"; then
        echo ".sops.yaml already has a clusters/gke-2 rule — leaving as-is"
      else
        cat >> "$SOPS_FILE" <<SOPS
  - path_regex: clusters/gke-2/.*\\.yaml$$
    gcp_kms: ${data.google_kms_crypto_key.sops.id}
SOPS
      fi

      git add clusters/.sops.yaml
      if ! git diff --cached --quiet; then
        git commit -m "chore(${var.cluster_name}): add clusters/gke-2 SOPS rule (Cloud KMS: ${data.google_kms_crypto_key.sops.id})"
        git push --set-upstream origin main
        echo "✓ .sops.yaml committed"
      else
        echo ".sops.yaml unchanged"
      fi
    CMD

    environment = {
      GITHUB_TOKEN = var.github_token
    }
  }

  depends_on = [flux_bootstrap_git.gke]
}

# ── Patch kustomize-controller / helm-controller SAs + author ortelius Kustomization ──
resource "null_resource" "flux_sops_patch_post_bootstrap" {
  triggers = {
    cluster_name = var.cluster_name
    gsa_email    = google_service_account.flux_sops.email
    flux_path    = var.flux_path
  }

  provisioner "local-exec" {
    command = <<-CMD
      REPO_ROOT=$(git -C "${path.module}" rev-parse --show-toplevel)
      FLUX_DIR="$REPO_ROOT/${var.flux_path}/flux-system"
      KUST_FILE="$FLUX_DIR/kustomization.yaml"
      ORTELIUS_KUST_FILE="$FLUX_DIR/ortelius-kustomization.yaml"

      mkdir -p "$FLUX_DIR"

      cat > "$KUST_FILE" <<KUST
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - gotk-components.yaml
  - gotk-sync.yaml
  - ortelius-kustomization.yaml
patches:
  - target:
      kind: ServiceAccount
      name: kustomize-controller
      namespace: flux-system
    patch: |
      - op: add
        path: /metadata/annotations/iam.gke.io~1gcp-service-account
        value: ${google_service_account.flux_sops.email}
  - target:
      kind: ServiceAccount
      name: helm-controller
      namespace: flux-system
    patch: |
      - op: add
        path: /metadata/annotations/iam.gke.io~1gcp-service-account
        value: ${google_service_account.flux_sops.email}
KUST

      # Child Kustomization for the ortelius workload, decrypting via Workload
      # Identity (no secretRef — age is not used by this cluster).
      cat > "$ORTELIUS_KUST_FILE" <<ORTELIUSKUST
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: ortelius
  namespace: flux-system
spec:
  interval: 10m
  path: ./${var.flux_path}/ortelius
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
  decryption:
    provider: sops
  dependsOn:
    - name: flux-system
ORTELIUSKUST

      cd "$REPO_ROOT"
      git stash || true
      git pull --rebase origin main
      git stash pop || true
      git add "${var.flux_path}/flux-system/kustomization.yaml" "${var.flux_path}/flux-system/ortelius-kustomization.yaml"
      if ! git diff --cached --quiet; then
        git commit -m "chore(${var.cluster_name}): annotate Flux controller SAs for Workload Identity KMS access, add ortelius Kustomization"
        git push --set-upstream origin main
        echo "✓ committed"
      else
        echo "no changes to commit"
      fi
    CMD

    environment = {
      GITHUB_TOKEN = var.github_token
    }
  }

  depends_on = [
    flux_bootstrap_git.gke,
    google_service_account_iam_member.kustomize_controller_wi,
    google_service_account_iam_member.helm_controller_wi,
    null_resource.sops_yaml_post_bootstrap,
  ]
}

output "kms_key_id" {
  description = "Cloud KMS key resource ID — used in .sops.yaml gcp_kms"
  value       = data.google_kms_crypto_key.sops.id
}

output "flux_sops_sa" {
  description = "GCP service account email — annotated on Flux controller KSAs"
  value       = google_service_account.flux_sops.email
}