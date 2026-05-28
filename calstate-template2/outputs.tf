output "alb_id" {
  value = azapi_resource.alb.id
}

output "alb_identity_client_id" {
  value = azurerm_user_assigned_identity.alb.client_id
}

output "alb_identity_principal_id" {
  value = azurerm_user_assigned_identity.alb.principal_id
}
