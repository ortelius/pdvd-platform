/*
  sops.tf — GKE SOPS decryption via age key

  Generates an age keypair (X25519 / ed25519-based elliptic curve)
  or reuses an existing AWS/EKS key if present.
  The private key is persisted to $HOME/.ssh/<cluster_name>.sops.key
  and stored as a Kubernetes Secret in flux-system so kustomize-controller
  can decrypt SOPS-encrypted files without any cloud IAM, KMS, or
  Workload Identity dependency.
*/

resource "null_resource" "age_keygen" {
  triggers = {
    cluster_name = var.cluster_name
  }

  provisioner "local-exec" {
    command = <<-CMD
      KEY_FILE="$HOME/.ssh/${var.cluster_name}.sops.key"

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

      if [ ! -f "$KEY_FILE" ]; then
        # Check if an AWS/EKS key exists to share the same identity
        EKS_KEY=$(ls $HOME/.ssh/*eks*.sops.key 2>/dev/null | head -n 1)
        
        if [ -n "$EKS_KEY" ]; then
          echo "Found existing AWS age key ($EKS_KEY). Copying to $KEY_FILE to share identity..."
          cp "$EKS_KEY" "$KEY_FILE"
        else
          echo "Generating age keypair -> $KEY_FILE"
          mkdir -p "$HOME/.ssh"
          age-keygen -o "$KEY_FILE"
          chmod 600 "$KEY_FILE"
          echo "Age key generated: $KEY_FILE"
        fi
      else
        echo "Age key already exists: $KEY_FILE"
      fi

      grep "^# public key:" "$KEY_FILE" | awk '{print $4}' \
        > /tmp/${var.cluster_name}-age-pubkey.txt
      echo "Public key: $(cat /tmp/${var.cluster_name}-age-pubkey.txt)"
    CMD
  }
}

data "local_file" "age_pubkey" {
  filename   = "/tmp/${var.cluster_name}-age-pubkey.txt"
  depends_on = [null_resource.age_keygen]
}

# Step 1: Create sops-age secret BEFORE Flux bootstrap
resource "null_resource" "sops_age_secret_pre_bootstrap" {
  triggers = {
    cluster_name = var.cluster_name
  }

  provisioner "local-exec" {
    command = <<-CMD
      KEY_FILE="$HOME/.ssh/${var.cluster_name}.sops.key"

      gcloud container clusters get-credentials ${var.cluster_name} \
        --region ${var.region} \
        --project ${var.project_id}

      # Create namespace if it doesn't exist yet
      kubectl create namespace flux-system --dry-run=client -o yaml | kubectl apply -f -

      kubectl create secret generic sops-age \
        --namespace=flux-system \
        --from-literal=SOPS_AGE_KEY="$(cat $KEY_FILE)" \
        --dry-run=client -o yaml | kubectl apply -f -

      echo "sops-age secret applied in flux-system"
    CMD
  }

  depends_on = [null_resource.age_keygen, google_container_node_pool.default]
}

# Step 2: Push Git commits AFTER Flux bootstrap
resource "null_resource" "sops_yaml_post_bootstrap" {
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
      git stash || true
      git pull --rebase origin main
      git stash pop || true
      git add clusters/.sops.yaml
      if ! git diff --cached --quiet; then
        git commit -m "chore: update .sops.yaml with age public key for ${var.cluster_name}"
        git push --set-upstream origin main
        echo ".sops.yaml committed"
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

resource "null_resource" "flux_sops_patch_post_bootstrap" {
  triggers = {
    cluster_name = var.cluster_name
  }

  provisioner "local-exec" {
    command = <<-CMD
      REPO_ROOT=$(git -C "${path.module}" rev-parse --show-toplevel)
      KUST_FILE="$REPO_ROOT/clusters/gke/flux-system/kustomization.yaml"

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
      git add clusters/gke/flux-system/kustomization.yaml
      if ! git diff --cached --quiet; then
        git commit -m "chore(gke): patch kustomize-controller to use sops-age secret"
        git push --set-upstream origin main
        echo "kustomization.yaml committed"
      else
        echo "kustomization.yaml unchanged"
      fi
    CMD

    environment = {
      GITHUB_TOKEN = var.github_token
    }
  }

  depends_on = [flux_bootstrap_git.gke, null_resource.sops_yaml_post_bootstrap]
}

output "age_public_key" {
  description = "Age public key — used in .sops.yaml for encrypting secrets"
  value       = trimspace(data.local_file.age_pubkey.content)
}

output "age_key_file" {
  description = "Path to the age private key — back this up securely"
  value       = pathexpand("~/.ssh/${var.cluster_name}.sops.key")
}