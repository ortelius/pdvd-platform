terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    github = {
      source  = "integrations/github"
      version = "~> 6.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    flux = {
      source  = "fluxcd/flux"
      version = "~> 1.3"
    }
  }
}

# ── Variables ─────────────────────────────────────────────────────────────────
variable "project_id"   { default = "eighth-physics-169321" }
variable "region"       { default = "us-central1" }
variable "cluster_name" { default = "ortelius-gke" }

variable "github_org"  { default = "ortelius" }
variable "github_repo" { default = "platform-iac" }
variable "github_token" {
  description = "GitHub PAT with repo + admin:public_key scopes"
  type        = string
  sensitive   = true
}

# ── Providers ─────────────────────────────────────────────────────────────────
provider "google" {
  project = var.project_id
  region  = var.region
}

provider "github" {
  owner = var.github_org
  token = var.github_token
}

# GCP access token is used by the flux kubernetes provider
data "google_client_config" "default" {}

provider "flux" {
  kubernetes = {
    host  = "https://${google_container_cluster.primary.endpoint}"
    token = data.google_client_config.default.access_token
    cluster_ca_certificate = base64decode(
      google_container_cluster.primary.master_auth[0].cluster_ca_certificate
    )
  }
  git = {
    url = "ssh://git@github.com/${var.github_org}/${var.github_repo}.git"
    ssh = {
      username    = "git"
      private_key = tls_private_key.flux.private_key_pem
    }
  }
}

# ── VPC ───────────────────────────────────────────────────────────────────────
resource "google_compute_network" "vpc" {
  name                    = "${var.cluster_name}-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "subnet" {
  name          = "${var.cluster_name}-subnet"
  region        = var.region
  network       = google_compute_network.vpc.id
  ip_cidr_range = "10.0.0.0/16"

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = "10.1.0.0/16"
  }
  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = "10.2.0.0/20"
  }
}

# ── Static IP for GLB ─────────────────────────────────────────────────────────
resource "google_compute_global_address" "app" {
  name = "static-app-ip"
}

# ── GKE Cluster ───────────────────────────────────────────────────────────────
resource "google_container_cluster" "primary" {
  name     = var.cluster_name
  location = var.region

  network    = google_compute_network.vpc.name
  subnetwork = google_compute_subnetwork.subnet.name

  remove_default_node_pool = true
  initial_node_count       = 1

  # Enable Dataplane V2
  datapath_provider = "ADVANCED_DATAPATH"

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }
}

variable "node_locations" {
  description = "GKE node zones. Keep a single zone here when you want exactly one node at startup/minimum."
  type        = list(string)
  default     = ["us-central1-a"]
}

variable "node_min_count" {
  description = "Minimum number of nodes for the default GKE node pool autoscaler."
  type        = number
  default     = 1
}

variable "node_max_count" {
  description = "Maximum number of nodes for the default GKE node pool autoscaler."
  type        = number
  default     = 3
}

resource "google_container_node_pool" "default" {
  name           = "default"
  location       = var.region
  cluster        = google_container_cluster.primary.name
  node_locations = var.node_locations

  # Start with one node. With autoscaling enabled, GKE can scale from
  # node_min_count to node_max_count as workload demand changes.
  initial_node_count = 1

  autoscaling {
    min_node_count = var.node_min_count
    max_node_count = var.node_max_count
  }

  node_config {
    machine_type = "n1-standard-2"

    # Run nodes as Spot VMs.
    spot = true

    image_type = "COS_FIPS_CONTAINERDS"

    labels = {
      arch      = "amd64"
      fips      = "enabled"
      lifecycle = "spot"
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    metadata = {
      disable-legacy-endpoints = "true"
    }

    oauth_scopes = ["https://www.googleapis.com/auth/cloud-platform"]

    workload_metadata_config {
      mode = "GKE_METADATA"
    }
  }
}

# ── Flux Bootstrap ────────────────────────────────────────────────────────────
# Terraform generates an ECDSA key pair.
# Public key → GitHub deploy key (write access so Flux can push gotk-components).
# Private key → stored as the flux-system Secret inside the cluster by flux_bootstrap_git.
resource "tls_private_key" "flux" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P384"
}

resource "github_repository_deploy_key" "flux_gke" {
  title      = "flux-gke"
  repository = var.github_repo
  key        = tls_private_key.flux.public_key_openssh
  read_only  = false
}

# ── Flux Bootstrap ────────────────────────────────────────────────────────────

resource "flux_bootstrap_git" "gke" {
  path = "clusters/${var.cluster_name}"

  components_extra = ["image-reflector-controller", "image-automation-controller"]

  # Override the default kustomization.yaml to inject the GSA email automatically
  kustomization_override = <<-EOT
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - gotk-components.yaml
  - gotk-sync.yaml
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
          iam.gke.io/gcp-service-account: ${google_service_account.flux_sops.email}
  EOT

  # Ensure the cluster nodes are up, deploy key exists, AND Workload Identity is ready
  depends_on = [
    google_container_node_pool.default,
    github_repository_deploy_key.flux_gke,
    google_service_account_iam_member.flux_sops_workload_identity
  ]
}

data "google_kms_key_ring" "sops" {
  name     = "sops"
  location = "global"
}

data "google_kms_crypto_key" "sops" {
  name     = "${var.cluster_name}-secrets"
  key_ring = data.google_kms_key_ring.sops.id
}

resource "google_kms_crypto_key_iam_member" "sops_user" {
  crypto_key_id = data.google_kms_crypto_key.sops.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "user:steve@deployhub.com"
}

# ── Outputs ───────────────────────────────────────────────────────────────────
output "cluster_name"     { value = google_container_cluster.primary.name }
output "cluster_endpoint" { value = google_container_cluster.primary.endpoint }
output "static_ip"        { value = google_compute_global_address.app.address }

variable "domain" {
  type        = string
  description = "Application domain name. Present in terraform.tfvars; used by deploy.sh/DNS output even if not consumed directly by this module."
  default     = ""
}

# ── Flux Workload Identity for SOPS ───────────────────────────────────────────

resource "google_service_account" "flux_sops" {
  account_id   = "${var.cluster_name}-flux-sops"
  display_name = "Flux SOPS Decrypter for ${var.cluster_name}"
}

resource "google_kms_crypto_key_iam_member" "flux_sops_decrypter" {
  crypto_key_id = data.google_kms_crypto_key.sops.id
  role          = "roles/cloudkms.cryptoKeyDecrypter"
  member        = "serviceAccount:${google_service_account.flux_sops.email}"
}

resource "google_service_account_iam_member" "flux_sops_workload_identity" {
  service_account_id = google_service_account.flux_sops.name
  role               = "roles/iam.workloadIdentityUser"
  # Syntax: serviceAccount:PROJECT_ID.svc.id.goog[K8S_NAMESPACE/KSA_NAME]
  member             = "serviceAccount:${var.project_id}.svc.id.goog[flux-system/kustomize-controller]"
}