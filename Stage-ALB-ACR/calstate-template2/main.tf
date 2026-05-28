# ============================================================
# Calstate Template 2 — Grouper ALB POC
# Stage 1 ONLY
# Uses EXISTING App Gateway subnet from infra
# ============================================================

# ----- Read existing calstate infra -----

data "azurerm_resource_group" "grouper" {
  name = var.resource_group_name
}

data "azurerm_virtual_network" "grouper" {
  name                = var.vnet_name
  resource_group_name = data.azurerm_resource_group.grouper.name
}

data "azurerm_kubernetes_cluster" "grouper" {
  name                = var.aks_cluster_name
  resource_group_name = data.azurerm_resource_group.grouper.name
}

# ----- Existing App Gateway subnet from infra -----

data "azurerm_subnet" "appgw" {
  name                 = "grouper-dev-tf-appgw-subnet"
  virtual_network_name = data.azurerm_virtual_network.grouper.name
  resource_group_name  = data.azurerm_resource_group.grouper.name
}

# ----- Reference Existing ACR -----

data "azurerm_container_registry" "acr" {
  name                = var.acr_name
  resource_group_name = data.azurerm_resource_group.grouper.name
}

# ----- ALB Managed Identity -----

resource "azurerm_user_assigned_identity" "alb" {
  name                = "mi-alb-${var.name_prefix}"
  resource_group_name = data.azurerm_resource_group.grouper.name
  location            = data.azurerm_resource_group.grouper.location

  lifecycle {
    ignore_changes = all
  }
}

# ----- Workload Identity Federation -----

resource "azurerm_federated_identity_credential" "alb" {
  name                = "alb-federated"
  resource_group_name = data.azurerm_resource_group.grouper.name
  parent_id           = azurerm_user_assigned_identity.alb.id

  audience = ["api://AzureADTokenExchange"]
  issuer   = data.azurerm_kubernetes_cluster.grouper.oidc_issuer_url
  subject  = "system:serviceaccount:azure-alb-system:alb-controller-sa"
}

# ----- ALB Traffic Controller -----

resource "azapi_resource" "alb" {
  type      = "Microsoft.ServiceNetworking/trafficControllers@2024-05-01-preview"
  name      = "alb-${var.name_prefix}"
  parent_id = data.azurerm_resource_group.grouper.id
  location  = data.azurerm_resource_group.grouper.location

  body = {
    properties = {}
  }

  lifecycle {
    ignore_changes = all
  }
}

# ----- Associate ALB with EXISTING App Gateway subnet -----

resource "azapi_resource" "alb_association" {
  type      = "Microsoft.ServiceNetworking/trafficControllers/associations@2024-05-01-preview"
  name      = "alb-association"
  parent_id = azapi_resource.alb.id
  location  = data.azurerm_resource_group.grouper.location

  body = {
    properties = {
      associationType = "subnets"
      subnet = {
        id = data.azurerm_subnet.appgw.id
      }
    }
  }
}

# ----- AcrPull Role Assignment -----

resource "azurerm_role_assignment" "acr_pull" {
  principal_id                     = data.azurerm_kubernetes_cluster.grouper.kubelet_identity[0].object_id
  role_definition_name             = "AcrPull"
  scope                            = data.azurerm_container_registry.acr.id
  skip_service_principal_aad_check = true
}

# ============================================================
# STAGE 2 — ALB Controller, App, Gateway, HTTPRoute
# ============================================================

# ----- ALB Controller via Helm -----

resource "helm_release" "alb_controller" {
  name             = "alb-controller"
  repository       = "oci://mcr.microsoft.com/application-lb/charts"
  chart            = "alb-controller"
  version          = "1.3.7"
  namespace        = "azure-alb-system"
  create_namespace = true
  wait             = true
  timeout          = 300

  values = [
    <<-EOT
    albController:
      namespace: azure-alb-system
      podIdentity:
        clientID: ${azurerm_user_assigned_identity.alb.client_id}
    EOT
  ]
}

# ----- App Namespace -----

resource "kubernetes_namespace" "grouper_app" {
  metadata {
    name = "grouper-app"
  }
}

# ----- Grouper Deployment -----

resource "kubernetes_deployment" "grouper" {
  metadata {
    name      = "grouper"
    namespace = kubernetes_namespace.grouper_app.metadata[0].name
  }

  spec {
    replicas = 1

    selector {
      match_labels = { app = "grouper" }
    }

    template {
      metadata {
        labels = { app = "grouper" }
      }

      spec {
        container {
          name  = "grouper"
          image = "${var.acr_name}.azurecr.io/grouper:${var.grouper_image_tag}"

          port {
            container_port = 80
          }
        }
      }
    }
  }
}

# ----- Grouper Service -----

resource "kubernetes_service" "grouper" {
  metadata {
    name      = "grouper-service"
    namespace = kubernetes_namespace.grouper_app.metadata[0].name
  }

  spec {
    selector = { app = "grouper" }

    port {
      port        = 80
      target_port = 80
    }
  }
}

# ----- Wait for ALB CRDs to register -----

resource "time_sleep" "wait_for_crds" {
  depends_on      = [helm_release.alb_controller]
  create_duration = "60s"
}

# ----- Gateway -----

resource "kubernetes_manifest" "gateway" {
  depends_on = [time_sleep.wait_for_crds]

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "Gateway"
    metadata = {
      name      = "grouper-gateway"
      namespace = kubernetes_namespace.grouper_app.metadata[0].name
      annotations = {
        "alb.networking.azure.io/alb-id" = azapi_resource.alb.id
      }
    }
    spec = {
      gatewayClassName = "azure-alb-external"
      listeners = [{
        name     = "http"
        port     = 80
        protocol = "HTTP"
        allowedRoutes = {
          namespaces = {
            from = "Same"
          }
        }
      }]
    }
  }
}

# ----- HTTPRoute -----

resource "kubernetes_manifest" "httproute" {
  depends_on = [kubernetes_manifest.gateway]

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "grouper-route"
      namespace = kubernetes_namespace.grouper_app.metadata[0].name
    }
    spec = {
      parentRefs = [{
        name      = "grouper-gateway"
        namespace = kubernetes_namespace.grouper_app.metadata[0].name
      }]
      rules = [{
        backendRefs = [{
          name = "grouper-service"
          port = 80
        }]
      }]
    }
  }
}