# Fresh setup: Azure SQL Hyperscale database-level CMK across tenants with Managed HSM

Documentation checked: **18 November 2026**.

## 1. Outcome and non-negotiable tenant boundaries

This runbook creates a **new Hyperscale database** in an ISV tenant and protects its database encryption key with a customer-managed key in **Azure Key Vault Managed HSM in the customer's tenant**. It uses **database-level**, not server-level, transparent data encryption (TDE) key management.

- The ISV operator signs in **only to the ISV tenant**.
- The customer operator signs in **only to the customer tenant**.
- **Neither operator needs a guest account, directory role, subscription role, or SQL login in the other tenant.**
- The customer creates a local **enterprise application/service principal** for the ISV's multitenant application. This is a workload identity, **not an ISV guest user**. This workload trust is required; a design allowing no cross-tenant workload access at all cannot use this feature.
- Only non-secret identifiers and readiness confirmations are exchanged. No app secret, certificate private key, SQL password, key material, or HSM security domain is exchanged.
- The SQL logical server stays on its default **service-managed** TDE protector. Only the new database receives the customer's protector.

This is a new, standalone procedure. It does not depend on the earlier Key Vault guide or its script, and it does not reuse their resource names, IDs, or guest-user workarounds.

### Trust flow

```text
ISV tenant                                  Customer tenant
----------                                  ---------------
Hyperscale database
  | database user-assigned managed identity
  | federated credential on ISV application
  +--> multitenant app client ID ----------> local enterprise application
                                             | HSM-local service-encryption role
                                             v
                                           Managed HSM / customer key

ISV human: ISV tenant only                  Customer human: customer tenant only
```

The customer grants the **customer-tenant service principal** access to one HSM key, not to the ISV user's account or to the ISV managed identity's object ID.

**Security boundary:** TDE protects data at rest; it does not prevent an authorized SQL administrator/application from reading data through SQL. The ISV controls the application's credentials and federation configuration, so the customer is trusting that application, not cryptographically restricting it to one SQL database. Use a dedicated application and managed identity per customer/isolation boundary; govern app ownership and changes in the ISV tenant. Do not put unrelated credentials or federated identities on this application.

### Choose one execution method per step

Every configuration step below has portal instructions and optional Bash/Azure CLI and Azure PowerShell equivalents. Run **one alternative**, not all three. Stop at each checkpoint.

- **Portal-first:** complete the portal steps. Customer enterprise-app provisioning can use a single Cloud Shell command, or the optional browser-consent route in step 4.
- **Bash:** use Azure Cloud Shell Bash or a workstation with current Azure CLI. Commands are Bash, not Windows PowerShell.
- **PowerShell:** use PowerShell **7.4 or newer** with current `Az.Accounts`, `Az.Resources`, `Az.ManagedServiceIdentity`, `Az.KeyVault`, and `Az.Sql`.
- Each party uses their **own workstation/profile/session**. Do not share an authenticated Cloud Shell or CLI configuration directory.
- Keep that party's variables in the same shell between steps. If restarting or mixing portal and script steps, initialize the variables again and populate IDs from the checkpoints before continuing.
- These are fresh-create commands, **not an idempotent deployment tool**. Rerunning app creation makes another application; rerunning key creation makes another key version. After a failure, resolve it and rerun only the failed operation.
- No command in this document has been executed against your subscriptions. Validation here is documentation/syntax/command-contract checking, not an Azure deployment test.

## 2. Prerequisites, roles, and worksheet

### Permissions: assign locally, never across tenants

| Party | Permission | Purpose |
|---|---|---|
| ISV Azure operator | Contributor on the new SQL resource group, plus permission to create the group if it does not exist | Create logical server, database, and managed identity; attach that identity. Contributor on the same group covers identity assignment. For split scopes, use appropriate SQL write roles plus Managed Identity Operator on the identity. |
| ISV application operator | Tenant policy allowing app registration and ownership of the app, or an appropriate Entra application-administration role | Create the multitenant app and its federated credential. Azure Contributor alone does not grant Graph/application rights. |
| Customer Azure operator | Contributor at the resource-creation scope; permission to create the group if required | Provision Managed HSM and configure networking/purge protection. |
| Customer Entra administrator | For example, Cloud Application Administrator, subject to tenant policy | Provision the local service principal for the external multitenant app. |
| Customer HSM initial administrator | Named as an initial administrator when provisioning | Activate HSM and manage **HSM-local** role assignments. |
| Customer key custodian/operator | **Managed HSM Crypto User**, assigned locally at `/keys` | Generate/manage the TDE key. The initial HSM Administrator role by itself **cannot create keys**. |
| Runtime enterprise application | **Managed HSM Crypto Service Encryption User**, locally at `/keys/<key-name>` | Read key metadata and wrap/unwrap the database encryption key. No role on the customer subscription is required. |

Different people within a party can perform these duties. An HSM Administrator can assign local HSM roles without Azure Owner. Conversely, Azure Owner/Contributor does **not** automatically grant HSM key access.

### Before creating billable resources

1. Both tenants and their Azure subscriptions must already exist and be active. This runbook creates resources, not new Entra tenants/subscriptions.
2. Verify regional Managed HSM availability, subscription quota, and Hyperscale capacity. Example sizing is provisioned Gen5, 2 vCores; adjust to approved capacity.
3. **Managed HSM has a substantial always-on cost.** With purge protection, deletion does not avoid charges during the retention period. Obtain cost approval first.
4. Choose globally unique SQL server and HSM names. HSM names are 3-24 characters. Examples below must be replaced with available names.
5. In each subscription, open **Subscriptions > Resource providers** and register the providers used below if not already registered:
   - ISV: `Microsoft.Sql`, `Microsoft.ManagedIdentity`.
   - Customer: `Microsoft.KeyVault`.
   - CLI equivalent: `az provider register --namespace Microsoft.Sql --wait` (substitute each applicable provider).
   - PowerShell equivalent: `Register-AzResourceProvider -ProviderNamespace Microsoft.Sql`; check `Get-AzResourceProvider -ProviderNamespace Microsoft.Sql` until `RegistrationState` is `Registered`, before proceeding.
6. Customer: obtain an approved **public IPv4 egress address/CIDR** for the machine doing activation/key administration. The HSM firewall must allow it. Portal key operations also originate from the operator's network; Cloud Shell has a different egress and is **not automatically allowed** by trusted-services bypass.
7. Customer: plan security-domain custody: at least three RSA wrapping certificate/key pairs and a recovery quorum (example: **2 of 3**). Prepare these under customer control, preferably offline with separate custodians. Private keys never go to Azure or the ISV.
8. Use public Azure endpoints in this runbook. Sovereign clouds require their own endpoints and compatibility checks.

### Values to agree on

| Value | Owner | Example / source |
|---|---|---|
| ISV tenant/subscription IDs | ISV | ISV Entra Overview / subscription Overview |
| Customer tenant/subscription IDs | Customer | Customer Entra Overview / subscription Overview |
| ISV resource group | ISV | `rg-isv-hs-cmk-new` |
| Customer resource group | Customer | `rg-customer-mhsm-new` |
| Region | Each | `eastus`, or an approved supported region |
| SQL server / database | ISV | Globally unique server / `hs-customer-a` |
| Managed identity / app | ISV | `mi-hs-customer-a` / `app-hs-cmk-customer-a` |
| SQL Entra admin name and object ID | ISV | ISV-native user; **not** the UAMI or customer user |
| HSM name / key name | Customer | Globally unique HSM / `sql-tde-customer-a` |
| Customer initial administrator object ID | Customer | Customer-native user: Entra Users > user > Overview > Object ID |
| Customer admin egress CIDR | Customer | Approved public IPv4 `/32` or CIDR, not an RFC1918 address |

**Key type:** current SQL documentation recommends **AES-256** for new Azure SQL Database TDE protectors. This guide generates an HSM-backed `oct-HSM` 256-bit key. Supported RSA-HSM 2048/3072-bit keys are also an option if required by your policy; do not use EC or RSA 4096 for this TDE procedure. The RSA certificates used to activate the HSM are **separate from the TDE key**, even when the TDE key is AES.

## 3. Step 0 - Initialize each operator's own session

### Portal

Use separate browser profiles for the two operators. Check **Directories + subscriptions** and the tenant ID before each party's work. Each operator selects only their own subscription.

### Bash / Azure CLI - ISV only

Replace all angle-bracket placeholders. Run this initializer once in the ISV shell. The same context-check function must also be defined in the customer's independent Bash shell; it is repeated in that initializer.

```bash
set -Eeuo pipefail
trap 'printf "FAILED at line %s. Stop and resolve the error before continuing.\n" "$LINENO" >&2' ERR

ISV_TENANT_ID="<isv-tenant-guid>"
ISV_SUBSCRIPTION_ID="<isv-subscription-guid>"
ISV_RG="rg-isv-hs-cmk-new"
LOCATION="eastus"
UAMI_NAME="mi-hs-customer-a"
APP_NAME="app-hs-cmk-customer-a"
SQL_SERVER="<globally-unique-sql-server-name>"
DATABASE="hs-customer-a"
SQL_ADMIN_NAME="<isv-native-admin-user-principal-name>"
SQL_ADMIN_OBJECT_ID="<isv-native-admin-user-object-guid>"
SQL_CLIENT_IPV4="<approved-sql-client-public-ipv4>"

assert_context() {
  local tenant="$1" subscription="$2" actual_tenant actual_subscription
  actual_tenant="$(az account show --query tenantId -o tsv)"
  actual_subscription="$(az account show --query id -o tsv)"
  if [[ "${actual_tenant,,}" != "${tenant,,}" || "${actual_subscription,,}" != "${subscription,,}" ]]; then
    printf "Wrong Azure tenant/subscription. Stop.\n" >&2
    return 1
  fi
}

az login --tenant "$ISV_TENANT_ID" --output none
az account set --subscription "$ISV_SUBSCRIPTION_ID"
assert_context "$ISV_TENANT_ID" "$ISV_SUBSCRIPTION_ID"
az account show --query '{tenant:tenantId,subscription:id,user:user.name}' -o table
```

### Azure PowerShell - ISV only

If modules are missing, install the current `Az` module under your organization's approved policy before starting. Do not use deprecated `AzureAD` or `MSOnline` cmdlets.

```powershell
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
Disable-AzContextAutosave -Scope Process | Out-Null

$IsvTenantId = '<isv-tenant-guid>'
$IsvSubscriptionId = '<isv-subscription-guid>'
$IsvRg = 'rg-isv-hs-cmk-new'
$Location = 'eastus'
$UamiName = 'mi-hs-customer-a'
$AppName = 'app-hs-cmk-customer-a'
$SqlServer = '<globally-unique-sql-server-name>'
$Database = 'hs-customer-a'
$SqlAdminName = '<isv-native-admin-user-principal-name>'
$SqlAdminObjectId = '<isv-native-admin-user-object-guid>'
$SqlClientIPv4 = '<approved-sql-client-public-ipv4>'

function Assert-AzureContext {
    param([string]$TenantId, [string]$SubscriptionId)
    $context = Get-AzContext
    if (!$context -or $context.Tenant.Id -ne $TenantId -or
        $context.Subscription.Id -ne $SubscriptionId) {
        throw 'Wrong Azure tenant/subscription. Stop.'
    }
}

Connect-AzAccount -Tenant $IsvTenantId -Subscription $IsvSubscriptionId | Out-Null
Assert-AzureContext $IsvTenantId $IsvSubscriptionId
Get-AzContext | Select-Object Account, Tenant, Subscription
```

**Checkpoint:** the displayed account is an ISV-native operator and the IDs match the ISV worksheet.

## 4. Step 1 - ISV creates the resource group and managed identity

### Portal

1. **Resource groups > Create**: choose the ISV subscription, group name, and region.
2. **Managed Identities > Create**: choose that group, region, and identity name.
3. Record the identity's **Resource ID**, **Client ID**, and **Principal/Object ID**.

### Bash

```bash
assert_context "$ISV_TENANT_ID" "$ISV_SUBSCRIPTION_ID"
az group create --name "$ISV_RG" --location "$LOCATION" --output none
az identity create --resource-group "$ISV_RG" --name "$UAMI_NAME" --location "$LOCATION" --output none
UAMI_ID="$(az identity show -g "$ISV_RG" -n "$UAMI_NAME" --query id -o tsv)"
UAMI_PRINCIPAL_ID="$(az identity show -g "$ISV_RG" -n "$UAMI_NAME" --query principalId -o tsv)"
az identity show -g "$ISV_RG" -n "$UAMI_NAME" \
  --query '{resourceId:id,clientId:clientId,principalId:principalId}' -o json
```

### PowerShell

```powershell
Assert-AzureContext $IsvTenantId $IsvSubscriptionId
New-AzResourceGroup -Name $IsvRg -Location $Location | Out-Null
$identity = New-AzUserAssignedIdentity -ResourceGroupName $IsvRg -Name $UamiName -Location $Location
$UamiId = $identity.Id
$UamiPrincipalId = $identity.PrincipalId
$identity | Select-Object Id, ClientId, PrincipalId
```

**Checkpoint:** save `UAMI_ID` / `$UamiId` locally. Its **principal ID**, not client ID, becomes the federation subject.

## 5. Step 2 - ISV creates a multitenant application

### Portal

1. **Microsoft Entra ID > App registrations > New registration**.
2. Enter the application name.
3. Select **Accounts in any organizational directory (Any Microsoft Entra ID tenant - Multitenant)**, then **Register**.
4. Record **Application (client) ID** and **Object ID**. These are different IDs.
5. Under **Owners**, use approved ISV administrators. Do not add a customer user.
6. No client secret or certificate credential is required.
7. No Microsoft Graph application permission or Azure subscription role is required by this runtime application. For direct service-principal provisioning in step 4, remove an automatically added delegated `User.Read` permission if present. The optional browser-consent route is explained separately.

The portal normally creates a home-tenant service principal with the app registration. The script alternatives explicitly create it as well, so the app is available to identity-selection experiences. This ISV-local enterprise application is separate from the customer-local enterprise application created later; neither receives a directory or subscription role.

### Bash

```bash
assert_context "$ISV_TENANT_ID" "$ISV_SUBSCRIPTION_ID"
APP_OBJECT_ID="$(az ad app create --display-name "$APP_NAME" \
  --sign-in-audience AzureADMultipleOrgs --query id -o tsv)"
APP_CLIENT_ID="$(az ad app show --id "$APP_OBJECT_ID" --query appId -o tsv)"
az ad sp create --id "$APP_CLIENT_ID" --output none
az ad app show --id "$APP_OBJECT_ID" \
  --query '{clientId:appId,appObjectId:id,audience:signInAudience}' -o json
```

### PowerShell

```powershell
Assert-AzureContext $IsvTenantId $IsvSubscriptionId
$app = New-AzADApplication -DisplayName $AppName -SignInAudience AzureADMultipleOrgs
$AppObjectId = $app.Id
$AppClientId = $app.AppId
New-AzADServicePrincipal -ApplicationId $AppClientId | Out-Null
$app | Select-Object AppId, Id, SignInAudience
```

**Checkpoint:** audience is `AzureADMultipleOrgs`. Record client ID separately from the ISV app object ID.

## 6. Step 3 - ISV federates the managed identity to the application; handoff A

### Portal

1. Open the **app registration**, not a customer enterprise application.
2. **Certificates & secrets > Federated credentials > Add credential**.
3. Choose the supported **Managed identity** scenario and select the identity from step 1. If this scenario is not available, use **Other issuer**:

| Field | Value |
|---|---|
| Name | `fic-hs-customer-a` |
| Issuer | `https://login.microsoftonline.com/<ISV-TENANT-ID>/v2.0` |
| Subject | Managed identity **Principal/Object ID** from step 1 |
| Audience | `api://AzureADTokenExchange` |

4. Save. Issuer, subject, and audience must match exactly.

### Bash

This uses Microsoft Graph through Azure CLI, authenticated as the ISV operator. It does not sign in as the runtime application.

```bash
assert_context "$ISV_TENANT_ID" "$ISV_SUBSCRIPTION_ID"
FIC_JSON="$(printf '{"name":"fic-hs-customer-a","issuer":"https://login.microsoftonline.com/%s/v2.0","subject":"%s","audiences":["api://AzureADTokenExchange"]}' \
  "$ISV_TENANT_ID" "$UAMI_PRINCIPAL_ID")"
az ad app federated-credential create --id "$APP_OBJECT_ID" --parameters "$FIC_JSON"
az ad app federated-credential list --id "$APP_OBJECT_ID" -o json
printf 'ISV tenant: %s\nApplication client ID: %s\nApplication name: %s\n' \
  "$ISV_TENANT_ID" "$APP_CLIENT_ID" "$APP_NAME"
```

### PowerShell

```powershell
Assert-AzureContext $IsvTenantId $IsvSubscriptionId
New-AzADAppFederatedCredential -ApplicationObjectId $AppObjectId `
    -Name 'fic-hs-customer-a' `
    -Issuer "https://login.microsoftonline.com/$IsvTenantId/v2.0" `
    -Subject $UamiPrincipalId -Audience 'api://AzureADTokenExchange'
Get-AzADAppFederatedCredential -ApplicationObjectId $AppObjectId
[pscustomobject]@{
    IsvTenantId = $IsvTenantId
    ApplicationClientId = $AppClientId
    ApplicationName = $AppName
}
```

### Handoff A: ISV sends to customer

- ISV tenant ID, application display name, and **application client ID**.
- Confirmation that the app is multitenant and federation is configured.
- The customer verifies these identifiers with the ISV through an authenticated business channel before trusting the application.

The customer does **not** need the UAMI in their directory, the ISV app object ID for role assignment, or an ISV user invitation.

## 7. Step 4 - Customer initializes their own session and provisions the enterprise application

### Customer session - Bash

```bash
set -Eeuo pipefail
trap 'printf "FAILED at line %s. Stop and resolve the error before continuing.\n" "$LINENO" >&2' ERR

CUSTOMER_TENANT_ID="<customer-tenant-guid>"
CUSTOMER_SUBSCRIPTION_ID="<customer-subscription-guid>"
CUSTOMER_RG="rg-customer-mhsm-new"
CUSTOMER_LOCATION="eastus"
HSM_NAME="<globally-unique-hsm-name>"
KEY_NAME="sql-tde-customer-a"
CUSTOMER_ADMIN_OBJECT_ID="<customer-initial-admin-user-object-guid>"
CUSTOMER_ADMIN_CIDR="<approved-customer-admin-public-ipv4-cidr>"
APP_CLIENT_ID="<application-client-id-from-handoff-A>"

assert_context() {
  local tenant="$1" subscription="$2" actual_tenant actual_subscription
  actual_tenant="$(az account show --query tenantId -o tsv)"
  actual_subscription="$(az account show --query id -o tsv)"
  if [[ "${actual_tenant,,}" != "${tenant,,}" || "${actual_subscription,,}" != "${subscription,,}" ]]; then
    printf "Wrong Azure tenant/subscription. Stop.\n" >&2
    return 1
  fi
}

az login --tenant "$CUSTOMER_TENANT_ID" --output none
az account set --subscription "$CUSTOMER_SUBSCRIPTION_ID"
assert_context "$CUSTOMER_TENANT_ID" "$CUSTOMER_SUBSCRIPTION_ID"
az account show --query '{tenant:tenantId,subscription:id,user:user.name}' -o table
```

### Customer session - PowerShell

```powershell
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
Disable-AzContextAutosave -Scope Process | Out-Null

$CustomerTenantId = '<customer-tenant-guid>'
$CustomerSubscriptionId = '<customer-subscription-guid>'
$CustomerRg = 'rg-customer-mhsm-new'
$CustomerLocation = 'eastus'
$HsmName = '<globally-unique-hsm-name>'
$KeyName = 'sql-tde-customer-a'
$CustomerAdminObjectId = '<customer-initial-admin-user-object-guid>'
$CustomerAdminCidr = '<approved-customer-admin-public-ipv4-cidr>'
$AppClientId = '<application-client-id-from-handoff-A>'

function Assert-AzureContext {
    param([string]$TenantId, [string]$SubscriptionId)
    $context = Get-AzContext
    if (!$context -or $context.Tenant.Id -ne $TenantId -or
        $context.Subscription.Id -ne $SubscriptionId) {
        throw 'Wrong Azure tenant/subscription. Stop.'
    }
}

Connect-AzAccount -Tenant $CustomerTenantId -Subscription $CustomerSubscriptionId | Out-Null
Assert-AzureContext $CustomerTenantId $CustomerSubscriptionId
Get-AzContext | Select-Object Account, Tenant, Subscription
```

### Portal-first route - recommended provisioning without extra API permissions

1. Customer signs in with their **own customer-native administrator account**.
2. In the Azure portal, open **Cloud Shell > Bash** and run the customer initializer above.
3. Run the Bash provisioning block below.
4. Open **Microsoft Entra ID > Enterprise applications**, remove restrictive application-type filters if necessary, and search by the **application client ID**.
5. Open the result and verify the application ID, ISV publisher/home tenant information, and customer-local **Object ID**.

There is no need to use **Enterprise applications > Create your own application > Non-gallery application**. That does not provision this external app by its client ID and can create the wrong application.

### Bash - provision the customer-local service principal

For a fresh setup:

```bash
assert_context "$CUSTOMER_TENANT_ID" "$CUSTOMER_SUBSCRIPTION_ID"
CUSTOMER_SP_OBJECT_ID="$(az ad sp create --id "$APP_CLIENT_ID" --query id -o tsv)"
az ad sp show --id "$CUSTOMER_SP_OBJECT_ID" \
  --query '{clientId:appId,customerObjectId:id,homeTenant:appOwnerOrganizationId,name:displayName}' -o json
```

### PowerShell - provision the customer-local service principal

```powershell
Assert-AzureContext $CustomerTenantId $CustomerSubscriptionId
$customerSp = New-AzADServicePrincipal -ApplicationId $AppClientId
$CustomerSpObjectId = $customerSp.Id
$customerSp | Select-Object AppId, Id, AppOwnerOrganizationId, DisplayName
```

If the service principal already exists, **do not create a replacement application**. Retrieve the existing principal and verify its application ID/home tenant:

```bash
CUSTOMER_SP_OBJECT_ID="$(az ad sp show --id "$APP_CLIENT_ID" --query id -o tsv)"
az ad sp show --id "$CUSTOMER_SP_OBJECT_ID" -o json
```

```powershell
$customerSp = Get-AzADServicePrincipal -ApplicationId $AppClientId
if (!$customerSp) { throw 'Expected customer service principal was not found.' }
$CustomerSpObjectId = $customerSp.Id
$customerSp | Select-Object AppId, Id, AppOwnerOrganizationId, DisplayName
```

### Optional browser-only application onboarding, instead of Cloud Shell

This is an **alternative** to the direct provisioning commands, not a TDE requirement. It uses an admin-consent browser flow and therefore requires a configured redirect URI and a consent scope.

1. ISV, in its own app registration: **Authentication > Add a platform > Web**. Add an exact HTTPS redirect URI on an **ISV-owned, controlled onboarding endpoint**.
2. ISV: **API permissions > Add a permission > Microsoft Graph > Delegated permissions > User.Read**. Do **not** add application permissions such as `Directory.Read.All`.
3. ISV constructs the following URL, replacing the customer tenant ID and client ID and URL-encoding its exact registered redirect URI:

```text
https://login.microsoftonline.com/<CUSTOMER-TENANT-ID>/v2.0/adminconsent?client_id=<APPLICATION-CLIENT-ID>&scope=https%3A%2F%2Fgraph.microsoft.com%2FUser.Read&redirect_uri=<URL-ENCODED-REGISTERED-HTTPS-REDIRECT-URI>
```

4. Customer administrator opens that URL, confirms they are signing in to their **own tenant**, verifies the app/publisher and permission request, and approves it subject to customer policy.
5. Customer verifies the enterprise application's existence and local object ID in Entra as described above. A redirect alone is not proof of correct provisioning.

This route grants delegated access to a signed-in user's basic profile; it does **not** grant an app-only directory-read role, invite a user to either tenant, or authorize HSM use. The TDE runtime never needs this Graph permission or an interactive customer sign-in. Prefer direct service-principal provisioning if the customer wants **no Graph consent grant**. Maintain any real onboarding endpoint under normal application security practices; validating consent callbacks is outside this infrastructure runbook.

**Checkpoint:** the customer enterprise app has the **same client ID** as handoff A, a **different local object ID** from the ISV app registration, and the expected ISV home tenant. Save its customer object ID for step 8.

## 8. Step 5 - Customer provisions Managed HSM, recovery protection, and networking

### Portal

1. **Managed HSM Pools > Create**; choose the customer subscription, new resource group, globally unique HSM name, supported region, and Standard B1 SKU.
2. Set **Initial administrator(s)** to the approved customer-native administrator(s). Do not select any ISV user.
3. Enable **purge protection** and choose the approved soft-delete retention (example: 90 days). Soft-delete is part of Managed HSM recovery protection. Purge protection cannot subsequently be disabled.
4. Under **Networking > Public access > Manage**, enable public access **from selected networks**, allow the customer administration public IPv4/CIDR, and enable **Allow trusted Microsoft services to bypass this firewall**.
5. Review and create. Wait for successful provisioning.
6. Verify purge protection, retention, initial administrators, HSM URI, and networking on the deployed resource.

**Network design in this runbook:** restricted public HSM endpoint plus the trusted Azure SQL service bypass. This does not grant authorization; HSM-local role assignment is still required. Do not broadly allow all IP addresses. A private endpoint is not a drop-in replacement that automatically routes Azure SQL's managed TDE service through a customer VNet. Private-only designs need a separately validated SQL/HSM connectivity design; do not disable the working service path as an untested hardening step.

### Bash

```bash
assert_context "$CUSTOMER_TENANT_ID" "$CUSTOMER_SUBSCRIPTION_ID"
az group create --name "$CUSTOMER_RG" --location "$CUSTOMER_LOCATION" --output none
az keyvault create --hsm-name "$HSM_NAME" --resource-group "$CUSTOMER_RG" \
  --location "$CUSTOMER_LOCATION" --sku Standard_B1 \
  --administrators "$CUSTOMER_ADMIN_OBJECT_ID" \
  --enable-purge-protection true --retention-days 90 \
  --public-network-access Enabled --default-action Deny --bypass AzureServices \
  --network-acls-ips "$CUSTOMER_ADMIN_CIDR" --output none
az keyvault show --hsm-name "$HSM_NAME" --resource-group "$CUSTOMER_RG" \
  --query '{tenant:properties.tenantId,uri:properties.hsmUri,purgeProtection:properties.enablePurgeProtection,retention:properties.softDeleteRetentionInDays,network:properties.networkAcls}' -o json
```

### PowerShell

```powershell
Assert-AzureContext $CustomerTenantId $CustomerSubscriptionId
New-AzResourceGroup -Name $CustomerRg -Location $CustomerLocation | Out-Null
$network = New-AzKeyVaultManagedHsmNetworkRuleSetObject `
    -DefaultAction Deny -Bypass AzureServices -IpAddressRange @($CustomerAdminCidr)
$hsmParameters = @{
    Name = $HsmName
    ResourceGroupName = $CustomerRg
    Location = $CustomerLocation
    Administrator = @($CustomerAdminObjectId)
    Sku = 'Standard_B1'
    SoftDeleteRetentionInDays = 90
    EnablePurgeProtection = $true
    PublicNetworkAccess = 'Enabled'
    NetworkRuleSet = $network
}
New-AzKeyVaultManagedHsm @hsmParameters
Get-AzKeyVaultManagedHsm -Name $HsmName -ResourceGroupName $CustomerRg | Format-List
```

**Checkpoint:** provisioning succeeded in the **customer tenant**, purge protection is enabled, and admin networking is allowed. Provisioned is **not yet activated**.

## 9. Step 6 - Customer activates the HSM and safeguards the security domain

### Prepare wrapping certificates under customer control

The portal does not replace the customer's key-custody process. Obtain three **public RSA certificates** from customer custodians and use a 2-of-3 quorum (or an approved stronger arrangement). Keep their corresponding encrypted private keys separately with those custodians.

If starting from nothing, each custodian can run the following on their own approved secure/offline workstation with OpenSSL. Run once per custodian, changing `custodian1` to `custodian2` or `custodian3` on the other workstations. This prompts for a private-key passphrase. Do not put that passphrase in command arguments or source control.

### Bash - each customer custodian's secure workstation

```bash
set -euo pipefail
umask 077
openssl genrsa -aes256 -out custodian1.key 3072
openssl req -new -x509 -sha256 -days 3650 \
  -key custodian1.key -out custodian1.cer -subj "/CN=Customer-HSM-Custodian-1"
```

### PowerShell - each customer custodian's secure workstation

Use PowerShell 7.4+ and OpenSSL. Store the files in an access-controlled customer directory.

```powershell
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
openssl genrsa -aes256 -out custodian1.key 3072
openssl req -new -x509 -sha256 -days 3650 `
    -key custodian1.key -out custodian1.cer -subj '/CN=Customer-HSM-Custodian-1'
```

Only collect the three `.cer` public certificate files on the customer's activation workstation. Never collect the three private keys together merely for convenience. Certificate expiration does not remove the need to retain the keys for HSM recovery.

### Portal activation

1. The **customer initial administrator** opens the HSM from an allowed administration network.
2. Open **Settings > Security domain** and the activation/download workflow.
3. Upload `custodian1.cer`, `custodian2.cer`, and `custodian3.cer`.
4. Set quorum to **2** and download the encrypted security-domain file.
5. Securely archive it in the customer's recovery system, with separate custody of wrapping private keys.

### Bash activation

Run in the customer's initialized Azure shell, in the directory containing **public certificates only**, on an allowed network:

```bash
assert_context "$CUSTOMER_TENANT_ID" "$CUSTOMER_SUBSCRIPTION_ID"
az keyvault security-domain download --hsm-name "$HSM_NAME" \
  --sd-wrapping-keys custodian1.cer custodian2.cer custodian3.cer \
  --sd-quorum 2 --security-domain-file customer-hsm-security-domain.json
test -s customer-hsm-security-domain.json
```

### PowerShell activation

```powershell
Assert-AzureContext $CustomerTenantId $CustomerSubscriptionId
Export-AzKeyVaultSecurityDomain -Name $HsmName `
    -Certificates @('custodian1.cer', 'custodian2.cer', 'custodian3.cer') `
    -Quorum 2 -OutputPath 'customer-hsm-security-domain.json'
if ((Get-Item 'customer-hsm-security-domain.json').Length -eq 0) {
    throw 'Security-domain download is empty; stop.'
}
```

**Checkpoint:** activation/download completed successfully. Do not proceed until the security-domain file and the required quorum of wrapping private keys are safely retained by the customer. Losing these can make HSM disaster recovery impossible. Do not share them with the ISV or store them in this workspace.

## 10. Step 7 - Customer grants their key operator permission and generates the TDE key

### Portal

1. On the activated HSM open **Local RBAC**, not resource **Access control (IAM)**.
2. The initial HSM administrator assigns **Managed HSM Crypto User** to the approved customer key operator at **`/keys`**. For this single-operator example, this is the same customer administrator object ID.
3. Wait for assignment propagation. Refresh/re-authenticate if necessary.
4. **Keys > Generate/Import > Generate**:
   - Name: `sql-tde-customer-a`.
   - Key type: **oct-HSM / symmetric AES**, size **256 bits**.
   - Key operations: **Wrap Key**, **Unwrap Key**.
   - Enabled: **Yes**.
   - No future activation date. Set expiration only with a tested renewal/rotation process.
   - Do not enable exportability or configure a key-release policy for this procedure.
5. Open the new key version and copy the full **versioned Key Identifier**.

If the portal version/region does not expose AES key generation, use the commands below with current tooling rather than silently substituting an unsupported key.

### Bash

Run the role-assignment command first:

```bash
assert_context "$CUSTOMER_TENANT_ID" "$CUSTOMER_SUBSCRIPTION_ID"
az keyvault role assignment create --hsm-name "$HSM_NAME" \
  --role "Managed HSM Crypto User" \
  --assignee-object-id "$CUSTOMER_ADMIN_OBJECT_ID" --scope /keys
```

After role propagation, generate the key **once**:

```bash
assert_context "$CUSTOMER_TENANT_ID" "$CUSTOMER_SUBSCRIPTION_ID"
KEY_ID="$(az keyvault key create --hsm-name "$HSM_NAME" --name "$KEY_NAME" \
  --kty oct-HSM --size 256 --ops wrapKey unwrapKey --query key.kid -o tsv)"
az keyvault key show --id "$KEY_ID" \
  --query '{keyId:key.kid,type:key.kty,operations:key.keyOps,enabled:attributes.enabled,expires:attributes.exp,recovery:attributes.recoveryLevel}' -o json
printf 'Versioned key ID: %s\n' "$KEY_ID"
```

### PowerShell

Run the role-assignment command first:

```powershell
Assert-AzureContext $CustomerTenantId $CustomerSubscriptionId
New-AzKeyVaultRoleAssignment -HsmName $HsmName `
    -RoleDefinitionName 'Managed HSM Crypto User' `
    -ObjectId $CustomerAdminObjectId -Scope '/keys'
```

After role propagation, generate the key **once**. With `-HsmName`, `-KeyType oct` generates an HSM-backed symmetric key; `-Destination` is not part of this HSM parameter set.

```powershell
Assert-AzureContext $CustomerTenantId $CustomerSubscriptionId
$key = Add-AzKeyVaultKey -HsmName $HsmName -Name $KeyName `
    -KeyType oct -Size 256 -KeyOps @('wrapKey', 'unwrapKey')
$KeyId = ([uri]$key.Id).AbsoluteUri
Get-AzKeyVaultKey -HsmName $HsmName -Name $KeyName -Version $key.Version | Format-List
$KeyId
```

**Checkpoint:** enabled, HSM-backed AES-256 key; allowed wrap/unwrap operations; key URI resembles:

```text
https://<hsm-name>.managedhsm.azure.net/keys/sql-tde-customer-a/<version>
```

Do not pass a version GUID alone, a versionless URI, an HSM resource ID, or a `.vault.azure.net` URI from an unrelated Key Vault.

## 11. Step 8 - Customer grants the application access to this key; handoff B

### Portal

1. Open HSM **Local RBAC > Add role assignment**.
2. Choose **Managed HSM Crypto Service Encryption User**.
3. Scope: the single key, **`/keys/sql-tde-customer-a`**. This includes its versions, so a later version rotation does not require broadening the grant.
4. Member: the **customer-local enterprise application** created in step 4. Match its client ID and customer-local object ID, not only its display name.
5. Save and allow propagation. If the picker cannot resolve it yet, wait or use the object-ID command below.

Do **not** use `Key Vault Crypto Service Encryption User`, a Key Vault access policy, or Azure `az role assignment create`. Managed HSM uses its own **local** data-plane RBAC.

### Bash

```bash
assert_context "$CUSTOMER_TENANT_ID" "$CUSTOMER_SUBSCRIPTION_ID"
az keyvault role assignment create --hsm-name "$HSM_NAME" \
  --role "Managed HSM Crypto Service Encryption User" \
  --assignee-object-id "$CUSTOMER_SP_OBJECT_ID" --scope "/keys/$KEY_NAME"
az keyvault role assignment list --hsm-name "$HSM_NAME" \
  --scope "/keys/$KEY_NAME" -o json
printf 'Customer tenant: %s\nApplication client ID: %s\nCustomer SP object ID: %s\nVersioned key ID: %s\n' \
  "$CUSTOMER_TENANT_ID" "$APP_CLIENT_ID" "$CUSTOMER_SP_OBJECT_ID" "$KEY_ID"
```

### PowerShell

```powershell
Assert-AzureContext $CustomerTenantId $CustomerSubscriptionId
New-AzKeyVaultRoleAssignment -HsmName $HsmName `
    -RoleDefinitionName 'Managed HSM Crypto Service Encryption User' `
    -ObjectId $CustomerSpObjectId -Scope "/keys/$KeyName"
Get-AzKeyVaultRoleAssignment -HsmName $HsmName -Scope "/keys/$KeyName"
[pscustomobject]@{
    CustomerTenantId = $CustomerTenantId
    ApplicationClientId = $AppClientId
    CustomerServicePrincipalObjectId = $CustomerSpObjectId
    VersionedKeyId = $KeyId
}
```

### Handoff B: customer sends to ISV

- Customer tenant ID and the **full versioned HSM key identifier**.
- Confirmation of application client ID and customer-local service principal object ID.
- Confirmation that HSM activation, purge protection, enabled key state, key-level local role assignment, and trusted-service networking are ready.

These are identifiers, not credentials. The ISV need not browse the customer's HSM or sign in to the customer tenant. Do **not** grant the ISV operator HSM Reader/admin permissions just to make a portal picker work.

## 12. Step 9 - ISV creates a new logical SQL server

Resume the ISV's original shell or browser profile. The customer does not perform this step.

### Portal

1. Start **SQL databases > Create** using the ISV group and database name.
2. Under **Server > Create new**, enter the unique server name and region.
3. Choose **Microsoft Entra-only authentication**, set the approved **ISV-native user** as administrator, and save the server selection.
4. Continue creating the database in step 10. If creating the logical server separately, finish that resource first.
5. For this example use a public SQL endpoint with **only the approved ISV SQL client IPv4 firewall rule**. Keep **Allow Azure services and resources to access this server = No**. Production private SQL connectivity is an independent network design.
6. Leave **server-level** TDE key management as **Service-managed**. The server does not need the customer's federated identity or key.

### Bash - create server and a narrow client firewall rule

```bash
assert_context "$ISV_TENANT_ID" "$ISV_SUBSCRIPTION_ID"
az sql server create --resource-group "$ISV_RG" --name "$SQL_SERVER" \
  --location "$LOCATION" --enable-ad-only-auth \
  --external-admin-principal-type User --external-admin-name "$SQL_ADMIN_NAME" \
  --external-admin-sid "$SQL_ADMIN_OBJECT_ID" --minimal-tls-version 1.2 --output none
az sql server firewall-rule create --resource-group "$ISV_RG" --server "$SQL_SERVER" \
  --name ApprovedIsvSqlClient --start-ip-address "$SQL_CLIENT_IPV4" \
  --end-ip-address "$SQL_CLIENT_IPV4" --output none
```

### PowerShell

```powershell
Assert-AzureContext $IsvTenantId $IsvSubscriptionId
New-AzSqlServer -ResourceGroupName $IsvRg -ServerName $SqlServer -Location $Location `
    -EnableActiveDirectoryOnlyAuthentication `
    -ExternalAdminName $SqlAdminName -ExternalAdminSID $SqlAdminObjectId `
    -PublicNetworkAccess Enabled -MinimalTlsVersion '1.2' | Out-Null
New-AzSqlServerFirewallRule -ResourceGroupName $IsvRg -ServerName $SqlServer `
    -FirewallRuleName 'ApprovedIsvSqlClient' -StartIpAddress $SqlClientIPv4 `
    -EndIpAddress $SqlClientIPv4 | Out-Null
```

**Checkpoint:** new server exists in the ISV tenant; SQL administrator is an ISV-native user; server protector is still service-managed. No SQL administrator password is needed in this example.

## 13. Step 10 - ISV creates the Hyperscale database with database-level cross-tenant CMK

Do not create a temporary service-managed database first: these examples assign the database identity and customer protector **during database creation**.

### Portal

1. Continue the **Create SQL database** form from step 9, or start it and choose the newly created logical server.
2. **Basics > Compute + storage > Configure**:
   - Service tier: **Hyperscale**.
   - Hardware: **Standard-series (Gen5)**, provisioned **2 vCores**, if available/approved.
   - Review replica count and costs. Example backup storage redundancy: **Locally redundant**; choose the production-approved redundancy instead when required.
3. **Networking**: follow the narrow client-access settings from step 9.
4. **Security > Transparent data encryption key management > Database level key > Configure transparent data encryption**.
5. Select **Database level customer managed key (CMK)**.
6. Under **User-assigned managed identity > Configure**, enable **Database identity**, add the ISV UAMI from step 1, and apply.
7. In that **database identity** configuration, set **Federated client identity** to the ISV multitenant application's **client ID** from step 2. Search by app name/client ID if the UI offers a picker.
8. For the protector, choose **Enter a key identifier** / manual URI entry and paste the customer's **full versioned Managed HSM key URI**. Do not switch directories to browse the customer's subscription.
9. Leave **Auto-rotate key** unchecked for this initial version-pinned setup.
10. Apply and **Review + create**. Confirm that the key configuration is **database level**, then create.

Portal labels can vary by rollout. If the database creation blade only offers a same-tenant vault picker and no manual cross-tenant identifier entry, **do not add guest access as a workaround**. Use the supported CLI/PowerShell database-create alternative below. Do not accidentally configure the server-level protector.

### Bash

Paste handoff B's key URI. The managed identity resource ID and app client ID remain the ISV values from earlier steps.

```bash
assert_context "$ISV_TENANT_ID" "$ISV_SUBSCRIPTION_ID"
KEY_ID="<full-versioned-managedhsm-key-uri-from-handoff-B>"
if [[ ! "$KEY_ID" =~ ^https://[a-zA-Z0-9-]+\.managedhsm\.azure\.net(:443)?/keys/[^/]+/[^/?#]+$ ]]; then
  printf "Expected a full versioned public-Azure Managed HSM key URI.\n" >&2
  exit 1
fi

az sql db create --resource-group "$ISV_RG" --server "$SQL_SERVER" --name "$DATABASE" \
  --edition Hyperscale --family Gen5 --capacity 2 \
  --compute-model Provisioned --backup-storage-redundancy Local \
  --assign-identity true --user-assigned-identity-id "$UAMI_ID" \
  --federated-client-id "$APP_CLIENT_ID" --encryption-protector "$KEY_ID" \
  --encryption-protector-auto-rotation false --output none
```

### PowerShell

```powershell
Assert-AzureContext $IsvTenantId $IsvSubscriptionId
$KeyId = '<full-versioned-managedhsm-key-uri-from-handoff-B>'
if ($KeyId -notmatch '^https://[a-zA-Z0-9-]+\.managedhsm\.azure\.net(:443)?/keys/[^/]+/[^/?#]+$') {
    throw 'Expected a full versioned public-Azure Managed HSM key URI.'
}

$databaseParameters = @{
    ResourceGroupName = $IsvRg
    ServerName = $SqlServer
    DatabaseName = $Database
    Edition = 'Hyperscale'
    VCore = 2
    ComputeGeneration = 'Gen5'
    ComputeModel = 'Provisioned'
    BackupStorageRedundancy = 'Local'
    AssignIdentity = $true
    UserAssignedIdentityId = @($UamiId)
    FederatedClientId = $AppClientId
    EncryptionProtector = $KeyId
    EncryptionProtectorAutoRotation = $false
}
New-AzSqlDatabase @databaseParameters
```

**Checkpoint:** deployment reaches success. This is the first end-to-end check that Azure SQL can actually use the customer's HSM through federation. Reading a key as the customer administrator does **not** prove SQL's runtime access.

## 14. Step 11 - Verify the exact configuration, encryption, and tenant separation

### ISV portal checks

1. **SQL database > Overview**: status Online; tier Hyperscale.
2. **SQL database > Security > Transparent data encryption**:
   - TDE enabled.
   - Database-level CMK selected.
   - Expected versioned HSM protector URI.
   - Auto-rotation off.
3. Database identity settings show the expected UAMI and federated app.
4. **Logical server > Transparent data encryption**: protector **Service-managed**.
5. No guest or customer-directory role was needed for any of these checks.

### ISV Bash checks, including explicit assertions

The ARM read is intentional: it verifies the persisted database properties and identity together, rather than only testing whether TDE is enabled.

```bash
assert_context "$ISV_TENANT_ID" "$ISV_SUBSCRIPTION_ID"
DB_RESOURCE_ID="/subscriptions/$ISV_SUBSCRIPTION_ID/resourceGroups/$ISV_RG/providers/Microsoft.Sql/servers/$SQL_SERVER/databases/$DATABASE"
DB_URL="https://management.azure.com${DB_RESOURCE_ID}?api-version=2023-08-01"
az rest --method get --url "$DB_URL" \
  --query '{status:properties.status,tier:sku.tier,identity:identity,app:properties.federatedClientId,protector:properties.encryptionProtector,autoRotation:properties.encryptionProtectorAutoRotation}' -o json

ACTUAL_KEY="$(az rest --method get --url "$DB_URL" --query properties.encryptionProtector -o tsv)"
ACTUAL_APP="$(az rest --method get --url "$DB_URL" --query properties.federatedClientId -o tsv)"
ACTUAL_STATUS="$(az rest --method get --url "$DB_URL" --query properties.status -o tsv)"
ACTUAL_TIER="$(az rest --method get --url "$DB_URL" --query sku.tier -o tsv)"
ACTUAL_UAMI="$(az rest --method get --url "$DB_URL" --query 'keys(identity.userAssignedIdentities)[0]' -o tsv)"
ACTUAL_IDENTITY_COUNT="$(az rest --method get --url "$DB_URL" --query 'length(keys(identity.userAssignedIdentities))' -o tsv)"
ACTUAL_AUTO_ROTATION="$(az rest --method get --url "$DB_URL" --query properties.encryptionProtectorAutoRotation -o tsv)"
[[ "${ACTUAL_KEY/:443/}" == "${KEY_ID/:443/}" ]]
[[ "${ACTUAL_APP,,}" == "${APP_CLIENT_ID,,}" ]]
[[ "${ACTUAL_UAMI,,}" == "${UAMI_ID,,}" ]]
[[ "$ACTUAL_IDENTITY_COUNT" == "1" && "${ACTUAL_AUTO_ROTATION,,}" == "false" ]]
[[ "$ACTUAL_STATUS" == "Online" && "$ACTUAL_TIER" == "Hyperscale" ]]
[[ "$(az sql db tde show -g "$ISV_RG" -s "$SQL_SERVER" -d "$DATABASE" --query state -o tsv)" == "Enabled" ]]
[[ "$(az sql server tde-key show -g "$ISV_RG" -s "$SQL_SERVER" --query serverKeyType -o tsv)" == "ServiceManaged" ]]
printf "PASS: Online Hyperscale database uses the expected customer HSM key, app, and UAMI; TDE is enabled; server protector remains service-managed.\n"
```

If checks are pasted interactively, **stop on any failed assertion/error**; do not interpret a later printed line as proof. When saved as a script, include the initializer's `set -Eeuo pipefail` and error trap so failure terminates execution.

### ISV PowerShell checks

```powershell
Assert-AzureContext $IsvTenantId $IsvSubscriptionId
$DbResourceId = "/subscriptions/$IsvSubscriptionId/resourceGroups/$IsvRg/providers/Microsoft.Sql/servers/$SqlServer/databases/$Database"
$response = Invoke-AzRestMethod -Method GET -Path "${DbResourceId}?api-version=2023-08-01"
if ($response.StatusCode -ne 200) { throw "Database GET failed: $($response.Content)" }
$actual = $response.Content | ConvertFrom-Json
$actual | Select-Object identity, sku, properties | ConvertTo-Json -Depth 10
if (![uri]::Equals([uri]$actual.properties.encryptionProtector, [uri]$KeyId)) {
    throw 'Persisted database protector does not match the customer key URI.'
}
if ($actual.properties.federatedClientId -ne $AppClientId) { throw 'Federated client ID mismatch.' }
$assignedIdentityIds = @($actual.identity.userAssignedIdentities.PSObject.Properties.Name)
if ($assignedIdentityIds.Count -ne 1 -or $assignedIdentityIds[0] -ne $UamiId) {
    throw 'Database managed identity mismatch.'
}
if ($actual.properties.status -ne 'Online' -or $actual.sku.tier -ne 'Hyperscale') {
    throw 'Database is not an Online Hyperscale database.'
}
if ($actual.properties.encryptionProtectorAutoRotation -ne $false) {
    throw 'Expected version-pinned configuration with auto-rotation disabled.'
}
$tde = Get-AzSqlDatabaseTransparentDataEncryption -ResourceGroupName $IsvRg `
    -ServerName $SqlServer -DatabaseName $Database
if ($tde.State -ne 'Enabled') { throw 'TDE is not enabled.' }
$serverProtector = Get-AzSqlServerTransparentDataEncryptionProtector `
    -ResourceGroupName $IsvRg -ServerName $SqlServer
if ($serverProtector.Type -ne 'ServiceManaged') { throw 'Unexpected server-level protector.' }
'PASS: Online Hyperscale database uses the expected customer HSM key, app, and UAMI; TDE is enabled; server protector remains service-managed.'
```

### ISV SQL data-plane check

From the approved ISV SQL client, connect to `<server-name>.database.windows.net`, database `hs-customer-a`, using the configured **ISV Entra administrator** and Entra MFA authentication. No customer-directory login is involved.

Run in the user database:

```sql
SELECT DB_NAME(database_id) AS database_name,
       encryption_state,
       encryption_state_desc,
       encryptor_type,
       percent_complete
FROM sys.dm_database_encryption_keys
WHERE database_id = DB_ID();

SELECT DB_NAME() AS connected_database, SYSUTCDATETIME() AS checked_at_utc;
```

Expected stable TDE state: **`3` / `ENCRYPTED`**. A transitional encryption/key-change state requires waiting and rechecking. The DMV does not prove the exact external HSM URI; the ARM/database protector checks above do. Do not infer the specific CMK provider or key type solely from `encryptor_type`.

### Customer checks, performed independently in the customer tenant

1. Reopen HSM **Local RBAC**: expected service principal, service-encryption role, scope `/keys/sql-tde-customer-a`; no ISV human assignment.
2. **Keys > key > selected version**: Enabled, valid dates, correct key type/size and version.
3. Confirm purge protection and security-domain custody records.
4. **Monitoring > Diagnostic settings > Add diagnostic setting**: enable **AuditEvent** to a customer-owned Log Analytics workspace or approved destination. Complete destination provisioning/access locally if one does not exist.
5. After SQL provisioning/use, examine successful key-access/wrap/unwrap audit operations and the relevant application/object identifiers. SQL caches key material for service operation, so do not expect an HSM operation for every SQL query. Audit delivery can lag.
6. Confirm no new cross-tenant **user** invitation was made as part of this setup. Existing guest accounts unrelated to this setup are not automatically removed by this procedure.

**Acceptance:** both parties confirm their local checks, and ISV confirms SQL connectivity plus the persisted expected protector. Neither side needs permission to inspect the other side's directory.

## 15. Operations after initial setup

### Rotation: coordinate both sides

Auto-rotation is deliberately **disabled** above so initial validation checks an exact version.

1. Customer generates a new **version of the same key name**, verifies it, and sends the new full versioned URI to the ISV.
2. The key-name-scoped service-encryption role covers the new version. Preserve old versions and permissions.
3. ISV changes only this database's protector using the portal's database TDE page, or one of the following commands. In each case set `KEY_ID` / `$KeyId` to the new customer's full versioned URI first, then rerun the verification step.

```bash
assert_context "$ISV_TENANT_ID" "$ISV_SUBSCRIPTION_ID"
az sql db update -g "$ISV_RG" -s "$SQL_SERVER" -n "$DATABASE" \
  --encryption-protector "$KEY_ID" --encryption-protector-auto-rotation false --output none
```

```powershell
Assert-AzureContext $IsvTenantId $IsvSubscriptionId
Set-AzSqlDatabase -ResourceGroupName $IsvRg -ServerName $SqlServer -DatabaseName $Database `
    -EncryptionProtector $KeyId -EncryptionProtectorAutoRotation $false
```

If enabling automatic rotation later, coordinate HSM key-version creation/rotation policy **and** SQL's auto-rotation setting. Creating versions in HSM and enabling SQL to adopt them are different operations. Update validation to allow the expected current version instead of comparing permanently to the original URI.

### Recovery, revocation, and offboarding

- Preserve all historical TDE key versions needed by backups, point-in-time restore, long-term retention, replicas, and recovery tests. Do not disable/delete old versions simply because rotation succeeded.
- Keep customer HSM backups, security-domain material, and quorum keys under a tested customer recovery plan. The security domain alone is **not a backup of all application keys**.
- Before adding geo-replication, failover groups, or restores to another server, configure the destination database identity/federation/key access and required historical keys. This fresh single-database guide does not deploy DR partners.
- Revoking the app's key role, disabling the key, blocking networking, deleting federation, or deleting the enterprise app can make the database **Inaccessible**, potentially after a cache delay. This is a destructive availability action, not a routine smoke test.
- On loss of access, customer restores the key/permissions/network path; ISV restores identity/federation as necessary and uses the SQL database TDE **Revalidate key** operation. Coordinate evidence without exchanging administrator credentials.
- To revert to service-managed protection, the ISV can use the database TDE **Revert to server-level encryption** operation **only while the logical server uses a service-managed protector**. Obtain customer approval first and preserve key access while the operation completes.
- Do not delete the application, UAMI, customer enterprise app, HSM, or old keys until offboarding and all backup-retention/recovery obligations are explicitly resolved. No automated teardown commands are included.

## 16. Troubleshooting without guest access

| Symptom | Check / corrective action | Owner |
|---|---|---|
| Entra app creation or federation returns insufficient privileges | Check app ownership, native user's Entra role, tenant app-registration policy, and Graph client restrictions. Azure Contributor does not grant app-registration rights. Use approved local app administrator, not a guest invitation. | ISV |
| Customer service principal cannot be created | Confirm the ISV app is multitenant, client ID is correct, app replication has completed, and customer Entra policy/administrator permits provisioning. | Both, each locally |
| App already exists | Retrieve `az ad sp show --id <client-id>` / `Get-AzADServicePrincipal -ApplicationId ...`; verify home tenant and reuse the correct principal. | Customer |
| Admin consent reports no reply URL / redirect mismatch | Use the exact registered, encoded ISV-owned HTTPS redirect URI, or use direct customer-local service-principal provisioning instead. | ISV configures; customer retries |
| HSM provisioned but key/role operations unavailable | Activation/security-domain download must complete first, using an initial administrator. | Customer |
| HSM Administrator cannot generate keys | Assign **Managed HSM Crypto User** locally at `/keys`; wait for propagation. Do not substitute Key Vault Crypto Officer. | Customer |
| HSM key access denied | Verify **local** service-encryption role, customer-local SP object ID, and key-name scope. Azure IAM roles do not substitute for HSM-local roles. | Customer |
| Portal/Cloud Shell cannot list keys or download security domain | Its actual administration egress must be allowed. Trusted-services bypass does not automatically include the human's browser or Cloud Shell. | Customer |
| SQL cannot reach HSM | Verify selected-networks configuration, trusted-service bypass, key enabled/dates, and purge protection. An operator's successful key read proves only that operator's path. | Customer |
| SQL token/federation error | Issuer uses ISV tenant `/v2.0`; subject uses UAMI **principal ID**; audience is `api://AzureADTokenExchange`; database uses UAMI **resource ID** and app **client ID**. | ISV |
| Wrong role-assignment principal | Assign to customer enterprise app's object ID, not the ISV app object ID, UAMI object ID, or a human account. | Customer |
| HSM URI rejected | Use `https://<name>.managedhsm.azure.net/keys/<name>/<version>`; confirm a SQL-supported key type/size and a current client. | Customer supplies; ISV applies |
| SQL deployment authorization failure | Check ISV resource write permissions and managed identity assignment rights in the ISV subscription. No customer Azure permission is required for the ISV operator. | ISV |
| Portal requires browsing another tenant for the key | Use manual URI entry or CLI/PowerShell. Never add a guest to satisfy the resource picker. | ISV |
| TDE says Enabled, but expected CMK not shown | Enabled alone is insufficient. Verify the database's persisted `encryptionProtector`, `federatedClientId`, and identity, not only the server TDE page. | ISV |
| New role/federation is correct but first create fails | Allow propagation and rerun the failed SQL operation. Do not swallow the error, create duplicate apps, or broaden permissions to subscription scope. | Relevant party |
| Geo-DR/server identity errors | Confirm you did not switch the **server-level** protector or unintentionally target an existing DR topology. This guide creates a fresh database-level deployment. | ISV |

## 17. Final handover checklist

- [ ] ISV and customer operators used only native accounts in their own tenants.
- [ ] No user guest invitations, cross-tenant user roles, or shared administrator credentials.
- [ ] Dedicated ISV UAMI, multitenant app, and matching federated credential recorded.
- [ ] Customer-local service principal application ID and home tenant verified.
- [ ] Customer HSM activated; purge protection enabled; recovery custody tested/planned.
- [ ] HSM key is enabled AES-256 (`oct-HSM`) with valid dates and wrap/unwrap operations.
- [ ] Runtime principal has only the required key-level HSM-local service-encryption role.
- [ ] Restricted administration network plus Azure SQL trusted-service path verified.
- [ ] New database is Online, Hyperscale, TDE Enabled, with the expected versioned HSM URI.
- [ ] Database UAMI and federated client ID match; auto-rotation is initially disabled.
- [ ] Logical server protector remains service-managed.
- [ ] ISV SQL data-plane connectivity and encrypted DMV state verified.
- [ ] Customer audit logging, historical-key retention, rotation, DR, and offboarding ownership agreed.

## 18. Microsoft references

These links are external Microsoft documentation; review current service and regional limitations before production deployment.

1. [Cross-tenant customer-managed keys for Azure SQL Database](https://learn.microsoft.com/en-us/azure/azure-sql/database/transparent-data-encryption-byok-cross-tenant?view=azuresql).
2. [Database-level CMK overview, including Managed HSM and supported key types](https://learn.microsoft.com/en-us/azure/azure-sql/database/transparent-data-encryption-byok-database-level-overview?view=azuresql).
3. [Create and manage database-level identities and CMK using portal, CLI, and PowerShell](https://learn.microsoft.com/en-us/azure/azure-sql/database/transparent-data-encryption-byok-database-level-basic-actions?view=azuresql).
4. [TDE CMK requirements: key type, purge protection, and HSM access](https://learn.microsoft.com/en-us/azure/azure-sql/database/transparent-data-encryption-byok-overview?view=azuresql).
5. [Provision and activate Managed HSM through the portal](https://learn.microsoft.com/en-us/azure/key-vault/managed-hsm/quick-create-portal).
6. [Provision and activate Managed HSM through Azure CLI](https://learn.microsoft.com/en-us/azure/key-vault/managed-hsm/quick-create-cli).
7. [Provision and activate Managed HSM through PowerShell](https://learn.microsoft.com/en-us/azure/key-vault/managed-hsm/quick-create-powershell).
8. [Managed HSM local RBAC roles and permitted operations](https://learn.microsoft.com/en-us/azure/key-vault/managed-hsm/built-in-roles).
9. [Managed HSM networking and trusted-service considerations](https://learn.microsoft.com/en-us/azure/key-vault/managed-hsm/network-security).
10. [Configure Managed HSM networking](https://learn.microsoft.com/en-us/azure/key-vault/managed-hsm/configure-network-security).
11. [Managed HSM security-domain custody](https://learn.microsoft.com/en-us/azure/key-vault/managed-hsm/security-domain).
12. [Azure CLI SQL database command reference](https://learn.microsoft.com/en-us/cli/azure/sql/db?view=azure-cli-latest).
13. [PowerShell key-generation reference](https://learn.microsoft.com/en-us/powershell/module/az.keyvault/add-azkeyvaultkey).
14. [Microsoft identity platform admin-consent protocol](https://learn.microsoft.com/en-us/entra/identity-platform/v2-admin-consent).
