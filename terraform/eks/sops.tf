/*
  sops.tf — EKS SOPS decryption via age key

  The sops-age secret MUST exist in flux-system before Flux bootstrap runs,
  otherwise kustomize-controller fails with CreateContainerConfigError.
  This file creates it before bootstrap and re-applies it after.
*/

# Step 1: Create sops-age secret BEFORE Flux bootstrap
resource "null_resource" "sops_age_secret_pre_bootstrap" {
  triggers = {
    cluster_name = var.cluster_name
  }

  provisioner "local-exec" {
    command = <<-CMD
      KEY_FILE="$HOME/.ssh/${var.cluster_name}.sops.key"

      if [ ! -f "$KEY_FILE" ]; then
        echo "Error: $KEY_FILE not found. Run deploy.sh to generate it."
        exit 1
      fi

      aws eks update-kubeconfig \
        --name ${var.cluster_name} \
        --region ${var.aws_region}

      # Create flux-system namespace if it doesn't exist yet
      kubectl create namespace flux-system --dry-run=client -o yaml | kubectl apply -f -

      kubectl create secret generic sops-age \
        --namespace=flux-system \
        --from-literal=SOPS_AGE_KEY="$(cat $KEY_FILE)" \
        --dry-run=client -o yaml | kubectl apply -f -

      echo "✓ sops-age secret created in flux-system before bootstrap"
    CMD

    environment = {
      AWS_DEFAULT_REGION = var.aws_region
    }
  }

  depends_on = [module.eks]
}

# Step 2: Re-apply sops-age secret after bootstrap (in case bootstrap recreated the namespace)
resource "null_resource" "sops_age_secret_post_bootstrap" {
  triggers = {
    flux_sync = null_resource.flux_bootstrap.id
  }

  provisioner "local-exec" {
    command = <<-CMD
      KEY_FILE="$HOME/.ssh/${var.cluster_name}.sops.key"

      if [ ! -f "$KEY_FILE" ]; then
        echo "Error: $KEY_FILE not found. Run deploy.sh to generate it."
        exit 1
      fi

      aws eks update-kubeconfig \
        --name ${var.cluster_name} \
        --region ${var.aws_region}

      kubectl create secret generic sops-age \
        --namespace=flux-system \
        --from-literal=SOPS_AGE_KEY="$(cat $KEY_FILE)" \
        --dry-run=client -o yaml | kubectl apply -f -

      echo "✓ sops-age secret re-applied in flux-system after bootstrap"
    CMD

    environment = {
      AWS_DEFAULT_REGION = var.aws_region
    }
  }

  depends_on = [null_resource.flux_bootstrap]
}

# Step 3: Write kustomization.yaml and commit
#
# flux-system kustomization: patches kustomize-controller with sops-age secret
#   and enables SOPS decryption on the flux-system Kustomization.
#
# pdvd kustomization: separate Kustomization for the pdvd path with dependsOn
#   flux-system so the ALB controller and external-dns are ready before pdvd
#   HelmReleases are reconciled. Prevents silent failures when pdvd deploys
#   before its infrastructure dependencies are ready.
resource "null_resource" "flux_sops_patch" {
  triggers = {
    cluster_name = var.cluster_name
  }

  provisioner "local-exec" {
    command = <<-CMD
      REPO_ROOT=$(git -C "${path.module}" rev-parse --show-toplevel)
      KUST_FILE="$REPO_ROOT/clusters/eks/flux-system/kustomization.yaml"

      cat > "$KUST_FILE" <<KUST
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - gotk-components.yaml
  - gotk-sync.yaml
  - aws-lbc-helmrepository.yaml
  - aws-lbc-helmrelease.yaml
  - external-dns-helmrepository.yaml
  - external-dns-helmrelease.yaml
patches:
  - patch: |
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: kustomize-controller
        namespace: flux-system
      spec:
        template:
          spec:
            containers:
              - name: manager
                envFrom:
                  - secretRef:
                      name: sops-age
    target:
      kind: Deployment
      name: kustomize-controller
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

      # Write the pdvd Kustomization as a separate file so it can declare
      # dependsOn without touching the flux-system Kustomization object.
      PDVD_KUST_FILE="$REPO_ROOT/clusters/eks/flux-system/pdvd-kustomization.yaml"
      cat > "$PDVD_KUST_FILE" <<PDVDKUST
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: pdvd
  namespace: flux-system
spec:
  interval: 10m
  path: ./clusters/eks/pdvd
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
  decryption:
    provider: sops
  dependsOn:
    - name: flux-system
PDVDKUST

      # Add pdvd-kustomization.yaml to the flux-system kustomization resources
      # so Flux picks it up. Use awk to insert after gotk-sync.yaml line.
      if ! grep -q "pdvd-kustomization.yaml" "$KUST_FILE"; then
        sed -i 's/  - gotk-sync.yaml/  - gotk-sync.yaml\n  - pdvd-kustomization.yaml/' "$KUST_FILE"
      fi

      cd "$REPO_ROOT"
      git stash || true
      git pull --rebase origin main
      git stash pop || true

      # Remove the old duplicate helmrelease.yaml if it exists
      if [ -f "$REPO_ROOT/clusters/eks/pdvd/helmrelease.yaml" ]; then
        git rm --force "$REPO_ROOT/clusters/eks/pdvd/helmrelease.yaml" 2>/dev/null || \
          rm -f "$REPO_ROOT/clusters/eks/pdvd/helmrelease.yaml"
        echo "✓ Removed duplicate clusters/eks/pdvd/helmrelease.yaml"
      fi

      git add clusters/eks/flux-system/kustomization.yaml
      git add clusters/eks/flux-system/pdvd-kustomization.yaml
      git add clusters/.sops.yaml || true

      if ! git diff --cached --quiet; then
        git commit -m "chore(eks): patch kustomize-controller, add pdvd Kustomization with dependsOn"
        git push --set-upstream origin main
        echo "✓ kustomization.yaml and pdvd-kustomization.yaml committed"
      else
        echo "kustomization files unchanged"
      fi

      # ── Age key backup warning ────────────────────────────────────────────
      KEY_FILE="$HOME/.ssh/${var.cluster_name}.sops.key"
      echo ""
      echo "╔══════════════════════════════════════════════════════════════════╗"
      echo "║  ⚠  IMPORTANT: Back up your age private key                     ║"
      echo "╠══════════════════════════════════════════════════════════════════╣"
      echo "║  Location : $KEY_FILE"
      echo "║                                                                  ║"
      echo "║  This is the ONLY copy of the key that decrypts all secrets     ║"
      echo "║  in the repository. If this file is lost, secrets in the repo   ║"
      echo "║  are permanently unreadable and must be re-encrypted.           ║"
      echo "║                                                                  ║"
      echo "║  Suggested: copy to a password manager or secure vault now.     ║"
      echo "╚══════════════════════════════════════════════════════════════════╝"
      echo ""
    CMD

    environment = {
      GITHUB_TOKEN = var.github_token
    }
  }

  depends_on = [null_resource.sops_age_secret_post_bootstrap]
}

output "age_key_file" {
  description = "Path to the age private key — back this up securely"
  value       = pathexpand("~/.ssh/${var.cluster_name}.sops.key")
}