# AzAutoDeploy

**Next‑gen ARM template deployment automation for Azure**

AzAutoDeploy is a professional PowerShell tool (`AzAutoDeploy.ps1`) that reads a flexible JSON spec and executes one or more ARM template deployments. It addresses advanced governance, reliability, and security requirements, making it ideal for enterprise‑grade pipelines.

---

## 🚀 Features

- **Spec Schema Validation**: Ensures all required fields exist using `Test-SpecSchema` before execution.
- **Dynamic Retry Policy**: Applies defaults if `retryPolicy` is missing; supports max attempts, initial delay, and exponential backoff.
- **WhatIf Support**: Simulate deployments with `-WhatIf` switch to preview changes safely.
- **Parallel Deployments**: Process multiple entries concurrently using background jobs or runspaces.
- **Post‑Deployment Verification**: Validates created resources exist and match expected state.
- **Sensitive Data Protection**: Redacts secrets or credentials from log output.
- **Enhanced Error Handling**: Contextual, user‑friendly messages with error codes and guidance.
- **Module & Environment Checks**: Auto‑installs/loads required `Az.*` modules and confirms PowerShell version.
- **Flexible Parameters**: Accepts inline overrides or external parameter files for each deployment.
- **Comprehensive Logging**: Timestamped logs (`INFO`, `DEBUG`, `WARN`, `ERROR`) to console and file, without leaking secrets.
- **Extensive Documentation**: Built‑in `Get-Help` support and detailed code comments for maintainability.

---

## 📋 Prerequisites

1. **PowerShell 7+** (recommended) or Windows PowerShell 5.1
2. **Internet access** for `Install-Module` if missing
3. **Az.Resources** (installed automatically) and any other Az modules used by your templates
4. **Azure credentials** with permission to create/update Resource Groups and deploy resources

---

## 🛠️ Installation

```bash
git clone https://github.com/YourOrg/AzAutoDeploy.git
cd AzAutoDeploy
```

```powershell
# Allow script execution if needed
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

---

## ⚙️ Spec File: `deployments.json`

Example structure illustrating advanced schema, defaults, and overrides:

```json
{
  "$schema": "https://example.com/schemas/azautodeploy.schema.json",
  "version": "1.0",
  "deployments": [
    {
      "name": "AppService-Dev",
      "resourceGroup": {
        "name": "rg-AppService-Dev",
        "location": "East US",
        "tags": { "environment": "Dev", "owner": "TeamA", "project": "CoolApp" }
      },
      "template": { "file": "templates/appservice.json", "checksum": "sha256:<hex>" },
      "parameters": {
        "file": "parameters/appservice.dev.parameters.json",
        "overrides": { "sku": "S1", "workerSize": 0 }
      },
      "mode": "Incremental",
      "preChecks": {
        "requireLogin": true,
        "validateTemplateFile": true,
        "validateParameterFile": true,
        "validateResourceGroupName": true
      },
      "retryPolicy": { "maxAttempts": 3, "delaySeconds": 15, "backoffFactor": 2 }
    }
    // more entries...
  ]
}
```

**Key Fields & Defaults**:

| Field                  | Description                                        | Default                                              |
| ---------------------- | -------------------------------------------------- | ---------------------------------------------------- |
| `name`                 | Unique identifier for logs and parallel job naming | *Required*                                           |
| `resourceGroup`        | RG name, location, tags for cost/governance        | *Required*                                           |
| `template.file`        | Path to ARM template                               | *Required*                                           |
| `template.checksum`    | SHA256 hash for integrity verification             | *Optional*                                           |
| `parameters.file`      | Path to parameter JSON                             | *Optional*                                           |
| `parameters.overrides` | Inline parameter overrides                         | *Optional*                                           |
| `mode`                 | `Incremental` or `Complete`                        | `Incremental`                                        |
| `preChecks.*`          | Toggles for various validations                    | `true` for essentials                                |
| `retryPolicy.*`        | Controls retry behavior                            | `maxAttempts=3`, `delaySeconds=5`, `backoffFactor=2` |

---

## ▶️ Usage

```powershell
# Standard deployment
.
\AzAutoDeploy.ps1 -SpecFile .\deployments.json

# With custom log path and WhatIf simulation
.
\AzAutoDeploy.ps1 -SpecFile .\deployments.json -LogFile .\logs\deploy.log -WhatIf

# Enable parallelism (e.g. 4 concurrent jobs)
.
\AzAutoDeploy.ps1 -SpecFile .\deployments.json -Parallel 4
```

The script will:

1. Validate the spec schema and required fields
2. Load/install Az modules and confirm login
3. Execute pre‑checks (files, naming, checksums)
4. Create/update Resource Groups with tags
5. Run deployments (with retry & backoff or simulate via `-WhatIf`)
6. Verify resource existence post‑deployment
7. Log all steps without exposing secrets

---

## 📑 Logging & Output

- **Console**: Color‑coded, leveled messages
- **Log file**: Daily rollover or custom path
- **Entry example**:
  ```
  2025-08-06T23:00:12 [INFO] Processing 'AppService-Dev' (Job 2 of 5)
  ```

---

## 🚧 Advanced Options

- `-Parallel <int>`: Number of concurrent deployment jobs
- `-WhatIf`: PowerShell’s native simulation
- `-Force`: Skip confirm prompts for RG creation

---

## 🤝 Contributing

1. Fork & branch from `main`
2. Add new validations, integrations, or fixes
3. Update schema and tests
4. Submit PR with clear description and examples

---

*Crafted with care for rock‑solid Azure deployments!*

