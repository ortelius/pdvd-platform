/*
  sops.tf — EKS SOPS decryption via age key

  Generates an age keypair (X25519 / ed25519-based elliptic curve).
  The private key is persisted to $HOME/.ssh/<cluster_name>.sops.key
  and stored as a Kubernetes Secret in flux-system so kustomize-controller
  can decrypt SOPS-encrypted files without any cloud IAM or KMS dependency.

  The public key is written to .sops.yaml so `sops --encrypt` uses it
  automatically.

  No AWS KMS, no IRSA, no IAM roles needed.
*/

resource "null_resource" "age_keygen" {
  # Stable trigger — only re-runs if cluster name changes
  triggers = {
    cluster_name = var.cluster_name
  }

  provisioner "local-exec" {
    command = <<-CMD
      KEY_FILE="$HOME/.ssh/${var.cluster_name}.sops.key"

      # Install age if not present
      if ! command -v age-keygen &>/dev/null; then
        echo "Installing age..."
        OS=$(uname -s | tr '[:upper:]' '[:lower:]')
        ARCH=$(uname -m)
        case "$ARCH" in
          x86_64)        ARCH_AMD="amd64" ;;
          arm64|aarch64) ARCH_AMD="arm64" ;;
          *) echo "Unsupported architecture: $ARCH"; exit 1 ;;
        esac
        AGE_VERSION=$(curl -fsSL https://api.github.com/repos/FiloSottile/age/releases/latest \
          | grep tag_name | cut -d '"' -f4)
        curl -fsSL "https://github.com/FiloSottile/age/releases/download/$AGE_VERSION/age-$AGE_VERSION-$OS-$ARCH_AMD.tar.gz" \
          -o /tmp/age.tar.gz
        tar -xzf /tmp/age.tar.gz -C /tmp
        sudo mv /tmp/age/age /usr/local/bin/age
        sudo mv /tmp/age/age-keygen /usr/local/bin/age-keygen
        rm -rf /tmp/age.tar.gz /tmp/age
      fi

      # Generate key only if it doesn't already exist
      if [ ! -f "$KEY_FILE" ]; then
        echo "Generating age keypair -> $KEY_FILE"
        mkdir -p "$HOME/.ssh"
        age-keygen -o "$KEY_FILE"
        chmod 600 "$KEY_FILE"
        echo "Age key generated: $KEY_FILE"
      else
        echo "Age key already exists: $KEY_FILE"
      fi

      # Extract public key to temp file for Terraform to read back
      grep "^# public key:" "$KEY_FILE" | awk '{print $4}' \
        > /tmp/${var.cluster_name}-age-pubkey.txt
      echo "Public key: $(cat /tmp/${var.cluster_name}-age-pubkey.txt)"
    CMD
  }

  depends_on = [null_resource.flux_bootstrap]
}

# Read the generated public key back into Terraform
data "local_file" "age_pubkey" {
  filename   = "/tmp/${var.cluster_name}-age-pubkey.txt"
  depends_on = [null_resource.age_keygen]
}

# Create / update the sops-age Kubernetes secret in flux-system
resource "null_resource" "sops_age_secret" {
  triggers = {
    cluster_name = var.cluster_name
  }

  provisioner "local-exec" {
    command = <<-CMD
      KEY_FILE="$HOME/.ssh/${var.cluster_name}.sops.key"

      aws eks update-kubeconfig \
        --name ${var.cluster_name} \
        --region ${var.aws_region}

      kubectl create secret generic sops-age \
        --namespace=flux-system \
        --from-file=age.agekey="$KEY_FILE" \
        --dry-run=client -o yaml | kubectl apply -f -

      echo "sops-age secret applied in flux-system"
    CMD

    environment = {
      AWS_DEFAULT_REGION = var.aws_region
    }
  }

  depends_on = [null_resource.age_keygen]
}

# Write .sops.yaml with the age public key and commit it
resource "null_resource" "sops_yaml" {
  triggers = {
    cluster_name = var.cluster_name
  }

  provisioner "local-exec" {
    command = <<-CMD
      REPO_ROOT=$(git -C "${path.module}" rev-parse --show-toplevel)
      PUBKEY=$(cat /tmp/${var.cluster_name}-age-pubkey.txt)

      cat > "$REPO_ROOT/clusters/.sops.yaml" <<SOPS
creation_rules:
  - path_regex: clusters/eks/.*\\.yaml$$
    age: $PUBKEY
  - path_regex: clusters/gke/.*\\.yaml$$
    age: $PUBKEY
SOPS

      cd "$REPO_ROOT"
      git pull --rebase origin main
      git add clusters/.sops.yaml
      if ! git diff --cached --quiet; then
        git commit -m "chore: update .sops.yaml with age public key for ${var.cluster_name}"
        git push origin main
        echo ".sops.yaml committed"
      else
        echo ".sops.yaml unchanged"
      fi
    CMD

    environment = {
      GITHUB_TOKEN = var.github_token
    }
  }

  depends_on = [null_resource.age_keygen]
}

# Patch kustomize-controller deployment to mount the sops-age secret
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
      git pull --rebase origin main
      git add clusters/eks/flux-system/kustomization.yaml
      if ! git diff --cached --quiet; then
        git commit -m "chore(eks): patch kustomize-controller to use sops-age secret"
        git push origin main
        echo "kustomization.yaml committed"
      else
        echo "kustomization.yaml unchanged"
      fi
    CMD

    environment = {
      GITHUB_TOKEN = var.github_token
    }
  }

  depends_on = [null_resource.sops_age_secret, null_resource.sops_yaml]
}

# ── Outputs ───────────────────────────────────────────────────────────────────
output "age_public_key" {
  description = "Age public key — used in .sops.yaml for encrypting secrets"
  value       = trimspace(data.local_file.age_pubkey.content)
}

output "age_key_file" {
  description = "Path to the age private key — back this up securely"
  value       = pathexpand("~/.ssh/${var.cluster_name}.sops.key")
}
