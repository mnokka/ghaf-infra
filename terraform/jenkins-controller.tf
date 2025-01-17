# SPDX-FileCopyrightText: 2023 Technology Innovation Institute (TII)
#
# SPDX-License-Identifier: Apache-2.0

# Build the Jenkins controller image
module "jenkins_controller_image" {
  source = "./modules/azurerm-nix-vm-image"

  nix_attrpath   = "outputs.nixosConfigurations.az-jenkins-controller.config.system.build.azureImage"
  nix_entrypoint = "${path.module}/.."

  name                   = "jenkins-controller"
  resource_group_name    = azurerm_resource_group.infra.name
  location               = azurerm_resource_group.infra.location
  storage_account_name   = azurerm_storage_account.vm_images.name
  storage_container_name = azurerm_storage_container.vm_images.name
}

# Create a machine using this image
module "jenkins_controller_vm" {
  source = "./modules/azurerm-linux-vm"

  resource_group_name          = azurerm_resource_group.infra.name
  location                     = azurerm_resource_group.infra.location
  virtual_machine_name         = "ghaf-jenkins-controller-${local.env}"
  virtual_machine_size         = local.opts[local.conf].vm_size_controller
  virtual_machine_source_image = module.jenkins_controller_image.image_id

  virtual_machine_custom_data = join("\n", ["#cloud-config", yamlencode({
    users = [
      for user in toset(["bmg", "flokli", "hrosten"]) : {
        name                = user
        sudo                = "ALL=(ALL) NOPASSWD:ALL"
        ssh_authorized_keys = local.ssh_keys[user]
      }
    ]
    write_files = [
      # See corresponding EnvironmentFile= directives in services
      {
        content = "KEY_VAULT_NAME=${data.azurerm_key_vault.ssh_remote_build.name}\nSECRET_NAME=${data.azurerm_key_vault_secret.ssh_remote_build.name}",
        "path"  = "/var/lib/fetch-build-ssh-key/env"
      },
      {
        content = "KEY_VAULT_NAME=${data.azurerm_key_vault.binary_cache_signing_key.name}\nSECRET_NAME=${data.azurerm_key_vault_secret.binary_cache_signing_key.name}",
        "path"  = "/var/lib/fetch-binary-cache-signing-key/env"
      },
      {
        content = "AZURE_STORAGE_ACCOUNT_NAME=${data.azurerm_storage_account.binary_cache.name}",
        "path"  = "/var/lib/rclone-http/env"
      },
      # Render /etc/nix/machines with terraform. In the future, we might want to
      # autodiscover this, or better, have agents register with the controller,
      # rather than having to recreate the VM whenever the list of builders is
      # changed.
      {
        content = join("\n", [
          for ip in toset(module.builder_vm[*].virtual_machine_private_ip_address) : "ssh://remote-build@${ip} x86_64-linux /etc/secrets/remote-build-ssh-key 10 10 kvm,big-parallel - -"
        ]),
        "path" = "/etc/nix/machines"
      },
      # Render /var/lib/builder-keyscan/scanlist, so known_hosts can be populated.
      {
        content = join("\n", toset(module.builder_vm[*].virtual_machine_private_ip_address))
        "path"  = "/var/lib/builder-keyscan/scanlist"
      }
    ]
  })])

  allocate_public_ip = true
  subnet_id          = azurerm_subnet.jenkins.id

  # Attach disk to the VM
  data_disks = [{
    name            = azurerm_managed_disk.jenkins_controller_jenkins_state.name
    managed_disk_id = azurerm_managed_disk.jenkins_controller_jenkins_state.id
    lun             = "10"
    # create_option = "Attach"
    caching      = "None"
    disk_size_gb = azurerm_managed_disk.jenkins_controller_jenkins_state.disk_size_gb
  }]
}

resource "azurerm_network_interface_security_group_association" "jenkins_controller_vm" {
  network_interface_id      = module.jenkins_controller_vm.virtual_machine_network_interface_id
  network_security_group_id = azurerm_network_security_group.jenkins_controller_vm.id
}

resource "azurerm_network_security_group" "jenkins_controller_vm" {
  name                = "jenkins-controller-vm"
  resource_group_name = azurerm_resource_group.infra.name
  location            = azurerm_resource_group.infra.location

  security_rule {
    name                       = "AllowSSHInbound"
    priority                   = 400
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = [22]
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

# Create a data disk
resource "azurerm_managed_disk" "jenkins_controller_jenkins_state" {
  name                 = "jenkins-controller-vm-jenkins-state"
  resource_group_name  = azurerm_resource_group.infra.name
  location             = azurerm_resource_group.infra.location
  storage_account_type = "Standard_LRS"
  create_option        = "Empty"
  disk_size_gb         = 10
}

# Grant the VM read-only access to the Azure Key Vault Secret containing the
# ed25519 private key used to connect to remote builders.
resource "azurerm_key_vault_access_policy" "ssh_remote_build_jenkins_controller" {
  key_vault_id = data.azurerm_key_vault.ssh_remote_build.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = module.jenkins_controller_vm.virtual_machine_identity_principal_id

  secret_permissions = [
    "Get",
  ]
}

# Allow the VM to *write* to (and read from) the binary cache bucket
resource "azurerm_role_assignment" "jenkins_controller_access_storage" {
  scope                = data.azurerm_storage_container.binary_cache_1.resource_manager_id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = module.jenkins_controller_vm.virtual_machine_identity_principal_id
}

# Grant the VM read-only access to the Azure Key Vault Secret containing the
# binary cache signing key.
resource "azurerm_key_vault_access_policy" "binary_cache_signing_key_jenkins_controller" {
  key_vault_id = data.azurerm_key_vault.binary_cache_signing_key.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = module.jenkins_controller_vm.virtual_machine_identity_principal_id

  secret_permissions = [
    "Get",
  ]
}
