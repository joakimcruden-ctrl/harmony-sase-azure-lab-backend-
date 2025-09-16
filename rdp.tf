

############################################################
# TILLÄGG: EN extra RG "SASE-RDPClient" med Windows 11-klienter
# - Antal klienter = var.resource_group_count
# - Eget VNet i 172.16.0.0/12 (subnät /16)
# - NSG öppnar RDP (3389/TCP)
# - Användarnamn = User01, User02, ...
# - Lösenord = BestSecurity1
############################################################

variable "enable_rdp" {
  description = "Set true to deploy the optional SASE-RDPClient resources."
  type        = bool
  default     = false
}

variable "rdp_location" {
  description = "Region för SASE-RDPClient (bör matcha din miljö)."
  type        = string
  default     = "Sweden Central"
}

variable "rdp_prefix" {
  description = "Namnprefix för resurser i SASE-RDPClient-RG."
  type        = string
  default     = "SASE-RDPClient"
}

variable "rdp_vm_size" {
  description = "VM-storlek för Windows 11-klienterna."
  type        = string
  default     = "Standard_D4s_v5"
}

variable "rdp_allowed_cidrs" {
  description = "Käll-CIDR som får ansluta RDP (3389)."
  type        = list(string)
  default     = ["0.0.0.0/0"] # Byt gärna till din publika IP/CIDR
}

# 1) RG
resource "azurerm_resource_group" "rdp_rg" {
  count    = var.enable_rdp ? 1 : 0
  name     = "SASE-RDPClient"
  location = var.rdp_location
}

# 2) VNet + Subnet (172.16.0.0/12 -> /16)
resource "azurerm_virtual_network" "rdp_vnet" {
  count               = var.enable_rdp ? 1 : 0
  name                = "${var.rdp_prefix}-vnet"
  resource_group_name = azurerm_resource_group.rdp_rg[0].name
  location            = azurerm_resource_group.rdp_rg[0].location
  address_space       = ["172.16.0.0/12"]
}

resource "azurerm_subnet" "rdp_clients_subnet" {
  count                = var.enable_rdp ? 1 : 0
  name                 = "clients-subnet"
  resource_group_name  = azurerm_resource_group.rdp_rg[0].name
  virtual_network_name = azurerm_virtual_network.rdp_vnet[0].name
  address_prefixes     = ["172.16.0.0/16"]
}

# 3) NSG + association (RDP)
resource "azurerm_network_security_group" "rdp_nsg" {
  count               = var.enable_rdp ? 1 : 0
  name                = "${var.rdp_prefix}-nsg"
  resource_group_name = azurerm_resource_group.rdp_rg[0].name
  location            = azurerm_resource_group.rdp_rg[0].location

  security_rule {
    name                       = "allow_rdp"
    priority                   = 1000
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3389"
    source_address_prefixes    = var.rdp_allowed_cidrs
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "rdp_subnet_nsg" {
  count                      = var.enable_rdp ? 1 : 0
  subnet_id                  = azurerm_subnet.rdp_clients_subnet[0].id
  network_security_group_id  = azurerm_network_security_group.rdp_nsg[0].id
}

# 4) Publika IP (en per klient) — antal = resource_group_count
resource "azurerm_public_ip" "rdp_pip" {
  count               = var.enable_rdp ? var.resource_group_count : 0
  name                = format("${var.rdp_prefix}-vm%02d-pip", count.index + 1)
  location            = azurerm_resource_group.rdp_rg[0].location
  resource_group_name = azurerm_resource_group.rdp_rg[0].name
  allocation_method   = "Static"
  sku                 = "Standard"
}

# 5) NIC per klient
resource "azurerm_network_interface" "rdp_nic" {
  count               = var.enable_rdp ? var.resource_group_count : 0
  name                = format("${var.rdp_prefix}-vm%02d-nic", count.index + 1)
  location            = azurerm_resource_group.rdp_rg[0].location
  resource_group_name = azurerm_resource_group.rdp_rg[0].name

  ip_configuration {
    name                          = "primary"
    subnet_id                     = azurerm_subnet.rdp_clients_subnet[0].id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.rdp_pip[count.index].id
  }
}

# 6) Windows 11-klienter (Enterprise N 22H2)
resource "azurerm_windows_virtual_machine" "rdp_vm" {
  count               = var.enable_rdp ? var.resource_group_count : 0
  name                = format("${var.rdp_prefix}-vm%02d", count.index + 1)
  computer_name       = format("RDPVM%02d", count.index + 1) # <= max 15 tecken
  resource_group_name = azurerm_resource_group.rdp_rg[0].name
  location            = azurerm_resource_group.rdp_rg[0].location
  network_interface_ids = [
    azurerm_network_interface.rdp_nic[count.index].id
  ]

  size           = var.rdp_vm_size
  admin_username = format("User%02d", count.index + 1)   # User01, User02, ...
  admin_password = "BestSecurity1"                       # fast lösenord

  os_disk {
    name                 = format("${var.rdp_prefix}-vm%02d-osdisk", count.index + 1)
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  # Windows 11 Enterprise N 22H2
  source_image_reference {
    publisher = "MicrosoftWindowsDesktop"
    offer     = "windows-11"
    sku       = "win11-22h2-entn"
    version   = "latest"
  }

  automatic_updates_enabled = true
  provision_vm_agent       = true

  boot_diagnostics { storage_account_uri = null }
}

# 7) Outputs
output "rdp_public_ips" {
  description = "Publika IP:n för Windows 11-klienterna i SASE-RDPClient. (empty when enable_rdp=false)"
  value       = azurerm_public_ip.rdp_pip[*].ip_address
}

output "rdp_mstsc_commands" {
  description = "Färdiga RDP-kommandon (Windows). (empty when enable_rdp=false)"
  value       = [for ip in azurerm_public_ip.rdp_pip[*].ip_address : "mstsc /v:${ip}:3389"]
}


# 8) Output: karta över användarnamn -> IP (inkl. VM-namn och mstsc)
output "rdp_clients" {
  description = "Mappar UserXX till publikt IP, VM-namn och färdigt mstsc-kommando. (empty when enable_rdp=false)"
  value = {
    for idx, ip in azurerm_public_ip.rdp_pip[*].ip_address :
    format("User%02d", idx + 1) => {
      vm    = format("${var.rdp_prefix}-vm%02d", idx + 1)
      ip    = ip
      mstsc = "mstsc /v:${ip}:3389"
    }
  }
}
