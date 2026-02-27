#!/usr/bin/env bash
# deploy.sh — deploy GKE or EKS independently
#
# Usage:
#   ./deploy.sh gke [plan|apply|destroy]
#   ./deploy.sh eks [plan|apply|destroy]
#
# Requires:
#   export TF_VAR_github_token="ghp_..."
#
# GKE also requires:  gcloud auth application-default login
# EKS also requires:  aws configure  (or AWS_* env vars set)

set -euo pipefail

CLUSTER="${1:-}"
ACTION="${2:-apply}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  echo "Usage: $0 <gke|eks> [plan|apply|destroy]"
  exit 1
}

[[ -z "$CLUSTER" ]] && usage
[[ "$CLUSTER" != "gke" && "$CLUSTER" != "eks" ]] && usage
[[ -z "${TF_VAR_github_token:-}" ]] && { echo "ERROR: TF_VAR_github_token is not set"; exit 1; }

WORKDIR="$SCRIPT_DIR/$CLUSTER"

# EKS pre-flight: ensure the ALB controller policy JSON is present
if [[ "$CLUSTER" == "eks" && ! -f "$WORKDIR/alb-controller-iam-policy.json" ]]; then
  echo "Downloading ALB controller IAM policy..."
  curl -fsSL -o "$WORKDIR/alb-controller-iam-policy.json" \
    https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json
fi

echo ""
echo "══════════════════════════════════════════"
echo "  Cluster : $CLUSTER"
echo "  Action  : $ACTION"
echo "  Dir     : $WORKDIR"
echo "══════════════════════════════════════════"
echo ""

cd "$WORKDIR"

terraform init -upgrade

case "$ACTION" in
  plan)
    terraform plan
    ;;
  apply)
    terraform apply -auto-approve
    echo ""
    echo "── Outputs ──────────────────────────────"
    terraform output
    ;;
  destroy)
    # lifecycle.prevent_destroy cannot use variables in Terraform, so we
    # temporarily patch sops.tf to allow KMS key deletion, then restore it.
    SOPS_TF="$WORKDIR/sops.tf"
    if [[ -f "$SOPS_TF" ]]; then
      sed -i.bak 's/prevent_destroy = true/prevent_destroy = false/' "$SOPS_TF"
      trap 'sed -i.bak "s/prevent_destroy = false/prevent_destroy = true/" "$SOPS_TF" && rm -f "$SOPS_TF.bak"' EXIT
    fi
    terraform destroy -auto-approve
    ;;
  *)
    usage
    ;;
esac
