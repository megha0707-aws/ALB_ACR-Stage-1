#!/usr/bin/env bash
# setup.sh — Run ONCE after Stage 1 (terraform apply) completes.
# Assigns the two RBAC roles the ALB managed identity needs.
# Run as: bash setup.sh

set -euo pipefail

SUBSCRIPTION_ID="f4f3ec7d-9d6f-4752-bdcc-440ed90734fe"
RESOURCE_GROUP="Grouper-Dev"
ALB_NAME="alb-grouper-dev"
IDENTITY_NAME="mi-alb-grouper-dev"

echo "── Setting subscription"
az account set --subscription "$SUBSCRIPTION_ID"
echo "[OK]    Subscription set."

echo "── Getting ALB identity principal ID"
ALB_PRINCIPAL_ID=$(az identity show \
  --name "$IDENTITY_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query principalId -o tsv)
echo "[OK]    ALB identity principal: $ALB_PRINCIPAL_ID"

ALB_RESOURCE_ID=$(az resource show \
  --resource-group "$RESOURCE_GROUP" \
  --resource-type "Microsoft.ServiceNetworking/trafficControllers" \
  --name "$ALB_NAME" \
  --query id -o tsv)

echo "── Assigning roles"

# 1. Reader on the ALB resource
az role assignment create \
  --assignee-object-id "$ALB_PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "Reader" \
  --scope "$ALB_RESOURCE_ID"
echo "[OK]    Reader on ALB resource — assigned."

# 2. Network Contributor on the resource group
az role assignment create \
  --assignee-object-id "$ALB_PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "Network Contributor" \
  --scope "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}"
echo "[OK]    Network Contributor on resource group — assigned."

echo "── Waiting 5 min for RBAC to propagate..."
for i in $(seq 30 30 300); do
  sleep 30
  echo "[INFO]    ${i}s elapsed"
done

echo "[OK]    Done. Now trigger Stage 2:"
echo "   GitHub Actions → Run workflow (workflow_dispatch) → type yes → Run workflow"
