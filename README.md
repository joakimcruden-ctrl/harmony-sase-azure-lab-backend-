**Harmony SASE Azure Lab (Terraform)**

- **Purpose:** Provision a multi-environment Azure lab for SASE demos and trainings. Each environment includes a Linux VM (for connector/utility use), a simple web server VM, and supporting networking. An optional RDP client resource group provides Windows 11 VMs for user simulation.
- **Tech:** Terraform + AzureRM provider.

**What It Creates**

- **Environments:** `var.resource_group_count` identical stacks (default: 12) named `SASE-LAB01..N`.
- **Networking:** One VNet + one subnet per environment, each a unique `/24` carved from `192.168.0.0/16` via `cidrsubnet(..., 8, index+10)`.
- **NSG:** Inbound SSH (TCP/22) allowed to the Linux VM NICs (open to `*` by default).
- **Public IPs:** One per Linux VM (dynamic). Web VMs are private only.
- **Linux VM:** Ubuntu 20.04, size `Standard_D2s_v3`, username `SrvUserXX`, password `BestSecurity1` (change this).
- **Web VM:** Ubuntu 20.04 with Apache installed and a sample page, username `WebsrvXX`, password `BestSecurity1` (change this).
- **Optional RDP RG:** A separate RG `SASE-RDPClient` with `resource_group_count` Windows 11 VMs, each with public IP and NSG allowing RDP (TCP/3389).

**Repository Layout**

- `main.tf`: Core lab: RGs, VNets/Subnets, NSGs, public IPs, NICs, Linux + Web VMs, and outputs.
- `rdp.tf`: Optional RDP client RG: VNet, NSG, public IPs, NICs, Windows 11 VMs, and outputs.

**Prerequisites**

- **Azure:** Subscription with permissions to create resource groups, networking, and VMs.
- **CLI/Auth:** `az login` with the target subscription selected, or service principal credentials configured for Terraform.
- **Terraform:** v1.3+ recommended.

**Configuration**

- **Count:** `resource_group_count` (number) — defaults to 12.
- **Subscription:** Provider sets `subscription_id` in `main.tf`. Prefer overriding via env/CLI to avoid hardcoding.
- **Region:** `location` is specified per resource in `main.tf` (default "Sweden Central"). Adjust to your nearest region.
- **RDP Module Vars:** In `rdp.tf` you can set `rdp_location`, `rdp_prefix`, `rdp_vm_size`, `rdp_allowed_cidrs` (default `0.0.0.0/0`; tighten this).
  - Toggle with `enable_rdp` (default `false`). The PowerShell `-AddRdp` flag sets this for you.

Examples:

- Override count at apply: `terraform apply -var "resource_group_count=5"`
- Restrict RDP sources: `-var 'rdp_allowed_cidrs=["203.0.113.4/32"]'`

**Usage**

- **1) Authenticate:** Ensure `az login` and correct subscription selection (`az account set --subscription <SUB_ID>`), or export service principal vars.
- **2) Initialize:** `terraform init`
- **3) Review plan:** `terraform plan`
- **4) Apply:** `terraform apply` and confirm.
- **5) Outputs:** Use `terraform output` to view:
  - `public_ips`: Map of Linux VM names to public IPs.
  - `private_ips_linux`: Map of Linux VM names to private IPs.
  - `private_ips_web`: Map of Web VM names to private IPs.
  - `admin_usernames`: Map of Linux VM names to admin usernames.
  - `web_vm_admin_usernames`: List of web server admin usernames.
  - `rdp_public_ips`, `rdp_mstsc_commands`, `rdp_clients` (when `rdp.tf` is included).

**PowerShell Runner**

- Run via `scripts/Deploy-Lab.ps1` for a streamlined flow (prereq checks, login, subscription selection, Terraform run):
  - Plan: `pwsh scripts/Deploy-Lab.ps1 -Action plan -Count 3`
  - Apply: `pwsh scripts/Deploy-Lab.ps1 -Action apply -Count 3 -AutoApprove`
  - Destroy/Delete: `pwsh scripts/Deploy-Lab.ps1 -Action destroy -AutoApprove` or `-Action delete`
  - Add RDP clients: append `-AddRdp` to include the optional `SASE-RDPClient` stack (disabled by default)
  - Optional params: `-SubscriptionId <GUID>`, `-Region "Sweden Central"`, `-RdpAllowedCidrs @("203.0.113.4/32")`

**Credentials and Access**

- **Linux VMs:** Username `SrvUserXX`, password `BestSecurity1`.
- **Web VMs:** Username `WebsrvXX`, password `BestSecurity1`.
- **Windows VMs (RDP RG):** Username `UserXX`, password `BestSecurity1`.
- Change all default passwords before exposing to the internet. Consider switching to SSH keys for Linux and Just-In-Time access.

**Customizing**

- **Region:** Update the `location` in resources to your preferred region.
- **Sizes:** Adjust `size` for VMs in `main.tf` and `rdp.tf`.
- **Passwords:** Replace hardcoded passwords with variables and mark them sensitive; or switch to key-based auth.
- **Ingress:** Lock down SSH/RDP sources via NSG rules (`source_address_prefix(es)`), e.g., to your office IP.
- **Count:** Tune `resource_group_count` to fit your capacity and budget.

**Costs and Cleanup**

- This lab provisions multiple VMs and public IPs; costs can be significant at default count (12).
- Destroy all resources when done: `terraform destroy`.

**Security Notes**

- **State file:** Terraform state may store sensitive data (including passwords). Do not commit `terraform.tfstate*` to version control; use secure remote state.
- **Open ports:** SSH and RDP are open to the world by default. Restrict `rdp_allowed_cidrs` and update NSG rules.
- **Hardcoded secrets:** Replace the sample passwords and provider `subscription_id` with variables or environment-driven config.

**How Networking Is Allocated**

- Each environment gets a unique `/24` via `cidrsubnet("192.168.0.0/16", 8, index+10)`, used for both the VNet and its single subnet.
- The RDP client RG uses `172.16.0.0/12` with a `/16` subnet named `clients-subnet`.

**Troubleshooting**

- **Auth errors:** Confirm `az login` and the correct subscription, or set `ARM_*` env vars for a service principal.
- **Quota:** VM size/cores may hit regional quotas. Reduce `resource_group_count` or choose a smaller size.
- **Region/Images:** If images are unavailable in your region, switch to a supported offer/sku or region.
- **NSG rules:** If SSH/RDP fails, verify NSG inbound rules and your source IP.

**Caveats**

- The configuration sets `disable_password_authentication = false` for Linux VMs. Consider enabling key-only auth for production-like setups.
- `azurerm_public_ip` for Linux VMs uses `Dynamic` allocation; the IP may change on restart. Use `Static` if you need stable addresses.

**License**

- No explicit license included. Add a LICENSE file if you plan to distribute.
