
#Number of environments to create
variable "resource_group_count" {
  description = "Number of resource groups to create"
  type        = number
  default     = 12
}
#set your own subscription ID
provider "azurerm" {
  features {}
  subscription_id = "ff155c65-757b-4033-936b-a391274bf95a"
}

resource "azurerm_resource_group" "sase_lab" {
  count    = var.resource_group_count
  name     = "SASE-LAB${count.index + 1}" #set dedicated name
  location = "Sweden Central"             #change to closest region
}

resource "azurerm_virtual_network" "sase_lab_vnet" {
  count               = var.resource_group_count
  name                = "sase_lab_vnet_${count.index + 1}"
  resource_group_name = azurerm_resource_group.sase_lab[count.index].name
  location            = azurerm_resource_group.sase_lab[count.index].location
  address_space       = [cidrsubnet("192.168.0.0/16", 8, count.index + 10)]
}

resource "azurerm_subnet" "sase_lab_subnet" {
  count                = var.resource_group_count
  name                 = "sase_lab_subnet_${count.index + 1}"
  resource_group_name  = azurerm_resource_group.sase_lab[count.index].name
  virtual_network_name = azurerm_virtual_network.sase_lab_vnet[count.index].name
  address_prefixes     = [cidrsubnet("192.168.0.0/16", 8, count.index + 10)]
}

#Allow SSH to wireguard connector
resource "azurerm_network_security_group" "sase_lab_nsg" {
  count               = var.resource_group_count
  name                = "sase_lab_nsg_${count.index + 1}"
  resource_group_name = azurerm_resource_group.sase_lab[count.index].name
  location            = azurerm_resource_group.sase_lab[count.index].location
  security_rule {
    name                       = "allow_ssh"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_public_ip" "sase_lab_public_ip" {
  count               = var.resource_group_count
  name                = "sase_lab_public_ip_${count.index + 1}"
  location            = azurerm_resource_group.sase_lab[count.index].location
  resource_group_name = azurerm_resource_group.sase_lab[count.index].name
  allocation_method   = "Dynamic"
  sku                 = "Basic"
}

resource "azurerm_network_interface" "sase_lab_nic" {
  count               = var.resource_group_count
  name                = "sase_lab_nic_${count.index + 1}"
  location            = azurerm_resource_group.sase_lab[count.index].location
  resource_group_name = azurerm_resource_group.sase_lab[count.index].name
  ip_configuration {
    name                          = "sase_lab_ipconfig_${count.index + 1}"
    subnet_id                     = azurerm_subnet.sase_lab_subnet[count.index].id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.sase_lab_public_ip[count.index].id
  }
}

resource "azurerm_linux_virtual_machine" "sase_lab_vm" {
  count                           = var.resource_group_count
  name                            = format("Srv%02d", count.index + 1)
  location                        = azurerm_resource_group.sase_lab[count.index].location
  resource_group_name             = azurerm_resource_group.sase_lab[count.index].name
  network_interface_ids           = [azurerm_network_interface.sase_lab_nic[count.index].id]
  size                            = "Standard_D2s_v3"
  admin_username                  = format("SrvUser%02d", count.index + 1)
  admin_password                  = "BestSecurity1"
  disable_password_authentication = false

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-focal"
    sku       = "20_04-lts"
    version   = "latest"
  }

  custom_data = base64encode(<<-EOF
              #!/bin/bash
              apt update && sudo apt upgrade -y
              EOF
  )

  depends_on = [azurerm_public_ip.sase_lab_public_ip]
}

resource "azurerm_network_interface" "sase_lab_web_nic" {
  count               = var.resource_group_count
  name                = "sase_lab_web_nic_${count.index + 1}"
  location            = azurerm_resource_group.sase_lab[count.index].location
  resource_group_name = azurerm_resource_group.sase_lab[count.index].name
  ip_configuration {
    name                          = "sase_lab_web_ipconfig_${count.index + 1}"
    subnet_id                     = azurerm_subnet.sase_lab_subnet[count.index].id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_linux_virtual_machine" "sase_lab_web_vm" {
  count                           = var.resource_group_count
  name                            = format("Websrv%02d", count.index + 1)
  location                        = azurerm_resource_group.sase_lab[count.index].location
  resource_group_name             = azurerm_resource_group.sase_lab[count.index].name
  network_interface_ids           = [azurerm_network_interface.sase_lab_web_nic[count.index].id]
  size                            = "Standard_D2s_v3"
  admin_username                  = format("Websrv%02d", count.index + 1)
  admin_password                  = "BestSecurity1"
  disable_password_authentication = false

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-focal"
    sku       = "20_04-lts"
    version   = "latest"
  }
  custom_data = base64encode(<<-EOF
              #!/bin/bash
              apt-get update
              apt-get install -y apache2
              systemctl enable apache2
              systemctl start apache2
              echo '<html><body><h1>Check Point Wins! </h1></body></html>' | sudo tee /var/www/html/checkpoint.html
              EOF
  ) #change "echo" to something nice

  depends_on = [
    azurerm_public_ip.sase_lab_public_ip
  ]
}


#return of public IPs for Wireguard Connectors
output "public_ips" {
  value = {
    for i in range(var.resource_group_count) :
    #"Srv${i + 1}" => azurerm_public_ip.sase_lab_public_ip[i].ip_address
    format("Srv%02d", i + 1) => azurerm_public_ip.sase_lab_public_ip[i].ip_address
  }
  description = "public IPs for Wireguard Connectors"
  depends_on = [
    azurerm_public_ip.sase_lab_public_ip
  ]
}

#return of private IPs for Wireguard Connectors
output "private_ips_linux" {
  value = {
    for i in range(var.resource_group_count) :
    format("Srv%02d", i + 1) => azurerm_network_interface.sase_lab_nic[i].private_ip_address
  }
  description = "private IPs for Wireguard Connectors"
}

#return of private IPs for webservers
output "private_ips_web" {
  value = {
    for i in range(var.resource_group_count) :
    format("Websrv%02d", i + 1) => azurerm_network_interface.sase_lab_web_nic[i].private_ip_address
  }
  description = "private IPs for webserver"
}


output "admin_usernames" {
  value = {
    for i in range(var.resource_group_count) :
    format("Srv%02d", i + 1) => format("SrvUser%02d", i + 1)
  }
  description = "Admin usernames for each VM"
}


output "web_vm_admin_usernames" {
  value = [
    for i in range(var.resource_group_count) : format("Websrv%02d", i + 1)
  ]
  description = "Admin usernames for each webserver"
}
