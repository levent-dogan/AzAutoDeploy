# Pester tests for AzAutoDeploy (Pester v5)
$ErrorActionPreference = 'Stop'

BeforeAll {
    $root     = Split-Path -Parent $PSScriptRoot
  $corePath = Join-Path $root 'AzAutoDeploy.Core.ps1'
  . $corePath

    Set-Item -Path function:Get-AzContext -Value {
    @{ Subscription = @{ Id = '00000000-0000-0000-0000-000000000000' } }
  }.GetNewClosure()

  Set-Item -Path function:Set-AzContext -Value {
    param([string]$SubscriptionId) $global:CtxSub = $SubscriptionId
  }.GetNewClosure()

  Set-Item -Path function:Get-AzResourceGroup -Value {
    param([string]$Name) $null   # RG yokmuş gibi döndür
  }.GetNewClosure()

  Set-Item -Path function:New-AzResourceGroup -Value {
    param([string]$Name, [string]$Location, [hashtable]$Tag)
    @{ Name = $Name; Location = $Location }
  }.GetNewClosure()

    $global:LastDeploymentName = $null
  Set-Item -Path function:New-AzResourceGroupDeployment -Value {
    param(
      [Parameter(Mandatory)]$Name,
      [Parameter(Mandatory)]$ResourceGroupName,
      [Parameter(Mandatory)]$TemplateFile,
      [string]$Mode,
      $TemplateParameterObject,
      $TemplateParameterFile,
      [switch]$WhatIf
    )
    $global:LastDeploymentName = $Name
    @{ Name = $Name; ProvisioningState = 'Succeeded' }
  }.GetNewClosure()

  Set-Item -Path function:Get-AzResourceGroupDeployment -Value {
    param([string]$ResourceGroupName, [string]$Name)
    @{ ProvisioningState = 'Succeeded' }
  }.GetNewClosure()

  Mock -CommandName Validate-File
}

Describe 'Spec schema & defaults' {
  It 'accepts minimal valid spec and applies defaults' {
    $spec = [pscustomobject]@{
      version = '1.1'
      deployments = @(
        [pscustomobject]@{
          name = 'UnitTest-01'
          resourceGroup = [pscustomobject]@{ name = 'rg-ut'; location = 'East US' }
          template      = [pscustomobject]@{ file = 'templates/ut.json' }
        }
      )
    }
    { Test-SpecSchema -Spec $spec } | Should -Not -Throw
    $spec.deployments[0].retryPolicy | Should -Not -BeNullOrEmpty
    $spec.deployments[0].mode        | Should -Be 'Incremental'
  }
}

Describe 'Parameter overrides merging' {
  It 'merges file parameters with overrides (overrides win)' {
    $tmp = New-TemporaryFile
    try {
      $paramObj = @{ parameters = @{ size = @{ value = 'S1' }; nodes = @{ value = 1 } } } | ConvertTo-Json -Depth 5
      Set-Content -Path $tmp -Value $paramObj -Encoding UTF8

      $spec = [pscustomobject]@{
        parameters = [pscustomobject]@{
          file = $tmp
          overrides = [pscustomobject]@{ nodes = 3 }
        }
      }

      $merged = Get-TemplateParameterObject -ParametersSpec $spec.parameters
      $merged['size']  | Should -Be 'S1'
      $merged['nodes'] | Should -Be 3
    }
    finally { Remove-Item -Path $tmp -Force -ErrorAction SilentlyContinue }
  }
}

Describe 'Deployment name binding' {
  It 'passes -Name from spec.name to deployment cmdlet' {
    $global:LastDeploymentName = $null
    $d = [pscustomobject]@{
      name = 'UnitTest-Name'
      resourceGroup = [pscustomobject]@{ name = 'rg-ut'; location = 'East US' }
      template      = [pscustomobject]@{ file = 'templates/ut.json' }
      parameters    = [pscustomobject]@{}
      mode          = 'Incremental'
      preChecks     = [pscustomobject]@{ validateTemplateFile=$true; validateParameterFile=$false; validateResourceGroupName=$true }
      retryPolicy   = [pscustomobject]@{ maxAttempts=1; delaySeconds=1; backoffFactor=2 }
    }
    { Invoke-DeploymentWithRetry -D $d -WhatIfPreference $false } | Should -Not -Throw
    $global:LastDeploymentName | Should -Be 'UnitTest-Name'
  }
}

Describe 'Checksum validation' {
  It 'throws on checksum mismatch' {
    $tmp = New-TemporaryFile
    try {
      Set-Content -Path $tmp -Value 'abc' -Encoding UTF8
      { Validate-Checksum -Path $tmp -Expected 'sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff' } | Should -Throw
    }
    finally { Remove-Item -Path $tmp -Force -ErrorAction SilentlyContinue }
  }

  It 'does not throw on correct checksum' {
    $tmp = New-TemporaryFile
    try {
      Set-Content -Path $tmp -Value 'abc' -Encoding UTF8
      $hash = (Get-FileHash -Path $tmp -Algorithm SHA256).Hash
      { Validate-Checksum -Path $tmp -Expected ("sha256:{0}" -f $hash) } | Should -Not -Throw
    }
    finally { Remove-Item -Path $tmp -Force -ErrorAction SilentlyContinue }
  }
}

Describe 'WhatIf path' {
  It 'skips post-verification when WhatIf is set' {
    $d = [pscustomobject]@{
      name = 'UT-WhatIf'
      resourceGroup = [pscustomobject]@{ name = 'rg-ut'; location = 'East US' }
      template      = [pscustomobject]@{ file = 'templates/ut.json' }
      parameters    = [pscustomobject]@{}
      mode          = 'Incremental'
      preChecks     = [pscustomobject]@{ validateTemplateFile=$true; validateParameterFile=$false; validateResourceGroupName=$true }
      retryPolicy   = [pscustomobject]@{ maxAttempts=1; delaySeconds=1; backoffFactor=2 }
    }
    { Process-Deployment -D $d -TopSpec ([pscustomobject]@{}) -WhatIfPreference $true } | Should -Not -Throw
  }
}
