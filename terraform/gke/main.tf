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

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }
}

resource "google_container_node_pool" "default" {
  name       = "default"
  location   = var.region
  cluster    = google_container_cluster.primary.name
  node_count = 2

  node_config {
    machine_type = "e2-standard-2"
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

resource "flux_bootstrap_git" "gke" {
  # Flux will install its components into clusters/gke/flux-system/
  # and watch clusters/gke/ for workload kustomizations
  path = "clusters/gke"

  components_extra = ["image-reflector-controller", "image-automation-controller"]

  # Ensure the cluster nodes are up and the deploy key exists before bootstrapping
  depends_on = [
    google_container_node_pool.default,
    github_repository_deploy_key.flux_gke,
    null_resource.sops_age_secret_pre_bootstrap # ENFORCES SECRET INJECTION BEFORE BOOTSTRAP
  ]
}

# ── Outputs ───────────────────────────────────────────────────────────────────
output "cluster_name"     { value = google_container_cluster.primary.name }
output "cluster_endpoint" { value = google_container_cluster.primary.endpoint }
output "static_ip"        { value = google_compute_global_address.app.address }