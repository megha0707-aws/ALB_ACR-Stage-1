terraform {
  backend "azurerm" {
    resource_group_name  = "Grouper"
    storage_account_name = "groupertfstatepoc01"
    container_name       = "terraform"
    key                  = "dcs-apps-alb.tfstate"
  }
}