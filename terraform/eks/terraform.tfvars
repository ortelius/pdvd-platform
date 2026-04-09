# terraform/eks/terraform.tfvars
# Committed to repo — github_token is NOT set here, pass it via env var:
#   export TF_VAR_github_token="ghp_..."

aws_region   = "us-east-1"
cluster_name = "ortelius-eks"
vpc_cidr     = "10.0.0.0/16"
domain       = "eks.deployhub.com"

github_org  = "ortelius"
github_repo = "platform-iac"

dns_provider  = "cloudflare"      # Change to "route53" if using AWs DNS
dns_zone_name = "deployhub.com"   # The parent hosted zone for the cluster domain