<#
.SYNOPSIS
  Enterprise-grade Azure ARM deployment automation with parallel jobs, per-job logging, and schema validation.
#>
[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Medium')]
param(
  [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$SpecFile,
  [Parameter()][string]$LogFile,
  [Parameter()][ValidateRange(1,64)][int]$Parallel = 1,
  [switch]$WhatIf
)
$ErrorActionPreference = 'Stop'

function New-LogFilePath {
  param([string]$Given)
  if ($Given) { return $Given }
  $dir = Join-Path -Path (Split-Path -Parent $SpecFile) -ChildPath 'logs'
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
  $ts = (Get-Date).ToString('yyyyMMdd_HHmmss')
  return (Join-Path $dir "AzAutoDeploy_$ts.log")
}
$Script:LogFile = New-LogFilePath -Given $LogFile

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$CoreFile   = Join-Path $ScriptRoot 'AzAutoDeploy.Core.ps1'
if (-not (Test-Path $CoreFile)) { throw "Core functions file not found: $CoreFile" }
. $CoreFile

try {
  Write-Log '=== AzAutoDeploy starting ===' 'INFO'
  Validate-File -Path $SpecFile
  $raw = Get-Content -Raw -Path $SpecFile
  Validate-JsonText -Text $raw
  $spec = $raw | ConvertFrom-Json
  Test-SpecSchema -Spec $spec

  Ensure-AzModules
  Connect-Azure

  if ($Parallel -gt 1 -and $PSVersionTable.PSVersion.Major -lt 7) {
    Write-Log 'Parallel>1 requires PowerShell 7+. Falling back to sequential.' 'WARN'
    $Parallel = 1
  }
  if ($Parallel -gt 1) {
    if (-not (Get-Module -ListAvailable -Name ThreadJob)) {
      Write-Log "Installing ThreadJob module for current user..." 'DEBUG'
      Install-Module -Name ThreadJob -Scope CurrentUser -Force -ErrorAction Stop
    }
    Import-Module ThreadJob -ErrorAction Stop
  }

  Enable-AzContextAutosave -Scope Process | Out-Null
  $ctxFile = Join-Path ([System.IO.Path]::GetTempPath()) ("azctx_{0}.json" -f [guid]::NewGuid())
  Save-AzContext -Path $ctxFile -Force | Out-Null

  if ($Parallel -le 1) {
    foreach ($d in $spec.deployments) {
      Write-Log ("Processing '{0}'" -f $d.name) 'INFO'
      Process-Deployment -D $d -TopSpec $spec -WhatIfPreference $WhatIf | Out-Null
    }
  } else {
    Write-Log ("Running in parallel with ThrottleLimit={0}" -f $Parallel) 'INFO'
    $jobs = @()
    foreach ($d in $spec.deployments) {
      $jobLog = (Join-Path (Split-Path -Parent $Script:LogFile) ("AzAutoDeploy_{0}_{1}.log" -f $d.name, (Get-Date).ToString('yyyyMMdd_HHmmss')))
      Write-Log ("Starting job for '{0}' → log: {1}" -f $d.name, $jobLog) 'DEBUG'
      $jobs += Start-ThreadJob -Name $d.name -ScriptBlock {
        param($innerD, $topSpec, $ctxFilePath, $whatIfFlag, $jobLogPath, $corePath)
        $ErrorActionPreference = 'Stop'
        $Script:LogFile = $jobLogPath
        . $corePath
        Ensure-AzModules
        Import-AzContext -Path $ctxFilePath -ErrorAction Stop | Out-Null
        try {
          Process-Deployment -D $innerD -TopSpec $topSpec -WhatIfPreference $whatIfFlag | Out-Null
        } catch {
          Write-Log ("Job error for '{0}': {1}" -f $innerD.name, $_.Exception.Message) 'ERROR'
          throw
        }
      } -ArgumentList $d, $spec, $ctxFile, [bool]$WhatIf, $jobLog, $CoreFile
    }
    Wait-Job -Job $jobs | Out-Null
    $failed = @()
    foreach ($j in $jobs) {
      $jobError = $null
      $null = Receive-Job -Job $j -Keep -ErrorAction SilentlyContinue -ErrorVariable jobError
      if ($j.State -ne 'Completed') {
        $failed += $j.Name
        if ($jobError) {
          Write-Log ("Job '{0}' failed: {1}" -f $j.Name, ($jobError | Out-String)) 'ERROR'
        } else {
          Write-Log ("Job '{0}' failed with unknown error" -f $j.Name) 'ERROR'
        }
      }
    }
    Remove-Job -Job $jobs -Force | Out-Null
    if ($failed.Count -gt 0) { throw ("One or more parallel deployments failed: {0}" -f ($failed -join ', ')) }
  }
  Write-Log '=== AzAutoDeploy completed successfully ===' 'INFO'
}
catch {
  Write-Log ("Script terminated with error: {0}" -f $_.Exception.Message) 'ERROR'
  exit 1
}
finally {
  if ($ctxFile -and (Test-Path $ctxFile)) { Remove-Item $ctxFile -Force -ErrorAction SilentlyContinue }
}
