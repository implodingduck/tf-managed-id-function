terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "=3.21.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "=3.1.0"
    }
  }
  backend "azurerm" {

  }
}

provider "azurerm" {
  features {}

  subscription_id = var.subscription_id
}

locals {
  func_name = "func${random_string.unique.result}"
  loc_for_naming = lower(replace(var.location, " ", ""))
  gh_repo = replace(var.gh_repo, "implodingduck/", "")
  tags = {
    "managed_by" = "terraform"
    "repo"       = local.gh_repo
  }
}

resource "random_string" "unique" {
  length  = 8
  special = false
  upper   = false
}


data "azurerm_client_config" "current" {}

data "azurerm_log_analytics_workspace" "default" {
  name                = "DefaultWorkspace-${data.azurerm_client_config.current.subscription_id}-EUS"
  resource_group_name = "DefaultResourceGroup-EUS"
} 

data "azurerm_network_security_group" "basic" {
    name                = "basic"
    resource_group_name = "rg-network-eastus"
}

resource "azurerm_resource_group" "rg" {
  name     = "rg-${local.gh_repo}-${random_string.unique.result}-${local.loc_for_naming}"
  location = var.location
  tags = local.tags
}

resource "azurerm_storage_account" "sa" {
  name                     = "sa${local.func_name}"
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}


resource "azurerm_storage_container" "container" {
  name                  = "function"
  storage_account_name  = azurerm_storage_account.sa.name
  container_access_type = "private"
}


resource "azurerm_storage_container" "hosts" {
  name                  = "azure-webjobs-hosts"
  storage_account_name  = azurerm_storage_account.sa.name
  container_access_type = "private"
}

resource "azurerm_storage_container" "secrets" {
  name                  = "azure-webjobs-secrets"
  storage_account_name  = azurerm_storage_account.sa.name
  container_access_type = "private"
}

resource "azurerm_role_assignment" "system" {
  scope                = azurerm_storage_account.sa.id
  role_definition_name = "Storage Blob Data Owner"
  principal_id         = azurerm_linux_function_app.func.identity.0.principal_id  
}

resource "azurerm_service_plan" "asp" {
  name                = "asp-${local.func_name}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  os_type             = "Linux"
  sku_name            = "Y1"
}

resource "azurerm_linux_function_app" "func" {
  depends_on = [
    azurerm_storage_container.hosts,
    azurerm_storage_container.secrets,
  ]
  name                = local.func_name
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location

  storage_account_name            = azurerm_storage_account.sa.name
  storage_uses_managed_identity   = true
  service_plan_id                 = azurerm_service_plan.asp.id

  site_config {
    application_stack {
      node_version = 16
    }
  }
  identity {
    type         = "SystemAssigned"
  }
  app_settings = {
    "WEBSITE_RUN_FROM_PACKAGE" = azurerm_storage_blob.blob.url
  }
}

resource "local_file" "localsettings" {
    content     = <<-EOT
{
  "IsEncrypted": false,
  "Values": {
    "FUNCTIONS_WORKER_RUNTIME": "node",
    "AzureWebJobsStorage": ""
  }
}
EOT
    filename = "../func/local.settings.json"
}

resource "null_resource" "publish_func" {
  triggers = {
    index = "${timestamp()}"
  }
  provisioner "local-exec" {
    command = "cd func && npm install"
  }
}

data "archive_file" "func" {
  depends_on = [
    null_resource.publish_func
  ]
  type        = "zip"
  source_dir  = "func"
  output_path = "func.zip"
}

resource "azurerm_storage_blob" "blob" {
  depends_on = [
    null_resource.publish_func
  ]
  name                   = "${local.func_name}.zip"
  storage_account_name   = azurerm_storage_account.sa.name
  storage_container_name = azurerm_storage_container.container.name
  type                   = "Block"
  source                 = "func.zip"
  content_md5            = data.archive_file.func.output_md5
}