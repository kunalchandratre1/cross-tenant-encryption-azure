# Cross-tenant customer-managed key (CMK) TDE for Azure SQL (Hyperscale) – step-by-step guide

This guide sets up TDE with a customer-managed key for an Azure SQL database (including Hyperscale), using a key stored in a Key Vault in a **different** Microsoft Entra tenant. The main path applies the key at **database level**. Server-level is covered as an alternative.

Based on: [Cross-Tenant Customer-Managed Keys with TDE – Azure SQL Database](https://learn.microsoft.com/en-us/azure/azure-sql/database/transparent-data-encryption-byok-cross-tenant?view=azuresql)

Script: [Set-CrossTenantCmkTde.ps1](./Set-CrossTenantCmkTde.ps1)

Access and permissions summary: [Cross-Tenant-CMK-Access-Summary.md](./Cross-Tenant-CMK-Access-Summary.md)

---

## 1. Environment

Replace the placeholders with your own values.

| Item | ISV / service-provider tenant (SQL side) | Customer tenant (key side) |
|---|---|---|
| Tenant ID | `<tenant id of ISV>` | `<tenant id of customer>` |
| Subscription ID | `<subscription id of ISV>` | `<subscription id of customer>` |
| Resources | SQL server `<SQL server name>` (RG `<SQL resource group>`)<br>Database `<database name>`<br>User-assigned managed identity `<managed identity name>`<br>Multitenant app `<multitenant app name>` | Key Vault `<Key Vault name>` (RG `<Key Vault resource group>`)<br>RSA key `<key name>` |
| Key IDs | App (client) ID: `<client id of multitenant app>` | Key identifier: `https://<Key Vault name>.vault.azure.net/keys/<key name>/<key version>` |

### How it works

1. In the ISV tenant, the SQL database uses the **managed identity** to get a token for the **multitenant app**. This works through a federated identity credential on the app.
2. The app has a **service principal** (enterprise application) in the customer tenant. That service principal holds a Key Vault role on the customer's vault.
3. The database can therefore wrap and unwrap its encryption key with the customer's key, without either tenant sharing secrets.

---

## 2. Summary – who does what, where

| # | Step | Tenant | Method |
|---|---|---|---|
| 0 | Prerequisites (modules, roles) | Both | PowerShell / Portal |
| 1 | Create the user-assigned managed identity | ISV | Portal (or script `-Phase IsvPrepare`) |
| 2 | Create the multitenant app registration | ISV | **Portal** (or script) |
| 3 | Add a redirect URI to the app | ISV | **Portal** |
| 4 | Add a federated credential (managed identity → app) | ISV | **Portal** (or script) |
| 5 | Install the app (create the service principal) | Customer | **Cloud Shell `az` / admin-consent URL** (or script `-Phase CustomerSetup`) |
| 6 | Create the Key Vault (soft delete **and purge protection**) | Customer | **Portal** (or script) |
| 7 | Grant the app *Key Vault Crypto Service Encryption User* | Customer | **Portal** (or script) |
| 8 | Create an RSA key and copy the key identifier | Customer | **Portal** (or script) |
| 9 | Grant your account Contributor on the SQL resource group | ISV | **Portal** |
| 10 | Configure database-level CMK | ISV | **Script** |
| 11 | Verify | ISV | PowerShell / T-SQL |

> **Why portal for Entra ID steps?** If the signed-in account is a **guest** in a tenant, or the tenant restricts Microsoft Graph access, Az PowerShell calls to Graph (`Get-AzADApplication`, `New-AzADApplication`, `New-AzADAppFederatedCredential`) can fail with `Insufficient privileges`, even when the account owns the app. The portal steps still work. Steps that only touch Azure resources (SQL, managed identity) work from the script. If your accounts have full Graph access, you can run `-Phase IsvPrepare` and `-Phase CustomerSetup` instead.

---

## 3. Step 0 – Prerequisites

### On the machine running the script

```powershell
# Register PSGallery if missing (fixes: "Unable to find repository 'PSGallery'")
Register-PSRepository -Default
Install-Module Az -Scope CurrentUser -Repository PSGallery -Force
```

The script also installs any missing `Az.Accounts`, `Az.Resources` (≥ 6.3.0), `Az.ManagedServiceIdentity`, `Az.KeyVault` and `Az.Sql` on its first run.

### Permissions needed

| Tenant | Who | Needs |
|---|---|---|
| ISV | Person who configures the SQL side | **Contributor** on the SQL resource group. This covers `Microsoft.Sql/servers/write`, database write, and assigning the managed identity.<br>**Owner** of the app registration, or the Entra role *Application Developer* / *Cloud Application Administrator*. |
| Customer | Customer admin | A directory role that can create service principals (*Cloud Application Administrator*, *Application Administrator* or *Global Administrator*).<br>**Owner** or **User Access Administrator** on the Key Vault, to assign roles.<br>**Key Vault Crypto Officer** on the vault, to create keys. |

> The *Application Developer* role is an **Entra ID directory role** (Entra ID → Roles and administrators). It is **not** an Azure subscription role.

See [Cross-Tenant-CMK-Access-Summary.md](./Cross-Tenant-CMK-Access-Summary.md) for the full breakdown.

---

## 4. ISV tenant – portal steps

Sign in to the portal in the **ISV tenant**.

### Step 1 – User-assigned managed identity (portal)

1. Go to **Managed Identities** → **+ Create**.
2. Choose the ISV subscription, the SQL resource group, the same region as the SQL server, and name `<managed identity name>`.
3. After it is created, open it → **Overview** and note the **Object (principal) ID**. Step 4 needs it.

Alternatively, run the script's `IsvPrepare` phase. It creates the managed identity and attempts the app and federated credential steps.

### Step 2 – Multitenant app registration (portal)

1. Go to **Microsoft Entra ID** → **App registrations** → **+ New registration**.
2. Name: `<multitenant app name>`.
3. Supported account types: **Accounts in any organizational directory (Any Microsoft Entra ID tenant – Multitenant)**.
4. Register, then note the **Application (client) ID** and the **Object ID**.
5. Under **Owners**, confirm that the account running the next steps is listed.

### Step 3 – Redirect URI (portal)

This is needed only if the customer installs the app through the admin-consent URL. Without it, you get `AADSTS500113: No reply address is registered for the application`.

1. Go to the app → **Authentication** → **Add a platform** → **Web**.
2. Redirect URI: `https://portal.azure.com` → **Configure**.

### Step 4 – Federated credential (portal)

1. Go to the app → **Certificates & secrets** → **Federated credentials** → **+ Add credential**.
2. Scenario: **Managed identity**. Select `<managed identity name>`. To enter the values manually instead, choose *Other issuer*:

| Field | Value |
|---|---|
| Issuer | `https://login.microsoftonline.com/<tenant id of ISV>/v2.0` |
| Subject | **Object (principal) ID** of `<managed identity name>`. This is *not* its client ID or resource ID. |
| Audience | `api://AzureADTokenExchange` |
| Name | `<federated credential name>` |

3. Click **Add**.

Share the **Application (client) ID** with the customer.

---

## 5. Customer tenant – portal / Cloud Shell steps

Sign in to the portal in the **customer tenant**.

### Step 5 – Install the ISV app (create the service principal)

"Installing" the app means creating a **service principal** (enterprise application) in the customer tenant for the ISV's application (client) ID. Use either option.

**Option A – Cloud Shell (Bash or PowerShell) in the customer tenant**

```bash
az ad sp create --id "<client id of multitenant app>"
```

- Use the ISV app's **Application (client) ID**. Do not use its Object ID.
- If you see `…service principal name … is already in use`, the service principal **already exists**, which is the result you need. Get its object ID with:

```bash
az ad sp show --id "<client id of multitenant app>" --query "{objectId:id, name:displayName}" -o table
```

**Option B – Admin-consent URL.** This requires step 3. A customer Global Administrator or Cloud Application Administrator opens:

```
https://login.microsoftonline.com/<tenant id of customer>/adminconsent?client_id=<client id of multitenant app>&redirect_uri=https://portal.azure.com
```

Then check **Entra ID → Enterprise applications** for `<multitenant app name>`. Remove the "Application type" filter if it doesn't appear. Note its **Object ID**. It differs from the ISV app's object ID.

### Step 6 – Key Vault (portal)

1. Create the vault `<Key Vault name>` in RG `<Key Vault resource group>`, or use an existing one.
2. **Properties** → make sure **Soft delete** is on **and Purge protection is enabled**.

> Without purge protection, the key step fails with `SecurityInvalidAzureKeyVaultRecoveryLevel … RecoveryLevel: Recoverable+Purgeable`.
> Purge protection **cannot be disabled** once enabled.

```powershell
# PowerShell alternative (customer tenant)
Update-AzKeyVault -VaultName "<Key Vault name>" -ResourceGroupName "<Key Vault resource group>" -EnablePurgeProtection
```

3. **Networking**: if the firewall is on, enable **Allow trusted Microsoft services to bypass this firewall**, or use a private endpoint.

### Step 7 – Grant the ISV app access to the vault (portal)

1. Go to the vault → **Access control (IAM)** → **+ Add role assignment**.
2. Role: **Key Vault Crypto Service Encryption User**.
3. Members: **User, group, or service principal** → select `<multitenant app name>`, the enterprise app from step 5.
4. **Review + assign**.

If the vault uses the *access policy* model instead of RBAC, add an access policy for the service principal with the key permissions **Get, Wrap Key, Unwrap Key**.

### Step 8 – Create the key and copy its identifier (portal)

1. Go to the vault → **Keys** → **+ Generate/Import**. Create an **RSA** key of 2048 or 3072 bits.
2. Open the key → open the **current version** → copy the **Key Identifier**:

```
https://<Key Vault name>.vault.azure.net/keys/<key name>/<key version>
```

> Use the **full versioned URL**. Passing only the version is invalid.

Share the key identifier with the ISV.

---

## 6. ISV tenant – Azure permissions (portal)

### Step 9 – Contributor on the SQL resource group

Without it, the script fails with:
`AuthorizationFailed … does not have authorization to perform action 'Microsoft.Sql/servers/write'`.

1. Go to the SQL resource group → **Access control (IAM)** → **+ Add role assignment** → **Contributor**.
2. Select the account that will run the script.

> For a **guest** account, confirm that the assignment targets the object ID shown in the error message. A guest has a different object ID in each tenant.

3. Sign out of and back into PowerShell so the new token includes the role:

```powershell
Disconnect-AzAccount; Clear-AzContext -Force
```

---

## 7. ISV tenant – run the script

### Step 10 – Configure database-level CMK

```powershell
.\Set-CrossTenantCmkTde.ps1 -Phase IsvConfigure -DatabaseLevel `
  -IsvTenantId "<tenant id of ISV>" -IsvSubscriptionId "<subscription id of ISV>" `
  -SqlServerName "<SQL server name>" -SqlResourceGroup "<SQL resource group>" `
  -UamiName "<managed identity name>" -DatabaseName "<database name>" `
  -AppId "<client id of multitenant app>" `
  -KeyId "https://<Key Vault name>.vault.azure.net/keys/<key name>/<key version>"
```

The script does the following, using direct Azure Resource Manager calls so that errors show the full code and message:

1. Signs in to the ISV tenant and subscription. This prompts an interactive login if needed.
2. Checks that `-KeyId` is a full, versioned key URL.
3. Looks up the managed identity.
4. `PATCH`es the database with:
   - `identity` = the user-assigned managed identity
   - `federatedClientId` = the multitenant app's client ID
   - `encryptionProtector` = the customer key URL
5. Reads the database back and checks that the encryption protector equals the customer key.

The **server-level** TDE protector stays `ServiceManaged`. Other databases on the server, and any geo-replication partner, are **not** affected.

### Why database-level and not server-level?

If the server has a geo-replication / failover-group partner, a **server-level** protector change applies to every database on the server, so Azure requires the partner server to reach the key first. Otherwise it fails with:

```
ManagementServiceMissingServerIdentityForGeoDr – The server identity is not configured on the partner server '<partner server name>'
```

Database-level CMK limits the change to the target database.

<details>
<summary>Alternative: server-level CMK (all databases + partner server)</summary>

```powershell
.\Set-CrossTenantCmkTde.ps1 -Phase IsvConfigure `
  -IsvTenantId "<tenant id of ISV>" -IsvSubscriptionId "<subscription id of ISV>" `
  -SqlServerName "<SQL server name>" -SqlResourceGroup "<SQL resource group>" `
  -UamiName "<managed identity name>" -DatabaseName "<database name>" `
  -AppId "<client id of multitenant app>" `
  -KeyId "https://<Key Vault name>.vault.azure.net/keys/<key name>/<key version>" `
  -PartnerServerName "<partner server name>" -PartnerResourceGroup "<partner resource group>"
```

The script configures the partner server first (identity and key), then the primary server, and finally sets the server TDE protector. You need Contributor on the partner server as well. Omit the `-Partner*` parameters if the server has no geo-replication partner.
</details>

---

## 8. Verify

### Step 11 – Confirm the customer key is used

**PowerShell (ISV tenant)**

```powershell
# Database-level protector – should return the customer key URL
(Get-AzSqlDatabase -ResourceGroupName "<SQL resource group>" -ServerName "<SQL server name>" `
   -DatabaseName "<database name>" -ExpandKeyList).EncryptionProtector

# TDE state – should be Enabled
Get-AzSqlDatabaseTransparentDataEncryption -ResourceGroupName "<SQL resource group>" `
   -ServerName "<SQL server name>" -DatabaseName "<database name>"

# Server-level protector – stays ServiceManaged with database-level CMK (expected)
Get-AzSqlServerTransparentDataEncryptionProtector -ResourceGroupName "<SQL resource group>" -ServerName "<SQL server name>" |
   Format-List Type, KeyId
```

> `Get-AzSqlDatabaseTransparentDataEncryption` only shows **Enabled/Disabled**. It does **not** show which key is used.

**T-SQL (connected to the target database)**

```sql
SELECT DB_NAME(database_id) AS db,
       encryption_state_desc,   -- ENCRYPTED
       encryptor_type,          -- ASYMMETRIC KEY = customer-managed key; CERTIFICATE = service-managed
       percent_complete
FROM sys.dm_database_encryption_keys
WHERE database_id = DB_ID();
```

**Portal**: open the database → **Security → Transparent data encryption**. It should show the customer-managed key.

---

## 9. Troubleshooting – common errors

| Error | Cause | Fix |
|---|---|---|
| `Unable to find repository 'PSGallery'` | PSGallery not registered | `Register-PSRepository -Default` (the script does this) |
| `Insufficient privileges to complete the operation` (`Get-/New-AzADApplication`) | Guest account, or Az PowerShell client blocked from Microsoft Graph | Do steps 2–4 in the **portal**; pass `-AppId`/`-AppObjectId`, `-SkipFederatedCredential`, `-CustomerSpObjectId` |
| `AADSTS500113: No reply address is registered` | Admin-consent URL used on an app with no redirect URI | Step 3, or use `az ad sp create` (step 5A) |
| `service principal name … is already in use` | Service principal already exists in that tenant | Nothing to fix – get its object ID with `az ad sp show` |
| `Forbidden` / `AuthorizationFailed … Microsoft.Sql/servers/write` | Account lacks write access on the SQL server | Step 9: Contributor on the SQL resource group, then sign in again |
| `KeyId must be the full, versioned key identifier URL` | Only the key version was passed | Use `https://<Key Vault name>.vault.azure.net/keys/<key name>/<key version>` |
| `SecurityInvalidAzureKeyVaultRecoveryLevel … Recoverable+Purgeable` | Purge protection disabled on the vault | Step 6: enable purge protection |
| `ManagementServiceMissingServerIdentityForGeoDr` | Server-level change on a server with a geo-DR partner | Use `-DatabaseLevel`, or `-PartnerServerName` for server-level |
| Key access / token / `AzureKeyVaultKeyAccessDenied` | Federated credential, vault role or firewall misconfigured | Recheck steps 4, 7 and 6 (networking) |

---

## 10. Script reference

| Parameter | Purpose |
|---|---|
| `-Phase` | `IsvPrepare`, `CustomerSetup`, `IsvConfigure` or `All` |
| `-DatabaseLevel` | Apply CMK only to `-DatabaseName`. The server protector is untouched. |
| `-DatabaseName` | Target or validated database |
| `-UamiName` | Managed identity name |
| `-AppId` / `-AppObjectId` | Multitenant app client ID / object ID. Supplying both skips the Graph lookups. |
| `-SkipFederatedCredential` | Use when the federated credential was created in the portal |
| `-CustomerSpObjectId` | Object ID of the customer-tenant enterprise app. Skips the Graph lookups. |
| `-KeyId` | Full, versioned key identifier URL |
| `-PartnerServerName` / `-PartnerResourceGroup` / `-PartnerSubscriptionId` | Geo-DR partner, for server-level CMK |
| `-StateFile` | Passes values between phases (default `cross-tenant-cmk.state.json`, git-ignored) |
