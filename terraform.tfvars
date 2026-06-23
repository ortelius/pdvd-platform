# terraform/gke/terraform.tfvars
# Committed to repo — github_token is NOT set here, pass it via env var:
#   export TF_VAR_github_token="ghp_..."
#
# UPDATED: stands up a NEW cluster ("deployhub") with Cloud KMS-backed SOPS
# from day one, reconciled from a separate GitOps path (clusters/gke-2/) so
# it can run alongside the existing cluster-2 during cutover/burn-in without
# both clusters fighting over the same Flux source path.

project_id   = "eighth-physics-169321"
region       = "us-central1-a"
cluster_name = "deployhub"
domain       = "app.deployhub.com"

github_org  = "ortelius"
github_repo = "platform-iac"
