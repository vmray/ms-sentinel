# VMRay Threat Intelligence Feed and Enrichment Integration - Microsoft Sentinel

**Latest Version:** 1.3.0 - **Release Date: 27-08-2026**

## Table of Contents
- [Overview](#overview)
- [Requirements](#requirements)
- [VMRay Configurations](#vmray-configurations)
- [Microsoft Sentinel](#microsoft-sentinel)
- [Provide Permission To App Created Above](#provide-permission-to-app-created-above)
- [Deploy VMRay Threat Intelligence Feed Function App Connector](#deploy-vmray-threat-intelligence-feed-function-app-connector)
- [Deploy VMRay Enrichment Function App Connector](#deploy-vmray-enrichment-function-app-connector)
- [Deploy VMRay Enrichment Logic Apps](#deploy-vmray-enrichment-logic-apps)
- [Provide Permission to Logic app](#provide-permission-to-logic-app)
- [Version History](#version-history)
- [Steps to Update from previous version](#steps-to-update-from-previous-version)

## Overview


## Requirements
- Microsoft Sentinel.
- VMRay Analyzer, VMRay FinalVerdict, VMRay TotalInsight.
- Microsoft Azure
  1. Azure functions with Flex Consumption plan.
     Reference: https://learn.microsoft.com/en-us/azure/azure-functions/flex-consumption-plan
     
	 **Note:** Flex Consumption plans are not available in all regions, please check if the region your are deploying the function is supported, if not we suggest you to deploy the function app with premium plan.
	 Reference: https://learn.microsoft.com/en-us/azure/azure-functions/flex-consumption-how-to?tabs=azure-cli%2Cvs-code-publish&pivots=programming-language-python#view-currently-supported-regions
  3. Azure functions Premium plan.
	 Reference: https://learn.microsoft.com/en-us/azure/azure-functions/functions-premium-plan
  4. Azure Logic App with Consumption plan.
     Reference: https://learn.microsoft.com/en-us/azure/logic-apps/logic-apps-pricing#consumption-multitenant
  5. Azure storage with Standard general-purpose v2.

## VMRay Configurations

- In VMRay Console, you must create a Connector API key.Create it by following the steps below:
  
  1. Create a user dedicated for this API key (to avoid that the API key is deleted if an employee leaves)
  2. Create a role that allows to "View shared submission, analysis and sample" and "Submit sample, manage own jobs, reanalyse old analyses and regenerate analysis reports".
  3. Assign this role to the created user
  4. Login as this user and create an API key by opening Settings > Analysis > API Keys.
  5. Please save the keys, which will be used in configuring the Azure Function.

     
## Microsoft Sentinel

### Creating Application for API Access

- Open [https://portal.azure.com/](https://portal.azure.com) and search `Microsoft Entra ID` service.

![01](Images/01.png)

- Click `Add->App registration`.

![02a](Images/02a.png)

- Enter the name of application and select supported account types and click on `Register`.

![02](Images/02.png)

- In the application overview you can see `Application Name`, `Application ID` and `Tenant ID`.
 
![03](Images/03.png)

- After creating the application, we need to set API permissions for connector. For this purpose,
  - Click `Manage->API permissions` tab
  - Click `Microsoft Graph` button
  - Search `indicator` and click on the `ThreatIndicators.ReadWrite.OwnedBy`, click `Add permissions` button below.
  - Click on `Grant admin consent`

 ![app_per](Images/app_per.png) 

- We need secrets to access programmatically. For creating secrets
  - Click `Manage->Certificates & secrets` tab
  - Click `Client secrets` tab
  - Click `New client secret` button
  - Enter description and set expiration date for secret

![10](Images/10.png)

- Use Secret `Value` to configure connector.
  
 ![11](Images/11.png)

## Provide Permission To App Created Above

- Open [https://portal.azure.com/](https://portal.azure.com) and search `Microsoft Sentinel` service.
- Goto `Settings` -> `Workspace Setting`

![04](Images/04.png)

- Goto `Access Control(IAM)` -> `Add`

![05](Images/05.png)

- Search for `Microsoft Sentinel Contributor` and click `Next`

![06](Images/06.png)

- Select `User,group or service principle` and click on `select members`.
- Search for the app name created above and click on `select`.
- Click on `Next`

![07](Images/07.png)

- Click on `Review + assign`

![08](Images/08.png)

# Deploy VMRay Threat Intelligence Feed Function App Connector

### Flex Consumption Plan 
- Click on below button to deploy with Flex Consumption plan:

  [![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fvmray%2Fms-sentinel%2Frefs%2Fheads%2Fmain%2FVMRayThreatIntelligence%2FFlexConsumptionPlan%2Fazuredeploy.json)

### Premium Plan
- Click on below button to deploy with Premium plan:

  [![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fvmray%2Fms-sentinel%2Frefs%2Fheads%2Fmain%2FVMRayThreatIntelligence%2FPremiumPlan%2Fazuredeploy.json)

- It will redirect to feed Configuration page.
  ![09](Images/09.png)
- Please provide the values accordingly.
  
|       Fields       |   Description |
|:---------------------|:--------------------
| Subscription		| Select the appropriate Azure Subscription    | 
| Resource Group 	| Select the appropriate Resource Group |
| Region			| Based on Resource Group this will be uto populated |
| Function Name		| Please provide a function name if needed to change the default value|
| Vmray Base URL | VMRay Base URL |
| Vmray API Key | VMRay API Key |
| Azure Client ID   | Enter the Azure Client ID created in the App Registration Step |
| Azure Client Secret | Enter the Azure Client Secret created in the App Registration Step |
|Azure Tenant ID | Enter the Azure Tenant ID of the App Registration |
| Azure Workspacse ID   | Enter the Azure Workspacse ID. Go to  `Log Analytics workspace -> Overview`, Copy `Workspace ID`, refer below image.|
| App Insights Workspace Resource ID | Go to `Log Analytics workspace` -> `Settings` -> `Properties`, Copy `Resource ID` and paste here |

![40](Images/40.png)

- Once you provide the above values, please click on `Review + create` button.

- Once the threat intelligence function app connector is succussefully deployed, the connector saves the IOCS into the Microsoft Sentinel Threat Intelligence.

![ti_feed](Images/ti_feed.png)

## Deploy VMRay Enrichment Function App Connector

- Click on below button to deploy 

  [![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fvmray%2Fms-sentinel%2Frefs%2Fheads%2Fmain%2FVMRayEnrichment%2Fazuredeploy.json)
  
- It will redirect to feed Configuration page.

![13](Images/13.png)

- Please provide the values accordingly
  
|       Fields       |   Description |
|:---------------------|:--------------------
| Subscription		| Select the appropriate Azure Subscription    | 
| Resource Group 	| Select the appropriate Resource Group |
| Region			| Based on Resource Group this will be uto populated |
| Function Name		| Please provide a function name if needed to change the default value|
| Vmray Base URL | VMRay Base URL |
| Vmray API Key | VMRay API Key |
| Resubmit   | If true file will be resubmitted to VMRay |
| App Insights Workspace Resource ID | Go to `Log Analytics workspace` -> `Settings` -> `Properties`, Copy `Resource ID` and paste here |

- Once you provide the above values, please click on `Review + create` button.


## Deploy VMRay Enrichment Logic Apps

### `Submit-URL-VMRay-Analyzer` Logic App

- This playbook can be used to enrich sentinel incidents, this playbook when configured to trigger on seninel incidents, the playbook will collect all the `URL` entities from the Incident and submits them to VMRay analyzer, once the submission is completed, it will add the VMRay Analysis report to the Incident and creates the IOCs in the microsoft seninel threat intelligence.

- Click on below button to deploy
  
[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fvmray%2Fms-sentinel%2Frefs%2Fheads%2Fmain%2FLogicApps%2Fazuredeploy1.json)

- It will redirect to configuration page

![url_playbook](Images/url_playbook.png)

- Please provide the values accordingly

|       Fields       |   Description |
|:---------------------|:--------------------
| Subscription		| Select the appropriate Azure Subscription    | 
| Resource Group 	| Select the appropriate Resource Group |
| Region			| Based on Resource Group this will be uto populated |
| Playbook Name		| Please provide a playbook name, if needed |
| Workspace ID		| Please provide Log Analytics Workspace ID |
| Function App Name		| Please provide the VMRay enrichment function app name |
| Whitelisted URL Domains	| Optional. Comma-separated list of domains whose URLs are never submitted to VMRay, e.g. `microsoft.com,google.com`. Matching is case-insensitive and subdomains of a listed domain are also skipped. Leave empty to submit every URL. |

- Once you provide the above values, please click on `Review + create` button.


### `VMRay-Sandbox_Outlook_Attachment` Logic App

- This playbook can be used to enrich outlook attachements, this playbook when configured will collect all the `attachements` from the email and submits them to VMRay analyzer, once the submission is completed, it will add the VMRay Analysis report by creating an Incident and creates the IOCs in the microsoft seninel threat intelligence.


- Click on below button to deploy
  
[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fvmray%2Fms-sentinel%2Frefs%2Fheads%2Fmain%2FLogicApps%2Fazuredeploy2.json)

- It will redirect to configuration page

![email_playbook](Images/email_playbook.png)

- Please provide the values accordingly

|       Fields       |   Description |
|:---------------------|:--------------------
| Subscription		| Select the appropriate Azure Subscription    | 
| Resource Group 	| Select the appropriate Resource Group |
| Region			| Based on Resource Group this will be uto populated |
| Playbook Name		| Please provide a playbook name, if needed |
| Workspace Name		| Please provide Log Analytics Workspace Name |
| Workspace ID		| Please provide Log Analytics Workspace ID |
| Function App Name		| Please provide the VMRay enrichment function app name |

- Once you provide the above values, please click on `Review + create` button.

## Provide Permission to Logic app

- Open [https://portal.azure.com/](https://portal.azure.com) and search `Microsoft Sentinel` service.
- Goto `Settings` -> `Workspace Setting`

![04](Images/04.png)

- Goto `Access Control(IAM)` -> `Add`

![05](Images/05.png)

- Search for `Microsoft Sentinel Contributor` and click `Next`

![06](Images/06.png)

- Select `Managed Identity` and click on `select members` .
- Search for the Logic app name deployed above and click on `select`.
- Click on `Next` 

![38](Images/38.png)

- Click on `Review + assign`


## Version History

| Version        | Release Date | Release Notes
|:---------------|:-------------|:---------------- |
| 1.3.0          | `27-08-2026` | <ul><li>Added URL domain whitelisting to the `Submit-URL-VMRay-Analyzer` playbook. The new `WhitelistedURLDomains` parameter takes a comma-separated list of domains that are never submitted to VMRay. Matching is case-insensitive and also skips subdomains of a listed domain (up to four labels deep).</li><li>When every URL on an incident is whitelisted, the playbook now adds an explanatory incident comment instead of exiting silently.</li><li>Playbook metadata updated with its real prerequisites and the managed-identity / Sentinel role assignments required to run it.</li></ul> |
| 1.2.0          | `26-08-2026` | <ul><li>Playbooks restructured into the `Playbooks/` layout used by the Azure-Sentinel repository, with the VMRay Enrichment Function App exposed as a reusable custom connector (`VMRayUploadSample`, `UplaodURL`, `GetVMRaySubmission`, `GetVMRaySample`, `GetVMRaySampleByHash`, `GetAnalysisBySampleID`, `GetVMRayIOCs`, `GetVMRayVTIs`, `GetVMRayThreatIndicator`).</li><li>Added `Scripts/Deploy-VMRayOutlookAttachmentPlaybook.ps1` — a single-command PowerShell deployment of the `VMRay-Sandbox_Outlook_Attachment` playbook together with the Function App it depends on.</li><li>Added the automated deployment guide, [docs/AUTOMATED-DEPLOYMENT.md](docs/AUTOMATED-DEPLOYMENT.md).</li></ul> |
| 1.1.2          | `07-11-2025` | <ul><li>Security hardening: the storage account and Function App deployed by the Threat Intelligence Feed templates now enforce a minimum TLS version of 1.2.</li><li>Function App package is now served from `https://aka.ms/sentinel-VMRay-functionapp` instead of a raw GitHub branch URL, so deployments no longer depend on branch state.</li><li>Fixed storage account name resolution in `azuredeploy.json` (inconsistent lower-casing could produce a resource-id mismatch at deployment time).</li><li>Added the solution architecture diagram.</li></ul> |
| 1.1.1          | `19-08-2025` | <ul><li>Function App released packages rebuilt. No functional changes.</li></ul> |
| 1.1.0          | `15-07-2025` | <ul><li>Added a configurable indicator expiration. The new `IndicatorExpirationInDays` / `Indicator_Expiration_In_Days` parameter (default `30`) sets how long uploaded indicators stay valid, and is available on both the Threat Intelligence Feed templates and both Logic Apps.</li><li>Indicator `sourcesystem` renamed from `VMRay Playbook` to `VMRayThreatIntelligence` for consistent attribution in Sentinel Threat Intelligence.</li></ul> |
| 1.0.1          | `27-06-2025` | <ul><li>Published the full Python source of both Function Apps under `Source/` (`VMRayEnrichmentApp` and `VMRayThreatIntellignceFeedApp`), so the shipped packages can be reviewed and rebuilt.</li></ul> |
| 1.0.0          | `11-06-2025` | <ul><li>VMRay VTIs (VMRay Threat Identifiers) are now retrieved through the new `GetVMRayVTIs` function and added to the incident comment, ordered by severity, with category, operation and classifications.</li><li>Incident comments now include the sample verdict reason description.</li></ul> |
| 1.0.0-beta.4   | `14-05-2025` | <ul><li>Threat Intelligence Feed function restructured — the timer trigger entry point moved from `__init__.py` to `main.py`.</li><li>Indicator IDs are now generated deterministically from the indicator type, value and threat source, so re-ingesting the same IOC no longer creates a duplicate indicator.</li></ul> |
| 1.0.0-beta.3   | `18-04-2025` | <ul><li>Added handling for clean URLs — the playbook now builds a submission report and posts the VMRay verdict as an HTML table comment on the incident for clean verdicts as well, instead of only for malicious and suspicious ones.</li></ul> |
| 1.0.0-beta.2   | `04-04-2025` | <ul><li>Added an Azure Functions Premium plan deployment template, for regions where the Flex Consumption plan is not available.</li><li>Threat Intelligence Feed templates reorganized into `FlexConsumptionPlan/` and `PremiumPlan/`.</li></ul> |
| 1.0.0-beta.1   | `25-02-2025` | Initial Release |


## Steps to Update from previous version

### Deploy VMRay Threat Intelligence Feed Function App
> Please redeploy the Threat Intelligence Feed Function App, following the instructions given in the document.
>- [Deploy VMRay Threat Intelligence Feed Function App Connector](#deploy-vmray-threat-intelligence-feed-function-app-connector)

### Deploy VMRay Enrichment Function App
> Please redeploy the Enrichment Function App, following the instructions given in the document.
>- [Deploy VMRay Enrichment Function App Connector](#deploy-vmray-enrichment-function-app-connector)

### Deploy Logic Apps
> Please redeploy the Logic Apps, following the instructions given in the document.
>- [Deploy VMRay Enrichment Logic Apps](#deploy-vmray-enrichment-logic-apps)
