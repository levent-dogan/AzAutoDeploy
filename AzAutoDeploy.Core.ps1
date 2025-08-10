# AzAutoDeploy.Core.ps1 — shared functions for AzAutoDeploy
function Write-Log {
  param(
    [Parameter(Mandatory)][string]$Message,
    [ValidateSet('INFO','DEBUG','WARN','ERROR')][string]$Level = 'INFO'
  )
  $ts = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
  $scrub = $Message -replace '(?i)(password|secret|token|apikey|connectionstring)\s*[:=]\s*\S+','$1=***'
  $line = "$ts [$Level] $scrub"
  Write-Host $line
  if ($Script:LogFile) { Add-Content -Path $Script:LogFile -Value $line }
}
function Validate-File { param([string]$Path) if (-not (Test-Path -LiteralPath $Path)) { throw "File not found: $Path" } }
function Validate-JsonText {
  param([string]$Text)
  try { $null = $Text | ConvertFrom-Json -ErrorAction Stop } catch { throw "Invalid JSON: $($_.Exception.Message)" }
}
function Validate-Checksum {
  param([string]$Path, [string]$Expected) # sha256:<hex>
  if (-not $Expected) { return }
  $algo, $hash = $Expected.Split(':',2)
  if ($algo -ne 'sha256') { throw "Unsupported checksum algo '$algo' (only sha256)." }
  $actual = (Get-FileHash -Path $Path -Algorithm SHA256).Hash
  if ($actual -ne $hash) { throw "Checksum mismatch for $Path. expected=$Expected actual=sha256:$actual" }
}
function Ensure-AzModules {
  $modules = @('Az.Accounts','Az.Resources')
  foreach ($m in $modules) {
    if (-not (Get-Module -ListAvailable -Name $m)) {
      Write-Log "Installing $m module for current user..." 'DEBUG'
      Install-Module -Name $m -Scope CurrentUser -Force -ErrorAction Stop
    }
    Import-Module $m -ErrorAction Stop
  }
}
function Connect-Azure {
  if (-not (Get-AzContext)) {
    Write-Log 'Signing into Azure account...' 'INFO'
    Connect-AzAccount -ErrorAction Stop | Out-Null
  }
}
function Get-TemplateParameterObject {
  param([pscustomobject]$ParametersSpec)
  $obj = @{}
  if ($ParametersSpec -and $ParametersSpec.file) {
    Validate-File $ParametersSpec.file
    $pjson = Get-Content -Raw -Path $ParametersSpec.file | ConvertFrom-Json
    if ($pjson.parameters) {
      foreach ($k in $pjson.parameters.PSObject.Properties.Name) { $obj[$k] = $pjson.parameters.$k.value }
    } else {
      foreach ($k in $pjson.PSObject.Properties.Name) { $obj[$k] = $pjson.$k }
    }
    if ($ParametersSpec.checksum) { Validate-Checksum -Path $ParametersSpec.file -Expected $ParametersSpec.checksum }
  }
  if ($ParametersSpec -and $ParametersSpec.overrides) {
    foreach ($name in $ParametersSpec.overrides.PSObject.Properties.Name) { $obj[$name] = $ParametersSpec.overrides.$name }
  }
  return $obj
}
function Test-SpecSchema {
  param([psobject]$Spec)
  if (-not $Spec) { throw 'Spec is empty.' }
  if (-not $Spec.PSObject.Properties.Match('deployments')) { throw "Spec must contain a 'deployments' array." }
  if ($Spec.deployments.Count -lt 1) { throw 'Spec has no deployments.' }
  foreach ($d in $Spec.deployments) {
    foreach ($req in 'name','resourceGroup','template') { if (-not $d.PSObject.Properties.Match($req)) { throw "Deployment missing '$req'" } }
    if (-not $d.resourceGroup.name) { throw "Deployment '$($d.name)': resourceGroup.name is required." }
    if (-not $d.resourceGroup.location) { throw "Deployment '$($d.name)': resourceGroup.location is required." }
    if (-not $d.template.file) { throw "Deployment '$($d.name)': template.file is required." }
    if (-not $d.mode) { $d | Add-Member -NotePropertyName mode -NotePropertyValue 'Incremental' }
    if (-not $d.preChecks) { $d | Add-Member -NotePropertyName preChecks -NotePropertyValue ([pscustomobject]@{ requireLogin=$true; validateTemplateFile=$true; validateParameterFile=$true; validateResourceGroupName=$true }) }
    if (-not $d.retryPolicy) { $d | Add-Member -NotePropertyName retryPolicy -NotePropertyValue ([pscustomobject]@{ maxAttempts=3; delaySeconds=5; backoffFactor=2 }) }
    if (-not $d.parameters) { $d | Add-Member -NotePropertyName parameters -NotePropertyValue ([pscustomobject]@{}) }
  }
}
function Set-DeploymentSubscriptionIfAny {
  param([pscustomobject]$Deployment, [pscustomobject]$TopSpec)
  $targetSub = if ($Deployment.subscriptionId) { $Deployment.subscriptionId } elseif ($TopSpec.subscriptionId) { $TopSpec.subscriptionId } else { $null }
  if ($targetSub) {
    $ctx = Get-AzContext
    if (-not $ctx -or $ctx.Subscription.Id -ne $targetSub) {
      Write-Log "Switching context to subscription $targetSub" 'INFO'
      Set-AzContext -SubscriptionId $targetSub -ErrorAction Stop | Out-Null
    }
  }
}
function New-OrUpdate-ResourceGroup {
  param([pscustomobject]$D, [bool]$WhatIfPreference)
  $rgName = $D.resourceGroup.name
  $rgLoc  = $D.resourceGroup.location
  $rgTags = $D.resourceGroup.tags
  if ($D.preChecks.validateResourceGroupName) {
    if ($rgName.Length -gt 90 -or $rgName.Length -lt 1 -or $rgName -notmatch '^[-\w\._\(\)]+$') {
      throw "Invalid resource group name: $rgName. Name must be 1–90 chars and contain only alphanumerics, underscores, periods, hyphens, and parenthesis."
    }
  }
  $rg = Get-AzResourceGroup -Name $rgName -ErrorAction SilentlyContinue
  if (-not $rg) {
    if ($WhatIfPreference) {
      Write-Log "WhatIf: Would create Resource Group '$rgName' in '$rgLoc' with tags $(($rgTags | ConvertTo-Json -Compress))" 'INFO'
    } else {
      Write-Log "Creating Resource Group '$rgName' in '$rgLoc'" 'INFO'
      New-AzResourceGroup -Name $rgName -Location $rgLoc -Tag $rgTags -ErrorAction Stop | Out-Null
    }
  } else {
    Write-Log "Resource Group '$rgName' exists; tags may be updated by templates." 'DEBUG'
  }
}
function Invoke-DeploymentWithRetry {
  param([pscustomobject]$D, [bool]$WhatIfPreference)
  $max    = [int]$D.retryPolicy.maxAttempts
  $delay  = [int]$D.retryPolicy.delaySeconds
  $factor = [int]$D.retryPolicy.backoffFactor
  if ($D.preChecks.validateTemplateFile) { Validate-File -Path $D.template.file }
  if ($D.template.checksum) { Validate-Checksum -Path $D.template.file -Expected $D.template.checksum }
  if ($D.preChecks.validateParameterFile -and $D.parameters.file) { Validate-File -Path $D.parameters.file }
  $paramObject = Get-TemplateParameterObject -ParametersSpec $D.parameters
  for ($i = 1; $i -le $max; $i++) {
    try {
      Write-Log "[Attempt $i/$max] Deploying '$($D.name)' to RG '$($D.resourceGroup.name)' (Mode=$($D.mode))" 'INFO'
      $args = @{
        Name = $D.name
        ResourceGroupName = $D.resourceGroup.name
        TemplateFile = $D.template.file
        Mode = $D.mode
        ErrorAction = 'Stop'
      }
      if ($paramObject.Count -gt 0) { $args['TemplateParameterObject'] = $paramObject } else { if ($D.parameters.file) { $args['TemplateParameterFile'] = $D.parameters.file } }
      if ($WhatIfPreference) { $args['WhatIf'] = $true }
      $result = New-AzResourceGroupDeployment @args
      Write-Log "Provisioning state: $($result.ProvisioningState)" 'INFO'
      return $result
    } catch {
      Write-Log ("Deployment error for '{0}': {1}" -f $D.name, $_.Exception.Message) 'WARN'
      if ($i -lt $max) {
        Write-Log "Retrying in $delay sec..." 'DEBUG'
        Start-Sleep -Seconds $delay
        $delay = [int]($delay * $factor)
      } else {
        throw "Deployment '$($D.name)' failed after $max attempts."
      }
    }
  }
}
function Verify-Deployment {
  param([pscustomobject]$D, [bool]$WhatIfPreference)
  $dep = Get-AzResourceGroupDeployment -ResourceGroupName $D.resourceGroup.name -Name $D.name -ErrorAction SilentlyContinue
  if ($dep -and $dep.ProvisioningState -eq 'Succeeded') {
    Write-Log "Post-verification OK for '$($D.name)'" 'INFO'
  } elseif ($WhatIfPreference) {
    Write-Log "WhatIf mode: skipping post-verification for '$($D.name)'" 'DEBUG'
  } else {
    throw "Post-verification failed for '$($D.name)'."
  }
}
function Process-Deployment {
  param([pscustomobject]$D, [pscustomobject]$TopSpec, [bool]$WhatIfPreference)
  try {
    Set-DeploymentSubscriptionIfAny -Deployment $D -TopSpec $TopSpec
    New-OrUpdate-ResourceGroup -D $D -WhatIfPreference $WhatIfPreference
    $res = Invoke-DeploymentWithRetry -D $D -WhatIfPreference $WhatIfPreference
    if (-not $WhatIfPreference) { Verify-Deployment -D $D -WhatIfPreference $WhatIfPreference }
    return $res
  } catch {
    Write-Log ("FATAL in '{0}': {1}" -f $D.name, $_.Exception.Message) 'ERROR'
    throw
  }
}
