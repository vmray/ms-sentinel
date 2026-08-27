<#
.SYNOPSIS
  End-to-end deployment of the VMRay "Sandbox Outlook Attachment" Microsoft Sentinel
  playbook and the VMRay Enrichment Function App it depends on.

.DESCRIPTION
  Single interactive script that automates the Azure-side deployment described in
  the SENTINEL README, for the VMRay-Sandbox_Outlook_Attachment Logic App:

    Phase 1: VMRay Enrichment Function App (ARM template)
             - a Python 3.11 Function App (base name "vmrayenrich" + 3-char hash)
               exposing the VMRayUploadSample / GetVMRaySubmission / GetVMRaySample /
               GetVMRayIOCs functions the playbook calls.
             - the function code is pulled from WEBSITE_RUN_FROM_PACKAGE, so there
               is NO manual code-publish step.

    Phase 2: VMRay-Sandbox_Outlook_Attachment playbook (Logic App, ARM template)
             - deploys into the SAME resource group as the Function App so the
               function-name hash (uniqueString(resourceGroup().id)) matches and the
               playbook resolves the function IDs automatically.
             - also creates the office365 (V1, OAuth) and azuresentinel (V1, Managed
               Identity) API connections.

    Phase 3: Role assignment
             - grants the playbook's system-assigned managed identity the
               "Microsoft Sentinel Contributor" role on the Log Analytics workspace,
               so it can create incidents and upload threat indicators.

  Unlike the Defender-for-Endpoint / MDO connectors, this playbook needs NO Azure AD
  App Registration: the Enrichment Function App takes only the VMRay URL/key, and the
  playbook writes to Sentinel through its own managed identity.

  MANUAL steps the script cannot perform (printed in the final summary):
    - Authorize the office365 API connection (interactive OAuth sign-in for the
      mailbox that receives the emails).
    - Set the "Send an email" recipient (the template ships a placeholder address).
    - Enable the playbook (it deploys Disabled).

.PARAMETER ResourceGroup
  Resource group to deploy into. Created if it doesn't exist. BOTH the Function App
  and the playbook go here (required for the function-name hash to match).

.PARAMETER Region
  Azure region for a new resource group. Default: "Central US".

.PARAMETER FunctionAppName
  Base name for the Function App (the template appends a 3-char uniqueness hash).
  Lowercase letters/numbers only (it is also used as the storage account name).
  Default: "vmrayenrich". The SAME value is passed to the playbook.

.PARAMETER VmrayBaseURL
  https://eu.cloud.vmray.com or https://us.cloud.vmray.com (or your on-prem URL).

.PARAMETER VmrayAPIKey
  VMRay connector API key (SecureString).

.PARAMETER Resubmit
  If $true, a sample is resubmitted to VMRay even if its hash was already seen.
  Default: $true.

.PARAMETER AppInsightsWorkspaceResourceID
  Full resource ID of a Log Analytics workspace for the Function App's App Insights.
  Defaults to the workspace you pick for Sentinel (prompted if not resolvable).

.PARAMETER PlaybookName
  Name of the Logic App/playbook. Default: "VMRay-Sandbox_Outlook_Attachment".

.PARAMETER WorkspaceName / WorkspaceID
  Log Analytics workspace Name and Workspace (customer) ID the playbook writes to.
  The script lists workspaces and lets you pick one if you don't pass these.

.PARAMETER FunctionTemplateFile / PlaybookTemplateFile
  Local ARM template overrides. Default to the templates in this repo (resolved
  relative to this script). Take precedence over the *Uri params.

.PARAMETER FunctionTemplateUri / PlaybookTemplateUri
  Remote ARM template overrides (used only if the local files can't be resolved).

.PARAMETER SkipFunctionApp / SkipPlaybook / SkipRoleAssignment
  Skip individual phases so you can test one at a time.

.EXAMPLE
  ./Deploy-VMRayOutlookAttachmentPlaybook.ps1

.EXAMPLE
  # Re-run only the playbook + role assignment, reusing an existing Function App
  ./Deploy-VMRayOutlookAttachmentPlaybook.ps1 -SkipFunctionApp -FunctionAppName vmrayenrich
#>

[CmdletBinding()]
param(
  # Common
  [string]$ResourceGroup,
  [string]$Region = "Central US",

  # Phase 1 - Function App
  [string]$FunctionAppName = "vmrayenrich",
  [string]$VmrayBaseURL,
  [SecureString]$VmrayAPIKey,
  [bool]$Resubmit = $true,
  [string]$AppInsightsWorkspaceResourceID,

  # Phase 2 - Playbook
  [string]$PlaybookName = "VMRay-Sandbox_Outlook_Attachment",
  [string]$WorkspaceName,
  [string]$WorkspaceID,

  # ARM template sources (local files take precedence; override for dev/offline)
  [string]$FunctionTemplateFile,
  [string]$PlaybookTemplateFile,
  [string]$FunctionTemplateUri = "https://raw.githubusercontent.com/Azure/Azure-Sentinel/refs/heads/master/Solutions/VMRay/Playbooks/CustomConnector/VMRayEnrichment_FunctionAppConnector/azuredeploy.json",
  [string]$PlaybookTemplateUri = "https://raw.githubusercontent.com/Azure/Azure-Sentinel/refs/heads/master/Solutions/VMRay/Playbooks/VMRay-Sandbox_Outlook_Attachment/azuredeploy.json",

  # Skip flags
  [switch]$SkipFunctionApp,
  [switch]$SkipPlaybook,
  [switch]$SkipRoleAssignment
)

$ErrorActionPreference = "Stop"
$ProgressPreference     = "SilentlyContinue"

# Track whether the operator passed the name explicitly (so we know to prompt).
$FunctionAppNameWasPassed = $PSBoundParameters.ContainsKey('FunctionAppName')
$PlaybookNameWasPassed    = $PSBoundParameters.ContainsKey('PlaybookName')

# ===========================================================================
#  Well-known constants
# ===========================================================================
# The role the playbook's managed identity needs to create incidents / upload IOCs.
$SENTINEL_CONTRIBUTOR_ROLE = "Microsoft Sentinel Contributor"

# ===========================================================================
#  Resolve default local template paths (relative to this script's folder).
# ===========================================================================
$scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $FunctionTemplateFile) {
  $candidate = Join-Path $scriptRoot "..\Playbooks\CustomConnector\VMRayEnrichment_FunctionAppConnector\azuredeploy.json"
  if (Test-Path $candidate) { $FunctionTemplateFile = (Resolve-Path $candidate).Path }
}
if (-not $PlaybookTemplateFile) {
  $candidate = Join-Path $scriptRoot "..\Playbooks\VMRay-Sandbox_Outlook_Attachment\azuredeploy.json"
  if (Test-Path $candidate) { $PlaybookTemplateFile = (Resolve-Path $candidate).Path }
}

# ===========================================================================
#  Display helpers
# ===========================================================================
function Write-Banner {
  param([string]$Title)
  Write-Host ""
  Write-Host "===========================================================================" -ForegroundColor Magenta
  Write-Host "  $Title" -ForegroundColor Magenta
  Write-Host "===========================================================================" -ForegroundColor Magenta
}

function Write-Phase {
  param([string]$Number, [string]$Title)
  Write-Host ""
  Write-Host ">>> Phase $Number - $Title" -ForegroundColor Cyan
  Write-Host ""
}

function Write-Step {
  param([string]$Index, [string]$Message)
  Write-Host ""
  Write-Host "[$Index] $Message" -ForegroundColor Cyan
}

# ===========================================================================
#  Interactive prompt helpers
# ===========================================================================
function Read-Choice {
  param([string]$Prompt, [string[]]$Options, [int]$Default = 1)
  Write-Host ""
  Write-Host $Prompt -ForegroundColor Yellow
  for ($i = 0; $i -lt $Options.Length; $i++) {
    $marker = if (($i + 1) -eq $Default) { " (default)" } else { "" }
    Write-Host "  [$($i + 1)] $($Options[$i])$marker"
  }
  do {
    $sel = Read-Host "  Choice"
    if ([string]::IsNullOrWhiteSpace($sel)) { return $Default }
    $num = 0
    if ([int]::TryParse($sel, [ref]$num) -and $num -ge 1 -and $num -le $Options.Length) { return $num }
    Write-Host "    Invalid. Enter a number between 1 and $($Options.Length)." -ForegroundColor Red
  } while ($true)
}

function Read-Text {
  param([string]$Prompt, [string]$Default = $null, [string]$ValidationPattern = $null,
        [string]$ValidationMessage = "Invalid input. Try again.")
  do {
    $defaultHint = if ($Default) { " [default: $Default]" } else { "" }
    Write-Host ""
    $value = Read-Host "  $Prompt$defaultHint"
    if ([string]::IsNullOrWhiteSpace($value) -and $Default) { return $Default }
    if ([string]::IsNullOrWhiteSpace($value)) { Write-Host "    Required. Please enter a value." -ForegroundColor Red; continue }
    if (-not $ValidationPattern -or $value -match $ValidationPattern) { return $value }
    Write-Host "    $ValidationMessage" -ForegroundColor Red
  } while ($true)
}

function Confirm-Action {
  param([string]$Prompt, [bool]$Default = $true)
  $defaultStr  = if ($Default) { "Y/n" } else { "y/N" }
  $defaultWord = if ($Default) { "Yes" } else { "No" }
  do {
    Write-Host ""
    $ans = (Read-Host "  $Prompt (default: $defaultWord) [$defaultStr]").Trim().ToLower()
    if ([string]::IsNullOrWhiteSpace($ans)) { return $Default }
    if ($ans -in @("y","yes")) { return $true }
    if ($ans -in @("n","no"))  { return $false }
    Write-Host "    Please answer y or n." -ForegroundColor Red
  } while ($true)
}

function Read-RequiredSecret {
  # Reads a masked (SecureString) value, re-prompting until a non-empty value is
  # entered. Used for mandatory secrets so an accidental empty ENTER doesn't sail
  # through and fail deep in the deployment.
  param([string]$Prompt)
  do {
    $secure = Read-Host -AsSecureString $Prompt
    $plain  = [System.Net.NetworkCredential]::new("", $secure).Password
    if (-not [string]::IsNullOrWhiteSpace($plain)) { return $secure }
    Write-Host "    Required. Please paste a non-empty value." -ForegroundColor Red
  } while ($true)
}

# ===========================================================================
#  Auth / module helpers
# ===========================================================================
function Connect-AzSmart {
  $azContext = Get-AzContext -ErrorAction SilentlyContinue
  if ($azContext) {
    Write-Host "  Azure session: $($azContext.Account.Id) (tenant $($azContext.Tenant.Id))" -ForegroundColor Green
    return
  }
  Write-Host "  No Azure session. Starting sign-in..." -ForegroundColor Gray
  Connect-AzAccount -ErrorAction Stop | Out-Null
  $azContext = Get-AzContext
  Write-Host "  Connected as $($azContext.Account.Id)." -ForegroundColor Green
}

function Ensure-Module {
  param([string]$Name)
  $module = Get-Module -ListAvailable -Name $Name | Select-Object -First 1
  if (-not $module) {
    Write-Host "  Installing $Name (current user, one-time)..." -ForegroundColor Yellow
    Install-Module $Name -Scope CurrentUser -Force -AllowClobber
  }
  Import-Module $Name -ErrorAction Stop
}

# ===========================================================================
#  Generic Az deploy helper
# ===========================================================================
function Invoke-ArmDeploy {
  param(
    [string]$DeploymentName,
    [string]$ResourceGroup,
    [hashtable]$Parameters,
    [string]$TemplateUri,
    [string]$TemplateFile
  )
  $p = @{
    Name              = $DeploymentName
    ResourceGroupName = $ResourceGroup
    ErrorAction       = "Stop"
  }
  foreach ($k in $Parameters.Keys) { $p[$k] = $Parameters[$k] }
  if ($TemplateFile) { $p.TemplateFile = $TemplateFile } else { $p.TemplateUri = $TemplateUri }
  return New-AzResourceGroupDeployment @p
}

# ===========================================================================
#                              SCRIPT START
# ===========================================================================
Write-Banner "VMRay Sandbox Outlook Attachment - Microsoft Sentinel Deployment"

Write-Host ""
Write-Host "  This script automates the Azure-side deployment:" -ForegroundColor Gray
Write-Host "    1. VMRay Enrichment Function App (ARM)" -ForegroundColor Gray
Write-Host "    2. VMRay-Sandbox_Outlook_Attachment playbook (Logic App, ARM)" -ForegroundColor Gray
Write-Host "    3. Sentinel Contributor role for the playbook's managed identity" -ForegroundColor Gray
Write-Host ""
Write-Host "  No App Registration is required for this playbook. After deployment you" -ForegroundColor Gray
Write-Host "  must still (manually) authorize the office365 connection, set the email" -ForegroundColor Gray
Write-Host "  recipient, and enable the playbook - see the final summary." -ForegroundColor Gray

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
Write-Phase "0" "Pre-flight"

Write-Step "1/2" "Loading PowerShell modules..."
Ensure-Module Az.Accounts
Ensure-Module Az.Resources
Ensure-Module Az.Websites
try { Ensure-Module Az.OperationalInsights } catch { Write-Host "  (Az.OperationalInsights optional - workspace picker disabled)" -ForegroundColor Gray }

Write-Step "2/2" "Connecting to Azure..."
Connect-AzSmart

$azContext = Get-AzContext
$tenantId  = $azContext.Tenant.Id

Write-Host ""
Write-Host "  Tenant       : $tenantId" -ForegroundColor White
Write-Host "  Subscription : $($azContext.Subscription.Name) ($($azContext.Subscription.Id))" -ForegroundColor White

# Subscription picker (same UX as the other VMRay scripts)
$allSubs = @()
try { $allSubs = @(Get-AzSubscription -TenantId $tenantId -ErrorAction Stop | Sort-Object Name) }
catch { $allSubs = @($azContext.Subscription) }

if ($allSubs.Count -le 1) {
  if (-not (Confirm-Action "Continue with this tenant + subscription?")) {
    throw "Aborted by user. Switch context (Connect-AzAccount) and retry."
  }
} else {
  Write-Host "  $($allSubs.Count) subscriptions are accessible in this tenant." -ForegroundColor Gray
  $subChoice = Read-Choice -Prompt "How do you want to handle the subscription?" -Options @(
    "Use the current subscription shown above", "Switch to a different subscription") -Default 1
  if ($subChoice -eq 2) {
    $subOptions = @($allSubs | ForEach-Object { "$($_.Name) ($($_.Id))" })
    $picked = Read-Choice -Prompt "Pick a subscription:" -Options $subOptions -Default 1
    $chosenSub = $allSubs[$picked - 1]
    Set-AzContext -SubscriptionId $chosenSub.Id -TenantId $tenantId | Out-Null
    $azContext = Get-AzContext
    Write-Host "  Now using: $($azContext.Subscription.Name) ($($azContext.Subscription.Id))" -ForegroundColor Green
  }
}
$subscriptionId = $azContext.Subscription.Id

# Resource group (BOTH resources deploy here so the function-name hash matches)
if (-not $ResourceGroup) {
  $ResourceGroup = Read-Text -Prompt "Resource group name (created if it doesn't exist)"
}
$existingRg = Get-AzResourceGroup -Name $ResourceGroup -ErrorAction SilentlyContinue
if ($existingRg) {
  $Region = $existingRg.Location
  Write-Host ""
  Write-Host "  Using existing resource group '$ResourceGroup' in '$Region'." -ForegroundColor Green
} else {
  if (-not $PSBoundParameters.ContainsKey('Region')) {
    $Region = Read-Text -Prompt "Azure region for the new resource group" -Default $Region
  }
  Write-Host "  Creating resource group '$ResourceGroup' in '$Region'..." -ForegroundColor Yellow
  New-AzResourceGroup -Name $ResourceGroup -Location $Region | Out-Null
  Write-Host "  Created." -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Shared inputs: Function App base name + Log Analytics workspace
# ---------------------------------------------------------------------------
# Function App base name is used by BOTH templates and (lowercased) as the storage
# account name, so restrict to lowercase alphanumeric and keep it short.
if (-not $FunctionAppNameWasPassed) {
  $FunctionAppName = Read-Text -Prompt "Function App base name (lowercase letters/numbers, <= 20 chars)" -Default $FunctionAppName `
                               -ValidationPattern '^[a-z0-9]{1,20}$' `
                               -ValidationMessage "Lowercase letters and numbers only, 20 characters max (used as the storage account name)."
}
$FunctionAppName = $FunctionAppName.ToLower()

# Pick a Log Analytics workspace once - it serves as the Sentinel workspace
# (Name + WorkspaceID for the playbook) AND the App Insights workspace (ResourceId).
$selectedWorkspace = $null
if (-not $WorkspaceName -or -not $WorkspaceID -or -not $AppInsightsWorkspaceResourceID) {
  try {
    $workspaces = @(Get-AzOperationalInsightsWorkspace -ErrorAction Stop | Sort-Object Name)
  } catch { $workspaces = @() }

  if ($workspaces.Count -gt 0) {
    $wsOpts = @($workspaces | ForEach-Object { "$($_.Name)  ($($_.ResourceGroupName))" })
    $wp = Read-Choice -Prompt "Select the Log Analytics / Sentinel workspace:" -Options ($wsOpts + @("Enter values manually")) -Default 1
    if ($wp -le $workspaces.Count) {
      $selectedWorkspace = $workspaces[$wp-1]
      Write-Host "  Selected workspace: $($selectedWorkspace.Name)" -ForegroundColor Green
    }
  } else {
    Write-Host "  No workspaces found (or Az.OperationalInsights unavailable) - entering values manually." -ForegroundColor Gray
  }
}

if ($selectedWorkspace) {
  if (-not $WorkspaceName)                  { $WorkspaceName = $selectedWorkspace.Name }
  if (-not $WorkspaceID)                    { $WorkspaceID   = $selectedWorkspace.CustomerId }
  if (-not $AppInsightsWorkspaceResourceID) { $AppInsightsWorkspaceResourceID = $selectedWorkspace.ResourceId }
  $workspaceResourceId = $selectedWorkspace.ResourceId
} else {
  if (-not $WorkspaceName) { $WorkspaceName = Read-Text -Prompt "Log Analytics workspace NAME" }
  if (-not $WorkspaceID)   { $WorkspaceID   = Read-Text -Prompt "Log Analytics WORKSPACE ID (GUID)" `
                                                -ValidationPattern '^[0-9a-fA-F-]{36}$' `
                                                -ValidationMessage "Expected a 36-char GUID." }
  if (-not $AppInsightsWorkspaceResourceID) {
    $AppInsightsWorkspaceResourceID = Read-Text -Prompt "App Insights Log Analytics workspace Resource ID" `
      -ValidationPattern '^/subscriptions/.+/workspaces/.+' `
      -ValidationMessage "Must be a full /subscriptions/.../workspaces/... resource ID."
  }
  # Best-effort resolve the workspace resource ID for the role-assignment scope.
  $workspaceResourceId = $AppInsightsWorkspaceResourceID
}

# ===========================================================================
# PHASE 1 - Function App
# ===========================================================================
if ($SkipFunctionApp.IsPresent) {
  Write-Phase "1" "VMRay Enrichment Function App - SKIPPED (-SkipFunctionApp)"
} else {
  Write-Phase "1" "Deploy VMRay Enrichment Function App"

  if (-not $VmrayBaseURL) {
    $urlChoice = Read-Choice -Prompt "VMRay Base URL:" -Options @(
      "https://eu.cloud.vmray.com","https://us.cloud.vmray.com","Other (enter manually)") -Default 1
    $VmrayBaseURL = switch ($urlChoice) {
      1 { "https://eu.cloud.vmray.com" }
      2 { "https://us.cloud.vmray.com" }
      3 { Read-Text -Prompt "VMRay Base URL" -ValidationPattern '^https?://' }
    }
  }
  if (-not $VmrayAPIKey) {
    Write-Host ""
    Write-Host "  Paste the VMRay connector API key (input hidden):" -ForegroundColor Yellow
    $VmrayAPIKey = Read-RequiredSecret "  VMRay API Key"
  }
  if (-not $PSBoundParameters.ContainsKey('Resubmit')) {
    $Resubmit = Confirm-Action "Resubmit samples to VMRay even if the hash was already seen?" -Default $true
  }

  Write-Host ""
  Write-Host "  About to deploy the Function App:" -ForegroundColor Yellow
  Write-Host "    Base name     : $FunctionAppName  (a 3-char hash is appended)" -ForegroundColor White
  Write-Host "    Resource group: $ResourceGroup" -ForegroundColor White
  Write-Host "    Region        : $Region" -ForegroundColor White
  Write-Host "    VMRay URL     : $VmrayBaseURL" -ForegroundColor White
  Write-Host "    Resubmit      : $Resubmit" -ForegroundColor White
  if (-not (Confirm-Action "Proceed with Function App deployment?")) { throw "Aborted by user." }

  Write-Step "1/1" "Deploying Function App ARM template (this can take several minutes)..."
  $faParams = @{
    vmrayBaseURL                   = $VmrayBaseURL
    vmrayAPIKey                    = $VmrayAPIKey
    Resubmit                       = $Resubmit
    FunctionAppName                = $FunctionAppName
    AppInsightsWorkspaceResourceID = $AppInsightsWorkspaceResourceID
  }
  $faDeployName = "vmray-enrich-func-$(Get-Date -Format 'yyyyMMddHHmmss')"
  $faDeploy = Invoke-ArmDeploy -DeploymentName $faDeployName -ResourceGroup $ResourceGroup `
                -Parameters $faParams -TemplateUri $FunctionTemplateUri -TemplateFile $FunctionTemplateFile
  if (-not $faDeploy -or $faDeploy.ProvisioningState -ne "Succeeded") {
    throw "Function App deployment finished with state '$($faDeploy.ProvisioningState)'."
  }
  Write-Host "  Function App deployment succeeded." -ForegroundColor Green

  # Discover the name-mangled Function App the template created (for the summary).
  $createdFunc = @(Get-AzWebApp -ResourceGroupName $ResourceGroup -ErrorAction SilentlyContinue |
                   Where-Object { $_.Name -like "$FunctionAppName*" })
  if ($createdFunc.Count -ge 1) {
    Write-Host "  Function App    : $($createdFunc[0].Name)" -ForegroundColor Gray
  }
}

# ===========================================================================
# PHASE 2 - Playbook (Logic App)
# ===========================================================================
if ($SkipPlaybook.IsPresent) {
  Write-Phase "2" "Playbook - SKIPPED (-SkipPlaybook)"
} else {
  Write-Phase "2" "Deploy VMRay-Sandbox_Outlook_Attachment Playbook"

  # Loop until we have a playbook name the operator is happy to deploy. Unlike an App
  # Registration, a Logic App is a single resource keyed by name+RG, so a name clash
  # OVERWRITES the existing playbook (its workflow definition is replaced and it is
  # reset to Disabled - wiping manual edits like the recipient address). Warn first and
  # let the operator overwrite or pick a different name. A name passed via -PlaybookName
  # is checked once but not re-prompted (non-interactive use).
  while ($true) {
    if (-not $PlaybookName) {
      $PlaybookName = Read-Text -Prompt "Playbook (Logic App) name" -Default "VMRay-Sandbox_Outlook_Attachment"
    }

    $existingPlaybook = Get-AzResource -ResourceGroupName $ResourceGroup -ResourceType "Microsoft.Logic/workflows" `
                          -Name $PlaybookName -ErrorAction SilentlyContinue
    if (-not $existingPlaybook) { break }

    Write-Host ""
    Write-Host "  WARNING: a Logic App named '$PlaybookName' already exists in resource group '$ResourceGroup'." -ForegroundColor Yellow
    Write-Host "  Deploying will OVERWRITE it: its workflow definition is replaced and it is reset to Disabled" -ForegroundColor Yellow
    Write-Host "  (any manual edits, e.g. the email recipient, are lost)." -ForegroundColor Yellow

    if ($PlaybookNameWasPassed) {
      # Name came from a parameter - don't silently loop forever in a non-interactive run.
      if (Confirm-Action "Overwrite the existing '$PlaybookName' playbook?" -Default $false) { break }
      throw "Aborted: playbook '$PlaybookName' already exists and overwrite was declined. Re-run with a different -PlaybookName."
    }

    if (Confirm-Action "Overwrite the existing '$PlaybookName' playbook?" -Default $false) { break }
    Write-Host "  Please enter a different name for the playbook." -ForegroundColor Yellow
    $PlaybookName = $null
  }

  Write-Host ""
  Write-Host "  About to deploy the playbook:" -ForegroundColor Yellow
  Write-Host "    Playbook name : $PlaybookName" -ForegroundColor White
  Write-Host "    Resource group: $ResourceGroup" -ForegroundColor White
  Write-Host "    Workspace name: $WorkspaceName" -ForegroundColor White
  Write-Host "    Workspace ID  : $WorkspaceID" -ForegroundColor White
  Write-Host "    Function App  : $FunctionAppName (base name; hash resolved in-RG)" -ForegroundColor White
  if (-not (Confirm-Action "Proceed with playbook deployment?")) { throw "Aborted by user." }

  Write-Step "1/1" "Deploying playbook ARM template..."
  $pbParams = @{
    PlaybookName    = $PlaybookName
    WorkspaceName   = $WorkspaceName
    WorkspaceID     = $WorkspaceID
    FunctionAppName = $FunctionAppName
  }
  $pbDeployName = "vmray-outlook-playbook-$(Get-Date -Format 'yyyyMMddHHmmss')"
  $pbDeploy = Invoke-ArmDeploy -DeploymentName $pbDeployName -ResourceGroup $ResourceGroup `
                -Parameters $pbParams -TemplateUri $PlaybookTemplateUri -TemplateFile $PlaybookTemplateFile
  if (-not $pbDeploy -or $pbDeploy.ProvisioningState -ne "Succeeded") {
    throw "Playbook deployment finished with state '$($pbDeploy.ProvisioningState)'."
  }
  Write-Host "  Playbook deployment succeeded (deployed Disabled)." -ForegroundColor Green
}

# ===========================================================================
# PHASE 3 - Role assignment (playbook managed identity -> Sentinel Contributor)
# ===========================================================================
$roleAssigned = $false
if ($SkipRoleAssignment.IsPresent) {
  Write-Phase "3" "Role assignment - SKIPPED (-SkipRoleAssignment)"
} else {
  Write-Phase "3" "Grant the playbook's managed identity Sentinel access"

  Write-Step "1/2" "Reading the playbook's managed identity..."
  $principalId = $null
  # The managed identity can take a moment to appear/replicate after deploy - retry.
  for ($attempt = 1; $attempt -le 6; $attempt++) {
    try {
      $wf = Get-AzResource -ResourceGroupName $ResourceGroup -ResourceType "Microsoft.Logic/workflows" `
              -Name $PlaybookName -ExpandProperties -ErrorAction Stop
      $principalId = $wf.Identity.PrincipalId
    } catch { $principalId = $null }
    if ($principalId) { break }
    Write-Host "  Identity not visible yet (attempt $attempt/6). Waiting 10s..." -ForegroundColor Gray
    Start-Sleep -Seconds 10
  }

  if (-not $principalId) {
    Write-Host "  Could not read the playbook's managed identity principalId." -ForegroundColor Yellow
    Write-Host "  Assign '$SENTINEL_CONTRIBUTOR_ROLE' to the playbook manually (see summary)." -ForegroundColor Yellow
  } else {
    Write-Host "  Managed identity principalId: $principalId" -ForegroundColor Green

    Write-Step "2/2" "Assigning '$SENTINEL_CONTRIBUTOR_ROLE' on the workspace..."
    if (-not $workspaceResourceId -or $workspaceResourceId -notmatch '/workspaces/') {
      Write-Host "  Workspace resource ID unknown - assigning at resource-group scope instead." -ForegroundColor Yellow
      $scope = "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroup"
    } else {
      $scope = $workspaceResourceId
    }

    # Retry to absorb Entra replication of the freshly-created managed identity.
    for ($attempt = 1; $attempt -le 4; $attempt++) {
      try {
        $existing = Get-AzRoleAssignment -ObjectId $principalId -RoleDefinitionName $SENTINEL_CONTRIBUTOR_ROLE `
                      -Scope $scope -ErrorAction SilentlyContinue
        if ($existing) {
          Write-Host "  Role already assigned. Skipping." -ForegroundColor Green
          $roleAssigned = $true
          break
        }
        New-AzRoleAssignment -ObjectId $principalId -RoleDefinitionName $SENTINEL_CONTRIBUTOR_ROLE `
          -Scope $scope -ErrorAction Stop | Out-Null
        Write-Host "  Role assigned at scope: $scope" -ForegroundColor Green
        $roleAssigned = $true
        break
      } catch {
        $msg = "$($_.Exception.Message)"
        if ($msg -match "already exists|RoleAssignmentExists") {
          Write-Host "  Role already assigned. Skipping." -ForegroundColor Green
          $roleAssigned = $true
          break
        }
        if (($msg -match "PrincipalNotFound|does not exist in the directory|principal") -and $attempt -lt 4) {
          Write-Host "  Managed identity not yet replicated to Entra (attempt $attempt/4). Waiting 20s..." -ForegroundColor Yellow
          Start-Sleep -Seconds 20
          continue
        }
        Write-Host "  Could not assign the role automatically: $msg" -ForegroundColor Yellow
        break
      }
    }
  }
}

# ===========================================================================
# FINAL SUMMARY
# ===========================================================================
Write-Banner "Deployment summary"

$office365Conn    = "office365-$PlaybookName"
$azureSentinelConn = "azuresentinel-$PlaybookName"

Write-Host ""
Write-Host "  Tenant ID       : $tenantId" -ForegroundColor White
Write-Host "  Subscription    : $subscriptionId" -ForegroundColor White
Write-Host "  Resource group  : $ResourceGroup" -ForegroundColor White
Write-Host "  Function App    : $FunctionAppName (+ 3-char hash)" -ForegroundColor White
Write-Host "  Playbook        : $PlaybookName" -ForegroundColor White
Write-Host "  Workspace       : $WorkspaceName ($WorkspaceID)" -ForegroundColor White
Write-Host "  Sentinel role   : $(if ($roleAssigned) { 'assigned' } elseif ($SkipRoleAssignment.IsPresent) { 'skipped' } else { 'NOT assigned - do it manually' })" -ForegroundColor White

Write-Host ""
Write-Host "  MANUAL NEXT STEPS (the script cannot perform these):" -ForegroundColor Yellow
Write-Host "  ----------------------------------------------------------------------" -ForegroundColor Yellow
Write-Host "  1. Authorize the office365 API connection (interactive OAuth):" -ForegroundColor Yellow
Write-Host "       Portal -> Resource group '$ResourceGroup' -> API Connection" -ForegroundColor Gray
Write-Host "       '$office365Conn' -> Edit API connection -> Authorize -> Save." -ForegroundColor Gray
Write-Host "       (Sign in as the mailbox that receives the emails to analyze.)" -ForegroundColor Gray
Write-Host "     The '$azureSentinelConn' connection uses the playbook's managed" -ForegroundColor Gray
Write-Host "     identity, so it needs no interactive authorization." -ForegroundColor Gray
Write-Host ""
Write-Host "  2. Set the 'Send an email (V2)' recipient in the playbook:" -ForegroundColor Yellow
Write-Host "       The template ships a placeholder address (abc@abc.com). Open the" -ForegroundColor Gray
Write-Host "       Logic App designer and set the real recipient before enabling." -ForegroundColor Gray
Write-Host ""
Write-Host "  3. Enable the playbook (it deploys Disabled):" -ForegroundColor Yellow
Write-Host "       Portal -> Logic App '$PlaybookName' -> Overview -> Enable." -ForegroundColor Gray
if (-not $roleAssigned -and -not $SkipRoleAssignment.IsPresent) {
  Write-Host ""
  Write-Host "  4. Assign '$SENTINEL_CONTRIBUTOR_ROLE' to the playbook's managed" -ForegroundColor Yellow
  Write-Host "       identity on the Sentinel workspace (Access Control (IAM))." -ForegroundColor Gray
}
Write-Host ""
Write-Host "===========================================================================" -ForegroundColor Magenta
