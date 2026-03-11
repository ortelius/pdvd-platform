/*
  sops.tf — EKS SOPS decryption via age key

  Age key generation and .sops.yaml creation are handled by deploy.sh
  prior to Terraform running. This file applies the key to the cluster
  and patches kustomize-controller to use it.
*/

resource "null_resource" "sops_age_secret" {
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
        --from-file=age.agekey="$KEY_FILE" \
        --dry-run=client -o yaml | kubectl apply -f -

      echo "✓ sops-age secret applied in flux-system"
    CMD

    environment = {
      AWS_DEFAULT_REGION = var.aws_region
    }
  }

  depends_on = [null_resource.flux_bootstrap]
}

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

  depends_on = [null_resource.sops_age_secret]
}

output "age_key_file" {
  description = "Path to the age private key — back this up securely"
  value       = pathexpand("~/.ssh/${var.cluster_name}.sops.key")
}
