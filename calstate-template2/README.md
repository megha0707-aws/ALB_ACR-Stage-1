# Template 2 — Grouper ALB POC

Deploys the Azure Application Gateway for Containers (ALB) layer on top of an existing AKS cluster. This template does **not** create any core infrastructure — it reads the existing resource group, VNet, and AKS cluster created by Template 1 (the infra repo) and layers the ALB ingress stack on top.

---

## Architecture

```
Template 1 (infra repo)          Template 2 (this repo)
─────────────────────────        ──────────────────────────────────────
Resource Group: Grouper-Dev  →   data source (read only)
VNet: grouper-dev-tf-vnet    →   data source (read only)
AKS: aks-grouper-dev-cluster →   data source (read only)
                                  │
                                  ├── snet-alb-grouper-dev       (new subnet)
                                  ├── mi-alb-grouper-dev         (managed identity)
                                  ├── alb-grouper-dev            (ALB resource)
                                  ├── ALB subnet association
                                  ├── ALB controller             (Helm)
                                  ├── nginx/grouper deployment   (test app)
                                  ├── Gateway                    (gateway.networking.k8s.io)
                                  └── HTTPRoute                  (routes traffic to app)
```

---

## Pre-requisites

### 1. Template 1 (infra repo) must be applied first
The following resources must already exist:
- Resource Group: `Grouper-Dev`
- VNet: `grouper-dev-tf-vnet`
- AKS cluster: `aks-grouper-dev-cluster`

### 2. Workload identity must be enabled on the AKS cluster
The infra repo does not enable this by default. Add the following line to the AKS resource in `infra/aks.tf` alongside `oidc_issuer_enabled = true`:

```hcl
workload_identity_enabled = true
```

Then apply the infra repo. Alternatively, enable it manually:

```bash
az aks update \
  --name aks-grouper-dev-cluster \
  --resource-group Grouper-Dev \
  --enable-workload-identity
```

### 3. GitHub Actions secrets
Add these 4 secrets to the repo under **Settings → Secrets → Actions**:

| Secret | Value |
|---|---|
| `AZURE_CLIENT_ID` | Service principal client ID |
| `AZURE_CLIENT_SECRET` | Service principal client secret |
| `AZURE_SUBSCRIPTION_ID` | Azure subscription ID |
| `AZURE_TENANT_ID` | Azure tenant ID |

The service principal needs **Contributor** on the subscription and **User Access Administrator** scoped to the resource group (with ABAC restricted to Network Contributor and AppGw for Containers Configuration Manager — see setup.sh for why).

### 4. State backend must exist
This template reuses the existing calstate state storage account:
- Storage account: `groupertfstate`
- Resource group: `Grouper`
- Container: `terraform`
- State key: `dcs-apps-alb-poc.tfstate`

If the storage account does not exist yet, create it before running:

```bash
az storage account create \
  --name groupertfstate \
  --resource-group Grouper \
  --sku Standard_LRS

az storage container create \
  --name terraform \
  --account-name groupertfstate
```

---

## Deployment Steps

### Step 1 — Push to main (Stage 1 runs automatically)

Push this repo to main. GitHub Actions triggers **Stage 1** automatically, which creates:
- ALB subnet in the existing VNet
- ALB managed identity + federated credential (workload identity)
- ALB resource (Application Gateway for Containers)
- ALB subnet association

Stage 1 completes in ~2 minutes.

### Step 2 — Run setup.sh in Azure Cloud Shell

Stage 2 requires the ALB managed identity to have two RBAC roles that the GitHub Actions service principal cannot assign due to ABAC restrictions. Run this once after Stage 1 completes:

```bash
bash setup.sh
```

This assigns:
- **AppGw for Containers Configuration Manager** on the ALB resource → allows the ALB controller to configure routing
- **Network Contributor** on the resource group → allows the ALB controller to manage networking

The script waits 5 minutes for RBAC to propagate before exiting.

### Step 3 — Trigger Stage 2 manually

After setup.sh completes, go to:

**GitHub Actions → Calstate Grouper ALB POC — Terraform → Run workflow → type `yes` → Run workflow**

Stage 2 deploys:
1. ALB controller (Helm chart from `mcr.microsoft.com/application-lb/charts`)
2. App namespace + nginx deployment + service
3. Waits 60 seconds for ALB controller CRDs to register
4. Gateway + HTTPRoute

Stage 2 completes in ~3 minutes. The ALB frontend FQDN appears in the Azure portal under **alb-grouper-dev → Frontends** within 1-2 minutes after Stage 2 finishes.

---

## Switching from Nginx to the Grouper App

The current deployment uses nginx as a placeholder. To switch to the actual grouper image once it is pushed to the ACR:

1. Add to `variables.tf`:
```hcl
variable "acr_name" {
  description = "Dev ACR name"
  type        = string
}

variable "grouper_image_tag" {
  description = "Grouper image tag"
  type        = string
  default     = "latest"
}
```

2. Add to `terraform.tfvars`:
```hcl
acr_name          = "<dev-acr-name>"   # exact ACR name from calstate infra
grouper_image_tag = "latest"
```

3. In `main.tf`, replace the nginx deployment image:
```hcl
image = "${var.acr_name}.azurecr.io/grouper:${var.grouper_image_tag}"
```

And update the service selector and HTTPRoute backendRef from `nginx-service` to `grouper-service`.

> **Note:** The AKS kubelet identity needs AcrPull on the ACR. This must be assigned manually due to ABAC restrictions — add it to setup.sh or run once in Cloud Shell.

---

## File Structure

```
.
├── .github/
│   └── workflows/
│       └── terraform.yml   # GitHub Actions — Stage 1 on push, Stage 2 on workflow_dispatch
├── backend.tf               # Remote state — reuses calstate groupertfstate storage account
├── main.tf                  # All resources — ALB subnet, identity, ALB, Helm, app
├── outputs.tf               # ALB resource ID, identity client ID and principal ID
├── provider.tf              # azurerm, azapi, helm, kubernetes providers
├── setup.sh                 # One-time RBAC role assignments (run between Stage 1 and Stage 2)
├── terraform.tfvars         # Actual values for dev environment
├── variables.tf             # Variable declarations
└── README.md                # This file
```

---

## Outputs

| Output | Description |
|---|---|
| `alb_id` | Full resource ID of the ALB resource |
| `alb_identity_client_id` | Client ID of the ALB managed identity (used by Helm) |
| `alb_identity_principal_id` | Principal ID of the ALB managed identity (used in RBAC assignments) |

---

## Troubleshooting

**Frontend FQDN not appearing in portal**
```bash
kubectl get gateway demo-gateway -n demo -o yaml
# Look at status.conditions — should show Accepted: True and Programmed: True
```

**ALB controller PermissionDenied errors**
```bash
kubectl logs -n azure-alb-system -l app=alb-controller --tail=30
# If PermissionDenied — re-run setup.sh, the roles may not have propagated yet
kubectl rollout restart deployment -n azure-alb-system
```

**Workload identity token errors**
```bash
# Confirm workload identity is enabled on AKS
az aks show --name aks-grouper-dev-cluster --resource-group Grouper-Dev \
  --query "securityProfile.workloadIdentity.enabled"
# Should return true — if null, run the az aks update command from Pre-requisites step 2
```

**State lock error**
```bash
az storage blob lease break \
  --account-name groupertfstate \
  --container-name terraform \
  --blob-name dcs-apps-alb-poc.tfstate
```
