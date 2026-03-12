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

# Step 3: Patch kustomize-controller and commit kustomization.yaml
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

      cd "$REPO_ROOT"
      git stash || true
      git pull --rebase origin main
      git stash pop || true

      git add clusters/eks/flux-system/kustomization.yaml
      git add clusters/.sops.yaml || true

      if ! git diff --cached --quiet; then
        git commit -m "chore(eks): patch kustomize-controller to use sops-age secret"
        git push --set-upstream origin main
        echo "✓ kustomization.yaml committed"
      else
        echo "kustomization.yaml unchanged"
      fi
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
