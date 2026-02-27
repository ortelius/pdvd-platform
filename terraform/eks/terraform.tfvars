# terraform/eks/terraform.tfvars
# Committed to repo — github_token is NOT set here, pass it via env var:
#   export TF_VAR_github_token="ghp_..."

aws_region   = "us-east-1"
cluster_name = "pdvd-eks"
vpc_cidr     = "10.0.0.0/16"

github_org  = "ortelius"
github_repo = "pdvd-platform"
domain = "eks.deployhub.com"
