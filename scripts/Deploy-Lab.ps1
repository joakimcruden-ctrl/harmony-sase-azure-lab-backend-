param(
  [ValidateSet("plan", "apply", "destroy", "delete")]
  [string]$Action = "apply",

  [int]$Count,

  [string]$Region,

  [string[]]$RdpAllowedCidrs,

  [switch]$AutoApprove,

  [string]$SubscriptionId,

  [switch]$AddRdp
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
  Write-Info "Checking prerequisites (az, terraform)..."
  if (-not (Test-Command az)) { throw "Azure CLI ('az') is required. Install from https://aka.ms/azcli" }
  if (-not (Test-Command terraform)) { throw "Terraform is required. Install from https://www.terraform.io/downloads.html" }
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
    [string]$SubscriptionId,
    [switch]$AddRdp
  )

  $args = @()
  if ($Count) { $args += @('-var', "resource_group_count=$Count") }
  if ($Region) { $args += @('-var', "rdp_location=$Region") }
  if ($RdpAllowedCidrs -and $RdpAllowedCidrs.Count -gt 0) {
    $cidrs = $RdpAllowedCidrs | ForEach-Object { '"' + $_ + '"' } | -join ','
    $args += @('-var', "rdp_allowed_cidrs=[$cidrs]")
  }
  if ($SubscriptionId) { $args += @('-var', "subscription_id=$SubscriptionId") }
  if ($AddRdp.IsPresent) { $args += @('-var', 'enable_rdp=true') }
  return $args
}

function Invoke-Terraform {
  param(
    [string]$Action,
    [string[]]$ExtraArgs,
    [switch]$AutoApprove
  )

  $root = Split-Path -Parent $MyInvocation.MyCommand.Path
  $repo = Resolve-Path (Join-Path $root '..')
  Push-Location $repo
  try {
    if (-not (Test-Path ".terraform")) {
      Write-Info "terraform init"
      terraform init | Write-Host
    }

    switch ($Action) {
      'plan' {
        Write-Info "terraform plan $($ExtraArgs -join ' ')"
        terraform plan @ExtraArgs | Write-Host
      }
      'apply' {
        $args = @('apply') + $ExtraArgs
        if ($AutoApprove) { $args += '-auto-approve' }
        Write-Info "terraform $($args -join ' ')"
        terraform @args | Write-Host
      }
      'destroy' {
        $args = @('destroy') + $ExtraArgs
        if ($AutoApprove) { $args += '-auto-approve' }
        Write-Info "terraform $($args -join ' ')"
        terraform @args | Write-Host
      }
      default { throw "Unknown action: $Action" }
    }
  }
  finally { Pop-Location }
}

# ---- Main flow (mirrors wafaas-style execution) ----
Ensure-Prereqs
Ensure-AzLogin
$activeSub = Select-Subscription -SubId $SubscriptionId
$tfArgs = Build-TerraformArgs -Count $Count -Region $Region -RdpAllowedCidrs $RdpAllowedCidrs -SubscriptionId $activeSub -AddRdp:$AddRdp
# Normalize alias
if ($Action -eq 'delete') { $Action = 'destroy' }
Invoke-Terraform -Action $Action -ExtraArgs $tfArgs -AutoApprove:$AutoApprove

Write-Info "Done. Use 'terraform output' to inspect results."
