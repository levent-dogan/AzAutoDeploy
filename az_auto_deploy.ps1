<#
.SYNOPSIS
    Pro-level AzAutoDeploy.ps1 - Advanced ARM template deployments with thorough pre-checks, validation, retry logic, logging, and governance controls.
.DESCRIPTION
    Reads a JSON spec file defining multiple deployments. For each deployment it:
      - Validates spec schema, files, and checksums
      - Ensures Azure login and required modules
      - Applies pre-checks (file existence, naming conventions)
      - Creates or updates Resource Groups with tags
      - Executes ARM template deployment with retry/exponential backoff
      - Logs detailed progress and errors to console and log file
      - Supports WhatIf mode, parallel deployments, and post-deployment validation
.PARAMETER SpecFile
    Path to the JSON specification file listing deployments.
.PARAMETER LogFile
    Optional path to the log file. Defaults to "AzAutoDeploy.log" alongside the spec file.
.PARAMETER WhatIf
    Switch to run in WhatIf mode to preview changes without actual deployment.
.PARAMETER ParallelDeployments
    Switch to enable parallel deployment of resources. Use with caution.
.PARAMETER MaxParallelJobs
    Maximum number of parallel deployment jobs when using ParallelDeployments. Default is 3.
.EXAMPLE
    .\AzAutoDeploy.ps1 -SpecFile .\deployments.json
.EXAMPLE
    .\AzAutoDeploy.ps1 -SpecFile .\deployments.json -WhatIf
.EXAMPLE
    .\AzAutoDeploy.ps1 -SpecFile .\deployments.json -ParallelDeployments -MaxParallelJobs 5
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$SpecFile,
    
    [Parameter(Mandatory = $false)]
    [string]$LogFile = "$(Join-Path -Path (Split-Path -Parent $SpecFile) -ChildPath 'AzAutoDeploy.log')",
    
    [Parameter(Mandatory = $false)]
    [switch]$WhatIf,
    
    [Parameter(Mandatory = $false)]
    [switch]$ParallelDeployments,
    
    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 10)]
    [int]$MaxParallelJobs = 3
)

# Import required modules
if (-not (Get-Module -ListAvailable -Name Az.Resources)) {
    Install-Module -Name Az.Resources -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
}
Import-Module Az.Resources -ErrorAction Stop

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','DEBUG','WARN','ERROR')][string]$Level = 'INFO'
    )
    $timestamp = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
    $entry = "${timestamp} [$Level] $Message"
    
    # Mask potential sensitive information in logs
    $maskedEntry = $entry -replace '(password|secret|key|token)\s*[:=]\s*[^\s]+', '$1 *****'
    
    Write-Host $maskedEntry
    try {
        Add-Content -Path $LogFile -Value $maskedEntry -ErrorAction SilentlyContinue
    } catch {
        Write-Warning "Could not write to log file: $_"
    }
}

function Validate-File {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { 
        throw "File not found: $Path" 
    }
    Write-Log "File validation successful: $Path" 'DEBUG'
}

function Validate-Json {
    param([Parameter(Mandatory)][string]$Content)
    try { 
        $null = $Content | ConvertFrom-Json -ErrorAction Stop 
        Write-Log "JSON validation successful" 'DEBUG'
    } catch { 
        throw "Invalid JSON content: $_" 
    }
}

function Validate-Checksum {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Expected  # format: sha256:<hex>
    )
    $actual = (Get-FileHash -Path $Path -Algorithm SHA256).Hash
    $expHash = $Expected.Split(':')[1]
    if ($actual -ne $expHash) { 
        throw "Checksum mismatch for $Path. Expected $Expected, got sha256:$actual" 
    }
    Write-Log "Checksum validation successful for $Path" 'DEBUG'
}

function Connect-Azure {
    Write-Log "Checking Azure connection..." 'DEBUG'
    if (-not (Get-AzContext)) {
        Write-Log "Signing into Azure..." 'INFO'
        Connect-AzAccount -ErrorAction Stop
    }
    Write-Log "Azure connection successful" 'DEBUG'
}

function Invoke-DeploymentWithRetry {
    param(
        [Parameter(Mandatory)][pscustomobject]$DeployParams,
        [Parameter(Mandatory)][bool]$WhatIfPreference
    )
    
    # Check if retry policy exists, if not create default
    if (-not $DeployParams.retryPolicy) {
        $DeployParams | Add-Member -MemberType NoteProperty -Name "retryPolicy" -Value @{
            maxAttempts = 3
            delaySeconds = 10
            backoffFactor = 2
        }
        Write-Log "No retry policy specified, using default values" 'WARN'
    }
    
    $attempt = 1
    $max = [int]$DeployParams.retryPolicy.maxAttempts
    $delay = [int]$DeployParams.retryPolicy.delaySeconds
    $factor = [int]$DeployParams.retryPolicy.backoffFactor
    
    while ($attempt -le $max) {
        try {
            Write-Log "Starting deployment '$($DeployParams.name)' (Attempt $attempt/$max)" 'INFO'
            
            # Build deployment parameters
            $deploymentParams = @{
                ResourceGroupName     = $DeployParams.resourceGroup.name
                TemplateFile          = $DeployParams.template.file
                Mode                  = $DeployParams.mode
                ErrorAction           = 'Stop'
            }
            
            # Add template parameter file if specified
            if ($DeployParams.parameters.file) {
                $deploymentParams.TemplateParameterFile = $DeployParams.parameters.file
            }
            
            # Add WhatIf if specified
            if ($WhatIfPreference) {
                $deploymentParams.WhatIf = $true
                Write-Log "Running in WhatIf mode - no actual changes will be made" 'INFO'
            }
            
            # Execute deployment
            $result = New-AzResourceGroupDeployment @deploymentParams
            
            if (-not $WhatIfPreference) {
                Write-Log "Deployment '$($DeployParams.name)' completed: $($result.ProvisioningState)" 'INFO'
                
                # Post-deployment validation
                if ($DeployParams.postDeploymentValidation) {
                    Validate-DeploymentResources -DeployParams $DeployParams -DeploymentResult $result
                }
            } else {
                Write-Log "WhatIf simulation completed for '$($DeployParams.name)'" 'INFO'
            }
            
            return
        } catch {
            Write-Log "Error in deployment '$($DeployParams.name)' on attempt $attempt: $_" 'WARN'
            if ($attempt -lt $max) {
                Write-Log "Retrying in $delay seconds..." 'DEBUG'
                Start-Sleep -Seconds $delay
                $delay = [int]($delay * $factor)
                $attempt++
            } else {
                throw "Deployment '$($DeployParams.name)' failed after $max attempts."
            }
        }
    }
}

function Validate-DeploymentResources {
    param(
        [Parameter(Mandatory)][pscustomobject]$DeployParams,
        [Parameter(Mandatory)][object]$DeploymentResult
    )
    
    Write-Log "Performing post-deployment validation for '$($DeployParams.name)'" 'INFO'
    
    # Check if expected resources were created
    if ($DeployParams.postDeploymentValidation.expectedResources) {
        foreach ($resource in $DeployParams.postDeploymentValidation.expectedResources) {
            $res = Get-AzResource -ResourceGroupName $DeployParams.resourceGroup.name -Name $resource.name -ResourceType $resource.type -ErrorAction SilentlyContinue
            if (-not $res) {
                throw "Expected resource '$($resource.name)' of type '$($resource.type)' was not found"
            }
            Write-Log "Validated resource '$($resource.name)' exists" 'DEBUG'
        }
    }
    
    # Check deployment outputs if specified
    if ($DeployParams.postDeploymentValidation.expectedOutputs) {
        foreach ($outputName in $DeployParams.postDeploymentValidation.expectedOutputs) {
            if (-not $DeploymentResult.Outputs.$outputName) {
                throw "Expected output '$outputName' was not found in deployment results"
            }
            Write-Log "Validated output '$outputName' exists" 'DEBUG'
        }
    }
    
    Write-Log "Post-deployment validation successful for '$($DeployParams.name)'" 'INFO'
}

function Test-SpecSchema {
    param(
        [Parameter(Mandatory)][object]$Spec
    )
    
    Write-Log "Validating spec file schema" 'DEBUG'
    
    # Check if deployments array exists
    if (-not $Spec.deployments) {
        throw "Spec file must contain a 'deployments' array"
    }
    
    # Validate each deployment
    foreach ($deployment in $Spec.deployments) {
        # Required fields
        $requiredFields = @('name', 'template', 'resourceGroup', 'mode')
        foreach ($field in $requiredFields) {
            if (-not $deployment.$field) {
                throw "Deployment '$($deployment.name)' is missing required field: $field"
            }
        }
        
        # Template must have a file
        if (-not $deployment.template.file) {
            throw "Deployment '$($deployment.name)' template must specify a file"
        }
        
        # Resource group must have name and location
        if (-not $deployment.resourceGroup.name -or -not $deployment.resourceGroup.location) {
            throw "Deployment '$($deployment.name)' resource group must specify name and location"
        }
    }
    
    Write-Log "Spec file schema validation successful" 'DEBUG'
}

# === MAIN EXECUTION ===
try {
    Write-Log "=== AzAutoDeploy started ===" 'INFO'
    Write-Log "Running with parameters: SpecFile=$SpecFile, WhatIf=$WhatIf, ParallelDeployments=$ParallelDeployments" 'INFO'
    
    # Spec file validation
    Validate-File $SpecFile
    $raw = Get-Content -Path $SpecFile -Raw
    Validate-Json $raw
    $spec = $raw | ConvertFrom-Json
    
    # Validate spec schema
    Test-SpecSchema -Spec $spec
    
    # Azure connection
    Connect-Azure
    
    # Process deployments
    if ($ParallelDeployments -and $WhatIf -eq $false) {
        Write-Log "Processing deployments in parallel (max $MaxParallelJobs jobs)" 'INFO'
        
        $jobs = @()
        foreach ($d in $spec.deployments) {
            # Check if we've reached the max number of parallel jobs
            while (($jobs | Where-Object { $_.State -eq 'Running' }).Count -ge $MaxParallelJobs) {
                Write-Log "Waiting for available job slot..." 'DEBUG'
                Start-Sleep -Seconds 5
                $jobs = $jobs | Where-Object { $_.State -ne 'Completed' }
            }
            
            # Start a new job for this deployment
            $job = Start-Job -ScriptBlock {
                param($deployment, $whatIf, $logFile)
                
                # Import modules in the job
                Import-Module Az.Resources -ErrorAction Stop
                
                # Define helper functions in the job
                function Write-Log {
                    param(
                        [Parameter(Mandatory)][string]$Message,
                        [ValidateSet('INFO','DEBUG','WARN','ERROR')][string]$Level = 'INFO'
                    )
                    $timestamp = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
                    $entry = "${timestamp} [$Level] [JOB:$($deployment.name)] $Message"
                    
                    # Mask potential sensitive information in logs
                    $maskedEntry = $entry -replace '(password|secret|key|token)\s*[:=]\s*[^\s]+', '$1 *****'
                    
                    Write-Host $maskedEntry
                    try {
                        Add-Content -Path $logFile -Value $maskedEntry -ErrorAction SilentlyContinue
                    } catch {
                        Write-Warning "Could not write to log file: $_"
                    }
                }
                
                # Process the deployment
                try {
                    Write-Log "Starting parallel deployment" 'INFO'
                    
                    # Pre-checks
                    if ($d.preChecks.requireLogin -and -not (Get-AzContext)) { 
                        throw "Not authenticated to Azure before deploying '$($d.name)'" 
                    }
                    
                    if ($d.preChecks.validateTemplateFile) { 
                        if (-not (Test-Path $d.template.file)) { 
                            throw "Template file not found: $($d.template.file)" 
                        }
                    }
                    
                    if ($d.template.checksum) { 
                        $actual = (Get-FileHash -Path $d.template.file -Algorithm SHA256).Hash
                        $expHash = $d.template.checksum.Split(':')[1]
                        if ($actual -ne $expHash) { 
                            throw "Checksum mismatch for $($d.template.file)" 
                        }
                    }
                    
                    if ($d.preChecks.validateParameterFile -and $d.parameters.file) { 
                        if (-not (Test-Path $d.parameters.file)) { 
                            throw "Parameter file not found: $($d.parameters.file)" 
                        }
                    }
                    
                    if ($d.preChecks.validateResourceGroupName) {
                        $rgName = $d.resourceGroup.name
                        if ($rgName.Length -gt 90 -or $rgName -notmatch '^[\w\-\.\(\)]+$') {
                            throw "Invalid resource group name: $rgName" 
                        }
                    }
                    
                    # Resource Group provisioning
                    $existing = Get-AzResourceGroup -Name $d.resourceGroup.name -ErrorAction SilentlyContinue
                    if (-not $existing) {
                        Write-Log "Creating Resource Group '$($d.resourceGroup.name)' in '$($d.resourceGroup.location)'" 'INFO'
                        New-AzResourceGroup -Name $d.resourceGroup.name -Location $d.resourceGroup.location -Tag $d.resourceGroup.tags -ErrorAction Stop
                    } else {
                        Write-Log "Resource Group '$($d.resourceGroup.name)' already exists" 'DEBUG'
                    }
                    
                    # Deployment with retry policy
                    # Check if retry policy exists, if not create default
                    if (-not $d.retryPolicy) {
                        $d | Add-Member -MemberType NoteProperty -Name "retryPolicy" -Value @{
                            maxAttempts = 3
                            delaySeconds = 10
                            backoffFactor = 2
                        }
                    }
                    
                    $attempt = 1
                    $max = [int]$d.retryPolicy.maxAttempts
                    $delay = [int]$d.retryPolicy.delaySeconds
                    $factor = [int]$d.retryPolicy.backoffFactor
                    
                    while ($attempt -le $max) {
                        try {
                            Write-Log "Starting deployment '$($d.name)' (Attempt $attempt/$max)" 'INFO'
                            
                            # Build deployment parameters
                            $deploymentParams = @{
                                ResourceGroupName     = $d.resourceGroup.name
                                TemplateFile          = $d.template.file
                                Mode                  = $d.mode
                                ErrorAction           = 'Stop'
                            }
                            
                            # Add template parameter file if specified
                            if ($d.parameters.file) {
                                $deploymentParams.TemplateParameterFile = $d.parameters.file
                            }
                            
                            # Execute deployment
                            $result = New-AzResourceGroupDeployment @deploymentParams
                            Write-Log "Deployment '$($d.name)' completed: $($result.ProvisioningState)" 'INFO'
                            
                            # Post-deployment validation
                            if ($d.postDeploymentValidation) {
                                Write-Log "Performing post-deployment validation" 'INFO'
                                
                                # Check if expected resources were created
                                if ($d.postDeploymentValidation.expectedResources) {
                                    foreach ($resource in $d.postDeploymentValidation.expectedResources) {
                                        $res = Get-AzResource -ResourceGroupName $d.resourceGroup.name -Name $resource.name -ResourceType $resource.type -ErrorAction SilentlyContinue
                                        if (-not $res) {
                                            throw "Expected resource '$($resource.name)' of type '$($resource.type)' was not found"
                                        }
                                        Write-Log "Validated resource '$($resource.name)' exists" 'DEBUG'
                                    }
                                }
                                
                                # Check deployment outputs if specified
                                if ($d.postDeploymentValidation.expectedOutputs) {
                                    foreach ($outputName in $d.postDeploymentValidation.expectedOutputs) {
                                        if (-not $result.Outputs.$outputName) {
                                            throw "Expected output '$outputName' was not found in deployment results"
                                        }
                                        Write-Log "Validated output '$outputName' exists" 'DEBUG'
                                    }
                                }
                                
                                Write-Log "Post-deployment validation successful" 'INFO'
                            }
                            
                            return $true
                        } catch {
                            Write-Log "Error in deployment '$($d.name)' on attempt $attempt: $_" 'WARN'
                            if ($attempt -lt $max) {
                                Write-Log "Retrying in $delay seconds..." 'DEBUG'
                                Start-Sleep -Seconds $delay
                                $delay = [int]($delay * $factor)
                                $attempt++
                            } else {
                                throw "Deployment '$($d.name)' failed after $max attempts."
                            }
                        }
                    }
                } catch {
                    Write-Log "Deployment failed: $_" 'ERROR'
                    throw $_
                }
            } -ArgumentList $d, $WhatIf, $LogFile
            
            $jobs += $job
            Write-Log "Started job for deployment '$($d.name)' with ID $($job.Id)" 'INFO'
        }
        
        # Wait for all jobs to complete
        Write-Log "Waiting for all deployment jobs to complete" '