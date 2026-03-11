# terraform/gke/terraform.tfvars
# Committed to repo — github_token is NOT set here, pass it via env var:
#   export TF_VAR_github_token="ghp_..."

project_id   = "eighth-physics-169321"
region       = "us-central1"
cluster_name = "pdvd-gke"
domain       = "app.deployhub.com"

github_org  = "ortelius"
github_repo = "pdvd-platform"
