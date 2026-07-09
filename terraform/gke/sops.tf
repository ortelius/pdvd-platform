/*
  sops.tf — deployhub SOPS decryption via Cloud KMS + Workload Identity
             (automation on top of resources declared in main.tf)

  No key material is generated or stored anywhere — Flux's kustomize-controller
  and helm-controller authenticate to Cloud KMS using their Kubernetes
  ServiceAccount's Workload Identity binding to a dedicated GCP service account.
  SOPS picks up these ambient credentials automatically; nothing is mounted
  into the pod and there is no secret to back up or rotate by hand.

  The KMS data sources, the flux_sops service account, its KMS decrypter
  binding, and the kustomize-controller Workload Identity binding all live in
  main.tf already — this file only adds the helm-controller binding (main.tf
  only wires up kustomize-controller) plus the local-exec automation that
  writes clusters/.sops.yaml and the Flux Kustomization manifests back to git.
*/

# ── Workload Identity binding for helm-controller ─────────────────────────────
# kustomize-controller's binding (google_service_account_iam_member.flux_sops_workload_identity)
# already exists in main.tf. helm-controller also needs to decrypt SOPS values
# (via HelmRelease valuesFrom/postRenderers), so it gets its own binding here.
# Requires the helm-controller KSA to already exist, which only happens after
# flux_bootstrap_git has run.
resource "google_service_account_iam_member" "helm_controller_wi" {
  service_account_id = google_service_account.flux_sops.name
  role                = "roles/iam.workloadIdentityUser"
  member              = "serviceAccount:${var.project_id}.svc.id.goog[flux-system/helm-controller]"

  depends_on = [flux_bootstrap_git.gke]
}

# ── Add a clusters/<gitops_path> rule to .sops.yaml (does not touch eks or gke rules) ──
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

      if [ -f "$SOPS_FILE" ] && grep -q "path_regex: clusters/${local.gitops_path}" "$SOPS_FILE"; then
        echo ".sops.yaml already has a clusters/${local.gitops_path} rule — leaving as-is"
      else
        cat >> "$SOPS_FILE" <<SOPS
  - path_regex: clusters/${local.gitops_path}/.*\\.yaml$$
    gcp_kms: ${data.google_kms_crypto_key.sops.id}
SOPS
      fi

      git add clusters/.sops.yaml
      if ! git diff --cached --quiet; then
        git commit -m "chore(${var.cluster_name}): add clusters/${local.gitops_path} SOPS rule (Cloud KMS: ${data.google_kms_crypto_key.sops.id})"
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
    flux_path    = "clusters/${local.gitops_path}"
  }

  provisioner "local-exec" {
    command = <<-CMD
      REPO_ROOT=$(git -C "${path.module}" rev-parse --show-toplevel)
      FLUX_DIR="$REPO_ROOT/clusters/${local.gitops_path}/flux-system"
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
  path: ./clusters/${local.gitops_path}/ortelius
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
      git add "clusters/${local.gitops_path}/flux-system/kustomization.yaml" "clusters/${local.gitops_path}/flux-system/ortelius-kustomization.yaml"
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
    google_service_account_iam_member.flux_sops_workload_identity,
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