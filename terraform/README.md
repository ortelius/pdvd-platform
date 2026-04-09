# platform-iac — Terraform

Provisions cluster infrastructure and bootstraps FluxCD in a single `terraform apply`.

```
terraform/
├── gke/
│   ├── main.tf    # VPC, GKE cluster, static IP, Flux bootstrap
│   └── sops.tf    # Cloud KMS key, Workload Identity for kustomize-controller
└── eks/
    ├── main.tf    # VPC, EKS cluster, ALB IAM, ACM cert, Flux bootstrap
    └── sops.tf    # AWS KMS key, IRSA role for kustomize-controller
    └── alb-controller-iam-policy.json   # (you must download this — see below)
```

Each cluster is an independent Terraform workspace. `main.tf` and `sops.tf`
share the same workspace and state; providers and data sources are declared
once in `main.tf`.

---

## Prerequisites

### Both clusters
- GitHub PAT with **repo** + **admin:public_key** scopes (for Flux deploy key)

### GKE
```bash
gcloud auth application-default login
```

### EKS
```bash
aws configure   # or set AWS_* env vars
```
Download the ALB controller IAM policy before applying EKS:
```bash
curl -o terraform/eks/alb-controller-iam-policy.json \
  https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json
```

---

## Apply — GKE

```bash
cd terraform/gke

terraform init

terraform apply \
  -var="github_token=$GITHUB_TOKEN"
```

**What happens in order:**
1. VPC, subnet, static IP created
2. GKE cluster + node pool created
3. Flux SSH key pair generated
4. Deploy key registered on `ortelius/platform-iac`
5. `flux_bootstrap_git` connects to the cluster, installs Flux controllers
   into `clusters/gke/flux-system/`, and commits `gotk-components.yaml` to the repo
6. KMS key ring + crypto key created
7. `flux-sops` GCP service account created, granted `cryptoKeyDecrypter`
8. Workload Identity binding created so `kustomize-controller` can impersonate
   the GCP SA (binding waits for Flux bootstrap to create the SA)

**After apply** — copy outputs into `clusters/gke/flux-system/kustomization.yaml`:
```yaml
patches:
  - patch: |
      apiVersion: v1
      kind: ServiceAccount
      metadata:
        name: kustomize-controller
        namespace: flux-system
        annotations:
          iam.gke.io/gcp-service-account: <flux_sops_sa>
    target:
      kind: ServiceAccount
      name: kustomize-controller
```

Update `.sops.yaml` with the KMS key:
```yaml
creation_rules:
  - path_regex: clusters/gke/.*\.yaml$
    gcp_kms: <kms_key_id>
```

### Import existing GKE resources (if KMS/SA pre-exist)
```bash
terraform import google_kms_key_ring.flux \
  projects/eighth-physics-169321/locations/global/keyRings/flux-sops

terraform import google_kms_crypto_key.sops \
  projects/eighth-physics-169321/locations/global/keyRings/flux-sops/cryptoKeys/sops-key

terraform import google_service_account.flux_sops \
  projects/eighth-physics-169321/serviceAccounts/flux-sops@eighth-physics-169321.iam.gserviceaccount.com
```

---

## Apply — EKS

```bash
cd terraform/eks

terraform init

terraform apply \
  -var="github_token=$GITHUB_TOKEN"
```

**What happens in order:**
1. VPC with public + private subnets, NAT gateway created
2. EKS cluster + managed node group created
3. OIDC provider resolved (enables IRSA)
4. ALB controller IAM policy + role created
5. ACM certificate requested (DNS validation — add the CNAME to your DNS provider)
6. Flux SSH key pair generated
7. Deploy key registered on `ortelius/platform-iac`
8. `flux_bootstrap_git` connects to the cluster, installs Flux controllers
   into `clusters/eks/flux-system/`, and commits `gotk-components.yaml` to the repo
9. KMS key + alias created
10. IRSA role for `kustomize-controller` created (waits for Flux bootstrap)

**After apply** — copy outputs into `clusters/eks/flux-system/kustomization.yaml`:
```yaml
patches:
  - patch: |
      apiVersion: v1
      kind: ServiceAccount
      metadata:
        name: kustomize-controller
        namespace: flux-system
        annotations:
          eks.amazonaws.com/role-arn: <flux_sops_role_arn>
    target:
      kind: ServiceAccount
      name: kustomize-controller
```

Update `clusters/eks/ortelius/values.yaml` with infrastructure outputs:
```bash
terraform output -raw acm_certificate_arn    # → ingress.certificateArn
terraform output -json public_subnet_ids | jq -r 'join(",")' # → ingress.subnets
```

Update `.sops.yaml` with the KMS key ARN:
```yaml
creation_rules:
  - path_regex: clusters/eks/.*\.yaml$
    aws_kms: <kms_key_arn>
```

---

## Outputs reference

| Output | Used in |
|--------|---------|
| `flux_sops_sa` (GKE) | `kustomize-controller` SA annotation |
| `kms_key_id` (GKE) | `.sops.yaml` `gcp_kms` |
| `flux_sops_role_arn` (EKS) | `kustomize-controller` SA annotation |
| `kms_key_arn` (EKS) | `.sops.yaml` `aws_kms` |
| `acm_certificate_arn` (EKS) | `clusters/eks/ortelius/values.yaml` `ingress.certificateArn` |
| `public_subnet_ids` (EKS) | `clusters/eks/ortelius/values.yaml` `ingress.subnets` |
| `alb_controller_role_arn` (EKS) | `clusters/eks/ortelius/aws-load-balancer-controller.yaml` SA annotation |
