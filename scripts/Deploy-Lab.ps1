param(
  [ValidateSet("plan", "apply", "destroy", "delete")]
  [string]$Action = "apply",

  [int]$Count,

  [string]$Region,

  [string[]]$RdpAllowedCidrs,

  [switch]$AutoApprove,

  [string]$SubscriptionId,

  [switch]$AddRdp,

  [string]$ReportPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Info($msg) { Write-Host "[INFO]  $msg" -ForegroundColor Cyan }
function Write-Warn($msg) { Write-Host "[WARN]  $msg" -ForegroundColor Yellow }
function Write-Err ($msg) { Write-Host "[ERROR] $msg" -ForegroundColor Red }

function Test-Command($name) {
  return [bool](Get-Command $name -ErrorAction SilentlyContinue)
}

function Ensure-Prereqs {
  Write-Info "Checking prerequisites (az)..."
  if (-not (Test-Command az)) { throw "Azure CLI ('az') is required. Install from https://aka.ms/azcli" }
}

function Ensure-AzLogin {
  Write-Info "Verifying Azure login..."
  try {
    $null = az account show --only-show-errors | Out-Null
  } catch {
    Write-Warn "Not logged in. Launching 'az login'..."
    az login | Out-Null
  }
}

function Resolve-TerraformExe {
  # Order: explicit env var, PATH, then interactive prompt for full path
  $envVars = @('TF_EXE', 'TERRAFORM_EXE', 'TERRAFORM_PATH')
  foreach ($name in $envVars) {
    $val = [System.Environment]::GetEnvironmentVariable($name)
    if (-not [string]::IsNullOrWhiteSpace($val)) {
      if (Test-Path $val) { Write-Info "Using Terraform from env '$name': $val"; return $val }
      Write-Warn "Env $name is set but path not found: $val"
    }
  }

  if (Test-Command terraform) { return 'terraform' }

  Write-Warn "Terraform not found on PATH and no env override set."
  while ($true) {
    $path = Read-Host "Enter full path to Terraform executable (e.g., C:\\tools\\terraform.exe or /usr/local/bin/terraform)"
    if ([string]::IsNullOrWhiteSpace($path)) { Write-Warn "Path cannot be empty."; continue }
    if (Test-Path $path) { return $path }
    Write-Warn "Path does not exist: $path"
  }
}

function Get-PresetSubscriptionId {
  # Sources (in order): explicit param, env vars, local files
  param([string]$ParamSubId)

  if ($ParamSubId) { return $ParamSubId }
  if ($env:ARM_SUBSCRIPTION_ID) { return $env:ARM_SUBSCRIPTION_ID }
  if ($env:AZURE_SUBSCRIPTION_ID) { return $env:AZURE_SUBSCRIPTION_ID }

  $base = (Get-Location).Path
  $candidates = @(
    (Join-Path -Path $base -ChildPath 'subscription.json')
    (Join-Path -Path $base -ChildPath '.azure-subscription')
    (Join-Path -Path $base -ChildPath 'config/subscription.json')
    (Join-Path -Path $base -ChildPath 'scripts/subscription.json')
  )

  foreach ($path in $candidates) {
    if (Test-Path $path) {
      try {
        if ($path.ToLower().EndsWith('.json')) {
          $json = Get-Content $path -Raw | ConvertFrom-Json
          $id = $json.subscriptionId
          if (-not $id) { $id = $json.subscription_id }
          if (-not $id) { $id = $json.id }
          if ($id) { return $id }
        } else {
          $text = (Get-Content $path -Raw).Trim()
          if ($text) { return $text }
        }
      } catch { }
    }
  }
  return $null
}

function Resolve-Subscription {
  param([string]$ParamSubId)

  $preset = Get-PresetSubscriptionId -ParamSubId $ParamSubId
  if ($preset) {
    Write-Info "Using preset subscription: $preset"
    az account set --subscription $preset | Out-Null
    $selected = az account show | ConvertFrom-Json
    Write-Info "Active subscription: $($selected.name) ($($selected.id))"
    return $selected.id
  }

  try {
    $current = az account show | ConvertFrom-Json
    if ($current -and $current.id) {
      Write-Info "Using current subscription: $($current.name) ($($current.id))"
      return $current.id
    }
  } catch { }

  Write-Warn "No active subscription detected. Fetching available subscriptions..."
  $subs = az account list | ConvertFrom-Json
  if (-not $subs -or $subs.Count -eq 0) {
    throw "No subscriptions available for the logged-in account."
  }

  $default = $subs | Where-Object { $_.isDefault -eq $true } | Select-Object -First 1
  Write-Host "Available subscriptions:" -ForegroundColor Cyan
  for ($i=0; $i -lt $subs.Count; $i++) {
    $mark = if ($subs[$i].isDefault) { '*' } else { ' ' }
    Write-Host ("[{0}] {1} {2} ({3})" -f $i, $mark, $subs[$i].name, $subs[$i].id)
  }
  $sel = Read-Host "Select subscription index (Enter for default)"
  if ([string]::IsNullOrWhiteSpace($sel)) {
    if ($default) { $target = $default } else { $target = $subs[0] }
  } else {
    if ($sel -notmatch '^[0-9]+$' -or [int]$sel -ge $subs.Count) { throw "Invalid selection: $sel" }
    $target = $subs[[int]$sel]
  }

  Write-Info "Setting subscription to: $($target.id)"
  az account set --subscription $target.id | Out-Null
  $selected = az account show | ConvertFrom-Json
  Write-Info "Active subscription: $($selected.name) ($($selected.id))"
  return $selected.id
}

function Select-Subscription {
  param([string]$SubId)
  if ([string]::IsNullOrWhiteSpace($SubId)) {
    $current = az account show | ConvertFrom-Json
    Write-Info "Using current subscription: $($current.name) ($($current.id))"
    return $current.id
  }
  Write-Info "Setting subscription to: $SubId"
  az account set --subscription $SubId | Out-Null
  $selected = az account show | ConvertFrom-Json
  Write-Info "Active subscription: $($selected.name) ($($selected.id))"
  return $selected.id
}

function Build-TerraformArgs {
  param(
    [int]$Count,
    [string]$Region,
    [string[]]$RdpAllowedCidrs,
    [switch]$AddRdp
  )

  # Build a temporary tfvars.json file to avoid quoting issues across shells
  $vars = @{}
  if ($Count) { $vars.resource_group_count = $Count }
  if ($Region) { $vars.rdp_location = $Region }
  if ($RdpAllowedCidrs -and $RdpAllowedCidrs.Count -gt 0) { $vars.rdp_allowed_cidrs = @($RdpAllowedCidrs) }
  if ($AddRdp.IsPresent) { $vars.enable_rdp = $true }

  $args = @()
  if ($vars.Count -gt 0) {
    $scriptRoot = $PSScriptRoot
    if (-not $scriptRoot) { $scriptRoot = Split-Path -Parent $PSCommandPath }
    if (-not $scriptRoot) { $scriptRoot = (Get-Location).Path }
    $repo = Resolve-Path (Join-Path -Path $scriptRoot -ChildPath '..')
    $varDir = Join-Path -Path $repo -ChildPath '.terraform'
    if (-not (Test-Path $varDir)) { New-Item -Path $varDir -ItemType Directory -Force | Out-Null }
    $varFile = Join-Path -Path $varDir -ChildPath 'generated.auto.tfvars.json'
    $json = ($vars | ConvertTo-Json -Depth 5)
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($varFile, $json, $utf8NoBom)
    $args += @('-var-file', $varFile)
  }
  return $args
}

function Invoke-Terraform {
  param(
    [string]$Action,
    [string[]]$ExtraArgs,
    [switch]$AutoApprove,
    [string]$TerraformExe
  )

  $scriptRoot = $PSScriptRoot
  if (-not $scriptRoot) { $scriptRoot = Split-Path -Parent $PSCommandPath }
  if (-not $scriptRoot) { $scriptRoot = (Get-Location).Path }
  $repo = Resolve-Path (Join-Path -Path $scriptRoot -ChildPath '..')
  Push-Location $repo
  try {
    if (-not (Test-Path ".terraform")) {
      Write-Info "terraform init"
      & $TerraformExe init | Write-Host
    }

    switch ($Action) {
      'plan' {
        Write-Info "terraform plan $($ExtraArgs -join ' ')"
        & $TerraformExe plan @ExtraArgs | Write-Host
      }
      'apply' {
        $args = @('apply') + $ExtraArgs
        if ($AutoApprove) { $args += '-auto-approve' }
        Write-Info "terraform $($args -join ' ')"
        & $TerraformExe @args | Write-Host
      }
      'destroy' {
        $args = @('destroy') + $ExtraArgs
        if ($AutoApprove) { $args += '-auto-approve' }
        Write-Info "terraform $($args -join ' ')"
        & $TerraformExe @args | Write-Host
      }
      default { throw "Unknown action: $Action" }
    }
  }
  finally { Pop-Location }
}

function Ensure-ImportExcel {
  param([switch]$AllowInstall)
  $mod = Get-Module -ListAvailable -Name ImportExcel | Select-Object -First 1
  if ($mod) { return $true }
  if ($AllowInstall) {
    try {
      Write-Info "ImportExcel module not found. Attempting install..."
      $currentPolicy = Get-PSRepository -Name 'PSGallery' -ErrorAction SilentlyContinue
      if ($currentPolicy -and $currentPolicy.InstallationPolicy -ne 'Trusted') {
        Set-PSRepository -Name 'PSGallery' -InstallationPolicy Trusted -ErrorAction SilentlyContinue | Out-Null
      }
      Install-Module -Name ImportExcel -Scope CurrentUser -Force -ErrorAction Stop
      return $true
    } catch {
      Write-Warn "Failed to install ImportExcel: $($_.Exception.Message)"
      return $false
    }
  }
  return $false
}

function Get-PasswordsFromTf {
  param([string]$RepoRoot)
  $linuxPass = $null
  $webPass = $null
  $rdpPass = $null
  try {
    $main = Get-Content (Join-Path $RepoRoot 'main.tf') -Raw
    $m = [regex]::Match($main, 'admin_password\s*=\s*"([^"]+)"')
    if ($m.Success) { $linuxPass = $m.Groups[1].Value; $webPass = $linuxPass }
  } catch { }
  try {
    $rdp = Get-Content (Join-Path $RepoRoot 'rdp.tf') -Raw
    $m2 = [regex]::Match($rdp, 'admin_password\s*=\s*"([^"]+)"')
    if ($m2.Success) { $rdpPass = $m2.Groups[1].Value }
  } catch { }
  if (-not $linuxPass) { $linuxPass = 'BestSecurity1' }
  if (-not $webPass)   { $webPass   = $linuxPass }
  if (-not $rdpPass)   { $rdpPass   = 'BestSecurity1' }
  return [pscustomobject]@{ Linux=$linuxPass; Web=$webPass; Rdp=$rdpPass }
}

function Get-TerraformOutputs {
  param([string]$TerraformExe, [string]$RepoRoot)
  Push-Location $RepoRoot
  try {
    $json = & $TerraformExe output -json
    return $json | ConvertFrom-Json
  } finally { Pop-Location }
}

function Generate-LabReport {
  param(
    [string]$TerraformExe,
    [string]$RepoRoot,
    [string]$Path,
    [switch]$AllowModuleInstall
  )

  $outputs = Get-TerraformOutputs -TerraformExe $TerraformExe -RepoRoot $RepoRoot
  $pwds = Get-PasswordsFromTf -RepoRoot $RepoRoot

  $linuxRows = @()
  $webRows = @()
  $rdpRows = @()

  $publicLinux = $outputs.public_ips.value
  $privateLinux = $outputs.private_ips_linux.value
  $adminLinux = $outputs.admin_usernames.value
  foreach ($name in ($adminLinux.Keys | Sort-Object)) {
    $idx = [int]([regex]::Match($name, '\\d+').Value)
    $rg = ('SASE-LAB{0}' -f $idx)
    $linuxRows += [pscustomobject]@{
      ResourceGroup = $rg
      VMName        = $name
      Username      = $adminLinux[$name]
      Password      = $pwds.Linux
      PublicIP      = $publicLinux[$name]
      PrivateIP     = $privateLinux[$name]
      Type          = 'Linux'
    }
  }

  $privateWeb = $outputs.private_ips_web.value
  $webAdmins  = $outputs.web_vm_admin_usernames.value
  foreach ($key in ($privateWeb.Keys | Sort-Object)) {
    $idx = [int]([regex]::Match($key, '\\d+').Value)
    $rg = ('SASE-LAB{0}' -f $idx)
    $username = if ($webAdmins.Count -ge $idx) { $webAdmins[$idx-1] } else { "Websrv{0:d2}" -f $idx }
    $webRows += [pscustomobject]@{
      ResourceGroup = $rg
      VMName        = $key
      Username      = $username
      Password      = $pwds.Web
      PublicIP      = ''
      PrivateIP     = $privateWeb[$key]
      Type          = 'Web'
    }
  }

  if ($outputs.PSObject.Properties.Name -contains 'rdp_clients') {
    $rdpMap = $outputs.rdp_clients.value
    foreach ($user in ($rdpMap.Keys | Sort-Object)) {
      $row = $rdpMap[$user]
      $rdpRows += [pscustomobject]@{
        ResourceGroup = 'SASE-RDPClient'
        VMName        = $row.vm
        Username      = $user
        Password      = $pwds.Rdp
        PublicIP      = $row.ip
        PrivateIP     = ''
        Type          = 'RDP-Client'
      }
    }
  }

  $allRows = $linuxRows + $webRows + $rdpRows
  if (-not $Path) {
    $ts = Get-Date -Format 'yyyyMMdd-HHmmss'
    $Path = Join-Path $RepoRoot ("reports/LabUsers-$ts.xlsx")
  }
  $dir = Split-Path -Parent $Path
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

  if (Ensure-ImportExcel -AllowInstall:$AllowModuleInstall) {
    Import-Module ImportExcel -ErrorAction SilentlyContinue | Out-Null
    $summary = [pscustomobject]@{
      TotalResources = $allRows.Count
      LinuxCount     = $linuxRows.Count
      WebCount       = $webRows.Count
      RdpCount       = $rdpRows.Count
      GeneratedAt    = (Get-Date)
    }
    $null = $summary | Export-Excel -Path $Path -WorksheetName 'Summary' -AutoSize -BoldTopRow -FreezeTopRow -TableName 'Summary' -TableStyle Medium6
    if ($linuxRows.Count -gt 0) { $null = $linuxRows | Export-Excel -Path $Path -WorksheetName 'Linux' -AutoSize -BoldTopRow -FreezeTopRow -TableName 'Linux' -TableStyle Medium6 -Append }
    if ($webRows.Count -gt 0)   { $null = $webRows   | Export-Excel -Path $Path -WorksheetName 'Web'   -AutoSize -BoldTopRow -FreezeTopRow -TableName 'Web'   -TableStyle Medium6 -Append }
    if ($rdpRows.Count -gt 0)   { $null = $rdpRows   | Export-Excel -Path $Path -WorksheetName 'RDP'   -AutoSize -BoldTopRow -FreezeTopRow -TableName 'RDP'   -TableStyle Medium6 -Append }
    Write-Info ("Report written: {0}" -f $Path)
  } else {
    # Fallback to CSVs
    $csvBase = [System.IO.Path]::ChangeExtension($Path, $null)
    $csvDir = Split-Path -Parent $csvBase
    $csvPrefix = Split-Path -Leaf $csvBase
    if ($linuxRows.Count -gt 0) { $linuxRows | Export-Csv -Path (Join-Path $csvDir ("$csvPrefix-Linux.csv")) -NoTypeInformation -Encoding UTF8 }
    if ($webRows.Count -gt 0)   { $webRows   | Export-Csv -Path (Join-Path $csvDir ("$csvPrefix-Web.csv"))   -NoTypeInformation -Encoding UTF8 }
    if ($rdpRows.Count -gt 0)   { $rdpRows   | Export-Csv -Path (Join-Path $csvDir ("$csvPrefix-RDP.csv"))   -NoTypeInformation -Encoding UTF8 }
    Write-Warn "ImportExcel module not available. Generated CSV files instead."
  }
}

# ---- Main flow (mirrors wafaas-style execution) ----
Ensure-Prereqs
Ensure-AzLogin
$activeSub = Resolve-Subscription -ParamSubId $SubscriptionId
# Ensure Terraform provider can read the subscription from environment
$env:ARM_SUBSCRIPTION_ID = $activeSub
$env:AZURE_SUBSCRIPTION_ID = $activeSub
$tfArgs = Build-TerraformArgs -Count $Count -Region $Region -RdpAllowedCidrs $RdpAllowedCidrs -AddRdp:$AddRdp
# Normalize alias
if ($Action -eq 'delete') { $Action = 'destroy' }
$tfExe = Resolve-TerraformExe
Invoke-Terraform -Action $Action -ExtraArgs $tfArgs -AutoApprove:$AutoApprove -TerraformExe $tfExe

Write-Info "Done. Use 'terraform output' to inspect results."

if ($Action -eq 'apply') {
  try {
    $scriptRoot = $PSScriptRoot; if (-not $scriptRoot) { $scriptRoot = Split-Path -Parent $PSCommandPath }
    if (-not $scriptRoot) { $scriptRoot = (Get-Location).Path }
    $repo = Resolve-Path (Join-Path -Path $scriptRoot -ChildPath '..')
    Generate-LabReport -TerraformExe $tfExe -RepoRoot $repo -Path $ReportPath -AllowModuleInstall
  } catch {
    Write-Warn "Failed to generate XLSX/CSV report: $($_.Exception.Message)"
  }
}
