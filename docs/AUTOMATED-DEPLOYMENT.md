# VMRay Sandbox Outlook Attachment (Microsoft Sentinel) — Automated Deployment Guide

This guide covers the single-command deployment of the **VMRay-Sandbox_Outlook_Attachment** Microsoft Sentinel playbook and the **VMRay Enrichment Function App** it depends on. The playbook watches an Office 365 mailbox, submits email attachments to the VMRay sandbox, and — when a sample is malicious or suspicious — creates a Microsoft Sentinel incident, uploads the resulting IOCs to Sentinel Threat Intelligence, and emails a verdict summary.

---

## Introduction

### Microsoft Sentinel + VMRay

This playbook enriches Microsoft Sentinel with VMRay (FinalVerdict / TotalInsight) analysis of email attachments. It:

- **Analyzes email attachments** — every attachment on incoming mail in the monitored mailbox is submitted to the VMRay sandbox for dynamic analysis.
- **Creates Sentinel incidents** — for non-clean verdicts, it opens an incident carrying the VMRay verdict, threat names, classifications, VTI score, and a link to the full VMRay report.
- **Feeds Threat Intelligence** — malicious/suspicious IOCs are uploaded into Microsoft Sentinel Threat Intelligence.
- **Notifies analysts** — sends an HTML verdict-summary email.

### Solution Overview

The deployment has two Azure pieces that work together:

1. **VMRay Enrichment Function App** — a Python Function App exposing the helper functions the playbook calls (`VMRayUploadSample`, `GetVMRaySubmission`, `GetVMRaySample`, `GetVMRayIOCs`). Its code is delivered via `WEBSITE_RUN_FROM_PACKAGE`, so there is no manual code-publish step.
2. **VMRay-Sandbox_Outlook_Attachment playbook** — a Logic App triggered on new mail with attachments. It uploads each attachment through the Function App, waits for the analysis, then creates the incident, uploads IOCs, and sends the summary email. It writes to Sentinel through its own **managed identity**.

The playbook references the Function App by a name built from `uniqueString(resourceGroup().id)`, so **both must deploy into the same resource group** for the names to line up — the script enforces this.

### About VMRay

VMRay is a leading provider of automated malware analysis and advanced threat detection. Using hypervisor-based sandboxing, VMRay delivers deep visibility into sophisticated and evasive threats.

---

## Prerequisites

| Requirement | Why |
|---|---|
| **Azure Subscription** | To host the Function App, Storage, and Logic App |
| **Microsoft Sentinel + Log Analytics workspace** | The target for incidents and Threat Intelligence indicators |
| **Rights to create resources and assign roles** | The script creates resources and grants the playbook's managed identity a role. You need **Owner** or **Contributor + User Access Administrator** on the resource group / workspace |
| **An Office 365 mailbox to monitor** | The playbook triggers on mail arriving in this mailbox; you sign in as it to authorize the connection |
| **VMRay FinalVerdict / TotalInsight** | The sandbox that analyzes the attachments |
| **VMRay Connector API key** | Created in the VMRay Console (see below). Used to configure the Function App |
| **PowerShell environment** | Azure Cloud Shell (PowerShell), or a local shell with the Az modules |

> **No App Registration is required.** Unlike the Defender-for-Endpoint and MDO connectors, this playbook needs no Entra App Registration, client secret, or admin consent — the Function App takes only the VMRay URL/key, and the playbook authenticates to Sentinel with its own managed identity.

### Create a VMRay Connector API key

In the VMRay Console:

1. Create a dedicated user for this API key (so the key isn't deleted if an employee leaves).
2. Create a role that allows *"View shared submission, analysis and sample"* and *"Submit sample, manage own jobs, reanalyse old analyses and regenerate analysis reports"*.
3. Assign the role to the user.
4. Sign in as that user and create an API key under **Settings → Analysis → API Keys**.
5. Save the key — you'll paste it into the script during Phase 1.

---

## Deployment Overview

The Azure-side deployment is driven by a single interactive PowerShell script with three phases:

| Phase | What it does | Manual? |
|---|---|---|
| **0. Pre-flight** | Loads modules, connects to Azure, offers a subscription picker, creates/reuses the resource group, and collects the shared inputs (Function App base name + Log Analytics workspace) | Automated |
| **1. Function App** | Deploys the VMRay Enrichment Function App via ARM (VMRay URL/key, resubmit flag, App Insights workspace) | Automated |
| **2. Playbook** | Deploys the VMRay-Sandbox_Outlook_Attachment Logic App **into the same RG**, plus its `office365` and `azuresentinel` API connections | Automated |
| **3. Role assignment** | Grants the playbook's managed identity the **Microsoft Sentinel Contributor** role on the workspace (with retry for identity replication) | Automated |

After the script finishes, there are **three manual steps it cannot perform** (it prints them in the final summary):

1. **Authorize the `office365` API connection** — an interactive OAuth sign-in (as the monitored mailbox). ARM creates the connection, but a human must click **Authorize**.
2. **Set the email recipient** — the playbook's *Send an email (V2)* action ships a placeholder address (`abc@abc.com`); change it to your real recipient.
3. **Enable the playbook** — it deploys **Disabled** and must be enabled before it will trigger.

> The `azuresentinel` connection uses the playbook's managed identity, so it needs **no** interactive authorization — the Phase 3 role assignment covers it.

---

## Quick Start — Azure Cloud Shell

1. Sign in to the [Azure Portal](https://portal.azure.com) and open **`>_`** Cloud Shell → **PowerShell**.
2. **Manage files → Upload** just the deployment script:
   - `Scripts/Deploy-VMRayOutlookAttachmentPlaybook.ps1`
3. Run it:
   ```powershell
   ./Deploy-VMRayOutlookAttachmentPlaybook.ps1
   ```

The two ARM templates are fetched directly from GitHub by the script — there's no need to upload them.

> **Offline / customized templates:** if you've edited a template or your environment can't reach GitHub, upload the JSON files alongside the script and pass them explicitly (a local file takes precedence over the GitHub URL). Give them distinct names on upload:
> ```powershell
> ./Deploy-VMRayOutlookAttachmentPlaybook.ps1 `
>   -FunctionTemplateFile ~/VMRayEnrichment.azuredeploy.json `
>   -PlaybookTemplateFile ~/OutlookAttachment.azuredeploy.json
> ```

The script is fully interactive — it prompts for everything it needs. Default values appear in brackets; press Enter to accept.

You'll be asked (in order):

| Prompt | What to enter |
|---|---|
| Confirm tenant + subscription | If only one subscription is accessible, press Enter to confirm. If multiple, choose 1 for the current one or 2 to pick another. |
| Resource group name | Existing RG, or a new name (created if missing). **Both resources deploy here.** |
| Azure region | **Only asked if the RG is new.** A reused RG uses its existing location. |
| Function App base name | Press Enter for default (`vmrayenrich`). **Lowercase letters/numbers only, ≤ 20 chars** (it's also the storage account name). A 3-char hash is appended. |
| Log Analytics / Sentinel workspace | Pick from the list. One pick supplies the App Insights workspace, the playbook's Workspace Name, and its Workspace ID. Choose *Enter values manually* to type them. |
| VMRay Base URL | **1** `https://eu.cloud.vmray.com`, **2** `https://us.cloud.vmray.com`, or **3** to enter your own. |
| VMRay API Key | Paste your VMRay connector API key (input hidden; required). |
| Resubmit samples even if the hash was seen? | Press Enter for **Yes** (matches the template default). |
| Proceed with Function App deployment? | Press Enter to confirm. |
| Playbook (Logic App) name | Press Enter for default (`VMRay-Sandbox_Outlook_Attachment`), or enter your own. |
| Proceed with playbook deployment? | Press Enter to confirm. |

A Function App deploy can take several minutes with little console output while the package unpacks — this is normal, don't cancel.

### After the script — complete the three manual steps

See **[Post-deployment: manual steps](#post-deployment-manual-steps)** below.

---

## Post-deployment: manual steps

### 1. Authorize the `office365` connection

1. Azure Portal → top search **API Connections** (or your resource group → **API Connection** type).
2. Open **`office365-<PlaybookName>`** → **Edit API connection** → **Authorize**.
3. Sign in as the **mailbox that receives the emails to analyze** → **Save**. Status should read **Connected**.

> The API Connections blade can show a stale list right after deployment. If you don't see the connection, click **Refresh**, or open it from **Resource group → (your RG) → API Connection**, or from the Logic App's **API connections** menu.

### 2. Set the email recipient

Open the Logic App **`<PlaybookName>`** in the designer → the **Send an email (V2)** action → replace the placeholder `abc@abc.com` with your real recipient → **Save**.

### 3. Enable the playbook

Logic App **`<PlaybookName>`** → **Overview** → **Enable**. It deployed *Disabled* and won't trigger until enabled.

---

## Re-deployment / running one phase at a time

The script is idempotent and supports skip flags so you can re-run a single phase:

```powershell
# Re-run only the playbook + role assignment, reusing an existing Function App
./Deploy-VMRayOutlookAttachmentPlaybook.ps1 -SkipFunctionApp -FunctionAppName vmrayenrich

# Re-run only the Function App
./Deploy-VMRayOutlookAttachmentPlaybook.ps1 -SkipPlaybook -SkipRoleAssignment

# Skip the role assignment (e.g. you lack rights and an admin will do it)
./Deploy-VMRayOutlookAttachmentPlaybook.ps1 -SkipRoleAssignment
```

Because the Function App name is derived from `uniqueString(resourceGroup().id)`, re-deploying with the **same resource group and base name** produces the **same** Function App name — so the playbook keeps resolving it correctly.

---

## Verification

The playbook is **event-driven**, not a poller — it fires when mail arrives in the monitored mailbox (and only after you've authorized the connection and enabled it).

To confirm it works end-to-end:

1. Send a test email **with an attachment** to the monitored mailbox.
2. Azure Portal → Logic App **`<PlaybookName>`** → **Runs history** → confirm a run triggered and succeeded.
3. Open your VMRay portal (e.g. `https://us.cloud.vmray.com`) → **Submissions** — the attachment should appear as a new submission.
4. If the verdict is not *clean*, check **Microsoft Sentinel → Incidents** for a new *"VMRay Email Attachment Scan…"* incident, and **Threat Intelligence** for the uploaded indicators.
5. Confirm the summary email arrived at the recipient you set.

---

## Troubleshooting

### Can't find the API connection to authorize

The **API Connections** blade often shows a stale list immediately after deployment. Click **Refresh**, or open the connection from **Resource group → your RG → API Connection**, or from the Logic App's **API connections** menu. Confirm it exists with:

```powershell
Get-AzResource -ResourceGroupName <RG> -ResourceType "Microsoft.Web/connections" |
  Where-Object Name -like "*<PlaybookName>*" | Select-Object Name, @{n='Status';e={$_.Properties.statuses.status}}
```

### Playbook doesn't trigger on new mail

Check, in order: (1) the playbook is **Enabled** (deploys Disabled); (2) the `office365-<PlaybookName>` connection status is **Connected** (not *Error*); (3) mail is actually arriving in the **Inbox** of the authorized mailbox.

### Role assignment failed ("insufficient privileges" / not assigned)

The Phase 3 role assignment needs **Owner** or **User Access Administrator** on the scope. If the script reports *"NOT assigned — do it manually"*, assign it in **Sentinel workspace → Access control (IAM) → Add role assignment → Microsoft Sentinel Contributor → Managed identity → (your playbook)**.

### Managed identity replication ("PrincipalNotFound")

Right after the playbook is created, its managed identity can take a moment to replicate to Entra ID, so the role assignment may fail on the first try. The script retries automatically (up to 4 attempts, 20s apart). Usually no action needed.

### Incidents/IOCs not created, but VMRay submission succeeded

The playbook writes to Sentinel via its managed identity, so this almost always means the **Microsoft Sentinel Contributor** role assignment (Phase 3) is missing or hasn't propagated. Verify it in the workspace IAM blade.

### Function App base name rejected

*"Lowercase letters and numbers only, 20 characters max."* — the base name is also used as the storage account name, which disallows hyphens/uppercase and caps the length. Choose a shorter, lowercase-alphanumeric name.

### Summary email never arrives

The template ships the placeholder recipient `abc@abc.com`. Set the real recipient in the *Send an email (V2)* action (manual step 2).

---

## Summary — Comparison with the Original (Manual) Flow

| Step | Original (manual portal flow) | New (script-driven) |
|---|---|---|
| Function App deployment | Portal "Deploy to Azure" + fill fields | Automated |
| Playbook deployment | Separate "Deploy to Azure" + fill fields | Automated |
| Match function name between playbook and Function App | Manual, error-prone | Automated (same RG + base name) |
| Workspace Name / ID / App Insights ID | Copy-paste 3 values from the portal | Auto-filled from one workspace pick |
| Sentinel Contributor role for the playbook | Manual IAM assignment | Automated (with replication retry) |
| Authorize `office365` connection | Manual | Manual (interactive OAuth — unavoidable) |
| Set email recipient / enable playbook | Manual | Manual (by design; template left as-is) |
| **Total manual interactions** | Many clicks across multiple pages | **1 PowerShell command + 3 finishing clicks** |

The single-command deployment is the recommended path. The step-by-step portal instructions in the main `README.md` remain available for reference.
