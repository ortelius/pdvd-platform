/*
  sops.tf — EKS SOPS decryption via AWS KMS + IRSA
             (mirrors terraform/gke/sops.tf's Cloud KMS + Workload Identity pattern)

  No key material is generated or stored anywhere — kustomize-controller and
  helm-controller authenticate to KMS using their Kubernetes ServiceAccount's
  IAM Roles for Service Accounts (IRSA) binding to a dedicated IAM role
  (module.flux_sops_irsa_role / aws_iam_policy.flux_sops_kms, declared in
  main.tf). SOPS picks up these ambient credentials automatically via the AWS
  SDK's default credential chain; nothing is mounted into the pod and there is
  no age key to generate, distribute, or back up by hand.
*/

# ── Add a clusters/eks rule to .sops.yaml (does not touch gke rules) ──────────
resource "null_resource" "sops_yaml_post_bootstrap" {
  triggers = {
    cluster_name = var.cluster_name
    kms_key_arn  = data.aws_kms_alias.sops.target_key_arn
  }

  provisioner "local-exec" {
    command = <<-CMD
      REPO_ROOT=$(git -C "${path.module}" rev-parse --show-toplevel)
      SOPS_FILE="$REPO_ROOT/clusters/.sops.yaml"

      cd "$REPO_ROOT"
      git stash || true
      git pull --rebase origin main
      git stash pop || true

      if [ -f "$SOPS_FILE" ] && grep -q "path_regex: clusters/eks" "$SOPS_FILE"; then
        echo ".sops.yaml already has a clusters/eks rule — leaving as-is"
      else
        cat >> "$SOPS_FILE" <<SOPS
  - path_regex: clusters/eks/.*\\.yaml$$
    kms: ${data.aws_kms_alias.sops.target_key_arn}
SOPS
      fi

      git add clusters/.sops.yaml
      if ! git diff --cached --quiet; then
        git commit -m "chore(${var.cluster_name}): add clusters/eks SOPS rule (KMS: ${data.aws_kms_alias.sops.target_key_arn})"
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

  depends_on = [null_resource.flux_bootstrap]
}

# ── Patch kustomize-controller / helm-controller SAs + author Kustomizations ──
resource "null_resource" "flux_sops_patch" {
  triggers = {
    cluster_name = var.cluster_name
    role_arn     = module.flux_sops_irsa_role.iam_role_arn
  }

  provisioner "local-exec" {
    command = <<-CMD
      REPO_ROOT=$(git -C "${path.module}" rev-parse --show-toplevel)
      FLUX_DIR="$REPO_ROOT/clusters/eks/flux-system"
      KUST_FILE="$FLUX_DIR/kustomization.yaml"
      ORTELIUS_KUST_FILE="$FLUX_DIR/ortelius-kustomization.yaml"

      cat > "$KUST_FILE" <<KUST
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - gotk-components.yaml
  - gotk-sync.yaml
  - ortelius-kustomization.yaml
  - aws-lbc-helmrepository.yaml
  - aws-lbc-helmrelease.yaml
  - external-dns-helmrepository.yaml
  - external-dns-helmrelease.yaml
patches:
  - target:
      kind: ServiceAccount
      name: kustomize-controller
      namespace: flux-system
    patch: |-
      apiVersion: v1
      kind: ServiceAccount
      metadata:
        name: kustomize-controller
        annotations:
          eks.amazonaws.com/role-arn: ${module.flux_sops_irsa_role.iam_role_arn}
  - target:
      kind: ServiceAccount
      name: helm-controller
      namespace: flux-system
    patch: |-
      apiVersion: v1
      kind: ServiceAccount
      metadata:
        name: helm-controller
        annotations:
          eks.amazonaws.com/role-arn: ${module.flux_sops_irsa_role.iam_role_arn}
  - patch: |
      apiVersion: kustomize.toolkit.fluxcd.io/v1
      kind: Kustomization
      metadata:
        name: flux-system
        namespace: flux-system
      spec:
        decryption:
          provider: sops
    target:
      kind: Kustomization
      name: flux-system
KUST

      # Child Kustomization for the ortelius workload, decrypting via IRSA
      # (no secretRef — age is no longer used by this cluster).
      cat > "$ORTELIUS_KUST_FILE" <<ORTELIUSKUST
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: ortelius
  namespace: flux-system
spec:
  interval: 10m
  path: ./clusters/eks/ortelius
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

      git add "clusters/eks/flux-system/kustomization.yaml" "clusters/eks/flux-system/ortelius-kustomization.yaml"
      git add clusters/.sops.yaml || true
      if ! git diff --cached --quiet; then
        git commit -m "chore(${var.cluster_name}): annotate Flux controller SAs for IRSA KMS access, refresh ortelius Kustomization"
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
    null_resource.flux_bootstrap,
    aws_iam_role_policy_attachment.flux_sops_kms,
    null_resource.sops_yaml_post_bootstrap,
  ]
}

output "kms_key_arn" {
  description = "AWS KMS key ARN — used in .sops.yaml kms rule"
  value       = data.aws_kms_alias.sops.target_key_arn
}

output "flux_sops_role_arn" {
  description = "IAM role ARN — annotated on Flux controller KSAs for IRSA KMS access"
  value       = module.flux_sops_irsa_role.iam_role_arn
}