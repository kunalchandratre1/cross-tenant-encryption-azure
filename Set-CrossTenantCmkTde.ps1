<#
.SYNOPSIS
    Configures cross-tenant customer-managed key (CMK) TDE for an Azure SQL logical server
    (works for Hyperscale databases) using a multitenant app + user-assigned managed identity
    federated credential.

.DESCRIPTION
    Phase 1 - IsvPrepare     (ISV / service-provider tenant)
        * Create user-assigned managed identity (UAMI)
        * Create multitenant Entra app registration
        * Add federated identity credential on the app trusting the UAMI
    Phase 2 - CustomerSetup  (customer tenant)
        * Create the enterprise app (service principal) for the ISV app
        * Create/use Key Vault (soft delete + purge protection) and an RSA key
        * Grant the service principal key permissions
        * Output the Key Identifier
    Phase 3 - IsvConfigure   (ISV / service-provider tenant)
        * Assign UAMI as Primary identity + Federated client identity on the SQL server
        * Register the customer's key on the server and set it as TDE protector
        * Validate

    Hand-off values between phases are stored in a JSON state file, so phases can be run
    separately (e.g. by different people) or all at once with -Phase All.

.EXAMPLE
    .\Set-CrossTenantCmkTde.ps1 -Phase All `
        -IsvTenantId <guid> -IsvSubscriptionId <guid> `
        -SqlServerName mysqlsrv -SqlResourceGroup rg-sql `
        -CustomerTenantId <guid> -CustomerSubscriptionId <guid> `
        -KeyVaultName kv-customer-cmk -KeyVaultResourceGroup rg-kv

.NOTES
    Required permissions
      ISV tenant      : create apps (Application Developer), create UAMI, Contributor on SQL server RG
      Customer tenant : create service principals (Application Administrator or similar),
                        Owner / User Access Administrator on the vault scope, rights to create the vault
#>
[CmdletBinding()]
param(
    [ValidateSet('All', 'IsvPrepare', 'CustomerSetup', 'IsvConfigure')]
    [string]$Phase = 'All',

    # ---- ISV (service provider) tenant: owns the SQL server ----
    [string]$IsvTenantId,
    [string]$IsvSubscriptionId,
    [string]$SqlServerName,
    [string]$SqlResourceGroup,
    [string]$UamiName = 'sql-cross-tenant-cmk-mi',
    [string]$UamiResourceGroup,                       # defaults to SqlResourceGroup
    [string]$AppDisplayName = 'sql-cross-tenant-cmk-app',
    [string]$FederatedCredentialName = 'sql-cross-tenant-cmk-federation',
    [string]$DatabaseName,                            # optional: validate a specific (e.g. Hyperscale) database
    [switch]$DatabaseLevel,                           # apply CMK only to -DatabaseName (server protector untouched)
    [string]$PartnerServerName,                       # optional: geo-replication / failover-group partner server
    [string]$PartnerResourceGroup,                    # defaults to SqlResourceGroup
    [string]$PartnerSubscriptionId,                   # defaults to IsvSubscriptionId

    # ---- Customer tenant: owns the Key Vault / key ----
    [string]$CustomerTenantId,
    [string]$CustomerSubscriptionId,
    [string]$KeyVaultName,
    [string]$KeyVaultResourceGroup,
    [string]$KeyName = 'sql-tde-protector',
    [ValidateSet(2048, 3072)]
    [int]$KeySize = 3072,
    [string]$KeyVaultLocation,                        # defaults to SQL server location (new vault only)

    # ---- Hand-off ----
    [string]$StateFile = (Join-Path $PSScriptRoot 'cross-tenant-cmk.state.json'),
    [string]$AppId,                                   # multitenant app (client) id; skips app lookup/creation
    [string]$AppObjectId,                             # app registration OBJECT id (needed with -AppId to skip Graph lookups)
    [switch]$SkipFederatedCredential,                 # federated credential was created manually in the portal
    [string]$CustomerSpObjectId,                      # OBJECT id of the enterprise app (service principal) in the customer tenant; skips Graph lookups
    [string]$KeyId                                    # override state: customer key identifier URL
)

$ErrorActionPreference = 'Stop'

# Accept a server FQDN (e.g. myserver.database.windows.net) but use the short name.
if ($SqlServerName) { $SqlServerName = $SqlServerName.Split('.')[0] }

# ------------------------------------------------------------------ helpers
function Write-Step($msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }
function Write-Info($msg) { Write-Host "  $msg" -ForegroundColor Gray }

function Assert-Param([hashtable]$Required) {
    $missing = $Required.GetEnumerator() | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.Value) } | ForEach-Object Key
    if ($missing) { throw "Missing required parameter(s) for this phase: $($missing -join ', ')" }
}

function Install-RequiredModules {
    $modules = @(
        @{ Name = 'Az.Accounts' },
        @{ Name = 'Az.Resources'; Min = '6.3.0' },        # New-AzADAppFederatedCredential
        @{ Name = 'Az.ManagedServiceIdentity' },
        @{ Name = 'Az.KeyVault' },
        @{ Name = 'Az.Sql' }
    )
    if (-not (Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue)) {
        Write-Info 'PSGallery is not registered; registering it...'
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        try { Register-PSRepository -Default -ErrorAction Stop }
        catch { Register-PSResourceRepository -PSGallery -Trusted -ErrorAction Stop }
    }
    foreach ($m in $modules) {
        $found = Get-Module -ListAvailable -Name $m.Name | Sort-Object Version -Descending | Select-Object -First 1
        if (-not $found -or ($m.Min -and $found.Version -lt [version]$m.Min)) {
            Write-Info "Installing module $($m.Name)..."
            Install-Module -Name $m.Name -Scope CurrentUser -Force -AllowClobber -Repository PSGallery
        }
        Import-Module $m.Name -ErrorAction Stop
    }
}

function Connect-Tenant([string]$TenantId, [string]$SubscriptionId, [string]$Label) {
    Write-Step "Connecting to $Label (tenant $TenantId, subscription $SubscriptionId)"
    $ctx = Get-AzContext
    if (-not $ctx -or $ctx.Tenant.Id -ne $TenantId -or $ctx.Subscription.Id -ne $SubscriptionId) {
        Connect-AzAccount -Tenant $TenantId -Subscription $SubscriptionId -ErrorAction Stop | Out-Null
    }
    Set-AzContext -Tenant $TenantId -Subscription $SubscriptionId -ErrorAction Stop | Out-Null
    $ctx = Get-AzContext
    Write-Info "Signed in as $($ctx.Account.Id) | tenant $($ctx.Tenant.Id) | subscription $($ctx.Subscription.Name)"
}

function Read-State {
    if (Test-Path $StateFile) { return Get-Content $StateFile -Raw | ConvertFrom-Json -AsHashtable }
    return @{}
}

function Save-State([hashtable]$Values) {
    $state = Read-State
    foreach ($k in $Values.Keys) { $state[$k] = $Values[$k] }
    $state | ConvertTo-Json | Set-Content -Path $StateFile -Encoding UTF8
    Write-Info "State saved to $StateFile"
}

function Invoke-WithRetry([scriptblock]$Action, [int]$Attempts = 12, [int]$DelaySeconds = 10, [string]$What = 'operation') {
    for ($i = 1; $i -le $Attempts; $i++) {
        try { return & $Action }
        catch {
            if ($i -eq $Attempts) { throw }
            Write-Info "$What not ready yet ($($_.Exception.Message.Split("`n")[0])). Retry $i/$Attempts in ${DelaySeconds}s..."
            Start-Sleep -Seconds $DelaySeconds
        }
    }
}

# ------------------------------------------------------------------ phase 1
function Invoke-IsvPrepare {
    Assert-Param @{ IsvTenantId = $IsvTenantId; IsvSubscriptionId = $IsvSubscriptionId
                    SqlServerName = $SqlServerName; SqlResourceGroup = $SqlResourceGroup }
    Connect-Tenant $IsvTenantId $IsvSubscriptionId 'ISV tenant'

    $rg = if ($UamiResourceGroup) { $UamiResourceGroup } else { $SqlResourceGroup }
    $server = Get-AzSqlServer -ResourceGroupName $SqlResourceGroup -ServerName $SqlServerName
    Write-Info "SQL server $SqlServerName found in $($server.Location)"

    Write-Step 'ISV 1/3: user-assigned managed identity'
    $uami = Get-AzUserAssignedIdentity -ResourceGroupName $rg -Name $UamiName -ErrorAction SilentlyContinue
    if (-not $uami) {
        $uami = New-AzUserAssignedIdentity -ResourceGroupName $rg -Name $UamiName -Location $server.Location
        Write-Info "Created UAMI $UamiName"
    } else { Write-Info "Using existing UAMI $UamiName" }
    Write-Info "UAMI principal (object) id: $($uami.PrincipalId)"

    Write-Step 'ISV 2/3: multitenant application'
    $permHint = "Your account cannot create/manage app registrations in the ISV tenant. Ask a tenant admin to grant you the 'Application Developer' role, or have an admin pre-create a multitenant app (Supported account types: any organizational directory), make you its Owner, and re-run with -AppId <client id>."
    try {
        if ($AppId -and $AppObjectId) {
            $app = [pscustomobject]@{ Id = $AppObjectId; AppId = $AppId; DisplayName = $AppDisplayName }
            Write-Info "Using supplied application (client id $AppId, object id $AppObjectId); skipping directory lookup"
        } else {
            $app = if ($AppId) { Get-AzADApplication -ApplicationId $AppId -ErrorAction Stop }
                   else { Get-AzADApplication -DisplayName $AppDisplayName -ErrorAction Stop | Select-Object -First 1 }
        }
        if (-not $app) {
            if ($AppId) { throw "Application with client id $AppId was not found in the ISV tenant." }
            $app = New-AzADApplication -DisplayName $AppDisplayName -SignInAudience AzureADMultipleOrgs -ErrorAction Stop
            Write-Info "Created application $AppDisplayName"
        } elseif ($app.PSObject.Properties['SignInAudience'] -and $app.SignInAudience -ne 'AzureADMultipleOrgs') {
            Update-AzADApplication -ObjectId $app.Id -SignInAudience AzureADMultipleOrgs -ErrorAction Stop
        }
    } catch {
        throw "$($_.Exception.Message)`n$permHint"
    }
    if (-not $app -or -not $app.AppId) { throw "Application was not created/found.`n$permHint" }
    Write-Info "Application (client) id: $($app.AppId)"

    Write-Step 'ISV 3/3: federated credential (UAMI -> application)'
    $existing = $null
    if ($SkipFederatedCredential) {
        Write-Info 'Skipped (-SkipFederatedCredential). Make sure this federated credential exists on the app (portal: App registration > Certificates & secrets > Federated credentials > Managed Identity):'
        Write-Info "  Issuer   : https://login.microsoftonline.com/$IsvTenantId/v2.0"
        Write-Info "  Subject  : $($uami.PrincipalId)   (managed identity '$UamiName' principal id)"
        Write-Info '  Audience : api://AzureADTokenExchange'
    } else {
    try {
        $existing = Get-AzADAppFederatedCredential -ApplicationObjectId $app.Id -ErrorAction Stop |
            Where-Object { $_.Name -eq $FederatedCredentialName }
    } catch { Write-Info "Could not list existing federated credentials ($($_.Exception.Message.Split("`n")[0])); will try to create." }
    if (-not $existing) {
        try {
            New-AzADAppFederatedCredential -ApplicationObjectId $app.Id -ErrorAction Stop `
            -Audience 'api://AzureADTokenExchange' `
            -Issuer "https://login.microsoftonline.com/$IsvTenantId/v2.0" `
            -Name $FederatedCredentialName `
            -Subject $uami.PrincipalId | Out-Null
            Write-Info "Created federated credential $FederatedCredentialName"
        } catch {
            if ($_.Exception.Message -match 'already exists|conflict|FederatedIdentityCredential_DuplicateSubject|same Subject') {
                Write-Info 'Federated credential already exists (create returned a duplicate error)'
            } else { throw }
        }
    } elseif ($existing.Subject -ne $uami.PrincipalId) {
        throw "Federated credential '$FederatedCredentialName' exists with a different subject ($($existing.Subject)). Remove or rename it."
    } else { Write-Info 'Federated credential already exists' }
    }

    Save-State @{
        IsvTenantId  = $IsvTenantId
        AppId        = $app.AppId
        UamiId       = $uami.Id
        UamiPrincipalId = $uami.PrincipalId
        SqlServerLocation = $server.Location
    }
    Write-Host "`nShare this Application (client) ID with the customer: $($app.AppId)" -ForegroundColor Green
}

# ------------------------------------------------------------------ phase 2
function Invoke-CustomerSetup {
    $state = Read-State
    if (-not $AppId) { $script:AppId = $state['AppId'] }
    Assert-Param @{ CustomerTenantId = $CustomerTenantId; CustomerSubscriptionId = $CustomerSubscriptionId
                    KeyVaultName = $KeyVaultName; KeyVaultResourceGroup = $KeyVaultResourceGroup; AppId = $script:AppId }
    Connect-Tenant $CustomerTenantId $CustomerSubscriptionId 'customer tenant'

    Write-Step 'Customer 1/4: install ISV multitenant application (service principal)'
    if ($CustomerSpObjectId) {
        $sp = [pscustomobject]@{ Id = $CustomerSpObjectId }
        Write-Info "Using supplied service principal object id: $CustomerSpObjectId (skipping directory lookup)"
    } else {
    $sp = Get-AzADServicePrincipal -ApplicationId $script:AppId -ErrorAction SilentlyContinue
    if (-not $sp) {
        try { $sp = New-AzADServicePrincipal -ApplicationId $script:AppId -ErrorAction Stop }
        catch {
            $url = "https://login.microsoftonline.com/$CustomerTenantId/adminconsent?client_id=$($script:AppId)"
            Write-Warning "Could not create the service principal: $($_.Exception.Message)"
            Write-Warning "Have a tenant admin open this admin-consent URL (or install the app via Enterprise applications), then re-run with -CustomerSpObjectId <enterprise app object id>:`n  $url"
            throw
        }
    }
    $sp = Invoke-WithRetry { $r = Get-AzADServicePrincipal -ApplicationId $script:AppId; if (-not $r) { throw 'SP not visible yet' }; $r } -What 'Service principal'
    }
    Write-Info "Service principal object id (customer tenant): $($sp.Id)"

    Write-Step 'Customer 2/4: Key Vault (soft delete + purge protection required)'
    $location = $KeyVaultLocation
    if (-not $location) {
        $state = Read-State
        $location = $state['SqlServerLocation']
    }
    $vault = Get-AzKeyVault -VaultName $KeyVaultName -ResourceGroupName $KeyVaultResourceGroup -ErrorAction SilentlyContinue
    if (-not $vault) {
        if (-not $location) { throw 'KeyVaultLocation is required to create a new vault.' }
        if (-not (Get-AzResourceGroup -Name $KeyVaultResourceGroup -ErrorAction SilentlyContinue)) {
            New-AzResourceGroup -Name $KeyVaultResourceGroup -Location $location | Out-Null
        }
        $vault = New-AzKeyVault -Name $KeyVaultName -ResourceGroupName $KeyVaultResourceGroup -Location $location `
            -EnableRbacAuthorization -EnablePurgeProtection
        Write-Info "Created vault $KeyVaultName"
    } else { Write-Info "Using existing vault $KeyVaultName" }
    if (-not $vault.EnablePurgeProtection) {
        Write-Info 'Enabling purge protection (irreversible)...'
        Update-AzKeyVault -ResourceGroupName $KeyVaultResourceGroup -VaultName $KeyVaultName -EnablePurgeProtection | Out-Null
        $vault = Get-AzKeyVault -VaultName $KeyVaultName -ResourceGroupName $KeyVaultResourceGroup
    }
    $useRbac = [bool]$vault.EnableRbacAuthorization

    Write-Step 'Customer 3/4: permissions + key'
    if ($useRbac) {
        # Current user needs a data-plane role to create the key.
        $me = $null
        try { $me = Get-AzADUser -SignedIn -ErrorAction Stop } catch { }
        if (-not $me) { try { $me = Get-AzADUser -UserPrincipalName (Get-AzContext).Account.Id -ErrorAction Stop } catch { } }
        if (-not $me) { Write-Warning 'Could not resolve the signed-in user in Entra; ensure you already hold Key Vault Crypto Officer on the vault to create the key.' }
        if ($me) {
            if (-not (Get-AzRoleAssignment -ObjectId $me.Id -RoleDefinitionName 'Key Vault Crypto Officer' -Scope $vault.ResourceId -ErrorAction SilentlyContinue)) {
                New-AzRoleAssignment -ObjectId $me.Id -RoleDefinitionName 'Key Vault Crypto Officer' -Scope $vault.ResourceId | Out-Null
                Write-Info 'Granted Key Vault Crypto Officer to the signed-in user'
            }
        }
        if (-not (Get-AzRoleAssignment -ObjectId $sp.Id -RoleDefinitionName 'Key Vault Crypto Service Encryption User' -Scope $vault.ResourceId -ErrorAction SilentlyContinue)) {
            Invoke-WithRetry {
                New-AzRoleAssignment -ObjectId $sp.Id -ObjectType ServicePrincipal -RoleDefinitionName 'Key Vault Crypto Service Encryption User' `
                    -Scope $vault.ResourceId | Out-Null
            } -What 'Role assignment'
            Write-Info 'Granted Key Vault Crypto Service Encryption User to the ISV application'
        } else { Write-Info 'ISV application already has Key Vault Crypto Service Encryption User' }
    } else {
        Set-AzKeyVaultAccessPolicy -VaultName $KeyVaultName -ResourceGroupName $KeyVaultResourceGroup `
            -ObjectId $sp.Id -PermissionsToKeys get, wrapKey, unwrapKey
        Write-Info 'Set access policy (get, wrapKey, unwrapKey) for the ISV application'
    }

    $key = Invoke-WithRetry { Get-AzKeyVaultKey -VaultName $KeyVaultName -Name $KeyName -ErrorAction SilentlyContinue } -Attempts 1 -What 'Get key'
    if (-not $key) {
        $key = Invoke-WithRetry {
            Add-AzKeyVaultKey -VaultName $KeyVaultName -Name $KeyName -Destination Software -Size $KeySize `
                -KeyOps wrapKey, unwrapKey, encrypt, decrypt, sign, verify
        } -What 'Key creation (RBAC propagation)'
        Write-Info "Created RSA-$KeySize key $KeyName"
    } else { Write-Info "Using existing key $KeyName" }

    Write-Step 'Customer 4/4: key identifier'
    $keyIdentifier = $key.Id
    Write-Host "Key Identifier: $keyIdentifier" -ForegroundColor Green
    Write-Info 'If the vault uses a firewall, enable "Allow trusted Microsoft services to bypass this firewall" (or private endpoint).'
    Save-State @{ KeyId = $keyIdentifier; CustomerTenantId = $CustomerTenantId }
}

# ------------------------------------------------------------------ phase 3
$SqlApiVersion = '2023-08-01-preview'

function Get-HeaderValue($Headers, [string]$Name) {
    $vals = $null
    if ($Headers -and $Headers.TryGetValues($Name, [ref]$vals)) { return @($vals)[0] }
    return $null
}

# Calls ARM, throws with the full error body on failure, and waits for async (201/202) operations.
function Invoke-Arm([string]$Method, [string]$Path, $Body) {
    $uriPath = if ($Path -match '\?') { $Path } else { "$Path`?api-version=$SqlApiVersion" }
    $params = @{ Method = $Method; Path = $uriPath }
    if ($null -ne $Body) { $params.Payload = ($Body | ConvertTo-Json -Depth 10) }
    $resp = Invoke-AzRestMethod @params
    if ($resp.StatusCode -ge 400) {
        throw "ARM $Method $Path failed: HTTP $($resp.StatusCode)`n$($resp.Content)"
    }
    if ($resp.StatusCode -in 201, 202) {
        $poll = Get-HeaderValue $resp.Headers 'Azure-AsyncOperation'
        if (-not $poll) { $poll = Get-HeaderValue $resp.Headers 'Location' }
        if ($poll) {
            for ($i = 0; $i -lt 120; $i++) {
                Start-Sleep -Seconds 10
                $p = Invoke-AzRestMethod -Method GET -Uri $poll
                if ($p.StatusCode -ge 400) { throw "ARM async operation failed: HTTP $($p.StatusCode)`n$($p.Content)" }
                $status = if ($p.Content) { ($p.Content | ConvertFrom-Json).status } else { $null }
                if ($status -in 'Succeeded') { break }
                if ($status -in 'Failed', 'Canceled') { throw "ARM async operation $status`n$($p.Content)" }
                if (-not $status -and $p.StatusCode -eq 200) { break }
                Write-Info "Waiting for $Method $(Split-Path $Path -Leaf) ($status)..."
            }
        }
    }
    return $resp
}

function Invoke-IsvConfigure {
    $state = Read-State
    if (-not $AppId) { $script:AppId = $state['AppId'] }
    if (-not $KeyId) { $script:KeyId = $state['KeyId'] }
    Assert-Param @{ IsvTenantId = $IsvTenantId; IsvSubscriptionId = $IsvSubscriptionId
                    SqlServerName = $SqlServerName; SqlResourceGroup = $SqlResourceGroup
                    AppId = $script:AppId; KeyId = $script:KeyId }
    Connect-Tenant $IsvTenantId $IsvSubscriptionId 'ISV tenant'

    if ($script:KeyId -notmatch '^https://(?<vault>[^/.]+)\.(vault|managedhsm)\.[^/]+/keys/(?<key>[^/]+)/(?<ver>[0-9a-fA-F]{32})/?$') {
        throw "KeyId must be the full, versioned key identifier URL, e.g. https://<vault>.vault.azure.net/keys/<keyname>/<version>. Got: $($script:KeyId)"
    }
    $serverKeyName = "$($Matches.vault)_$($Matches.key)_$($Matches.ver)"
    $keyUri = $script:KeyId.TrimEnd('/')

    $rg = if ($UamiResourceGroup) { $UamiResourceGroup } else { $SqlResourceGroup }
    $uami = Get-AzUserAssignedIdentity -ResourceGroupName $rg -Name $UamiName
    $serverPath = "/subscriptions/$IsvSubscriptionId/resourceGroups/$SqlResourceGroup/providers/Microsoft.Sql/servers/$SqlServerName"

    # Direct ARM calls instead of Az.Sql cmdlets: they surface the full error code/message (e.g. AuthorizationFailed,
    # LinkedAuthorizationFailed, RequestDisallowedByPolicy) instead of a bare 'Forbidden'.
    function Set-ServerCrossTenantIdentity([string]$Path) {
        $current = (Invoke-Arm GET $Path).Content | ConvertFrom-Json
        $identityType = if ("$($current.identity.type)" -match 'SystemAssigned') { 'SystemAssigned,UserAssigned' } else { 'UserAssigned' }
        $uamis = @{}
        if ($current.identity.userAssignedIdentities) {
            foreach ($p in $current.identity.userAssignedIdentities.PSObject.Properties) { $uamis[$p.Name] = @{} }
        }
        $uamis[$uami.Id] = @{}
        Invoke-Arm PATCH $Path @{
            identity   = @{ type = $identityType; userAssignedIdentities = $uamis }
            properties = @{ primaryUserAssignedIdentityId = $uami.Id; federatedClientId = $script:AppId }
        } | Out-Null
    }

    # Geo-replication / failover-group partners must be able to reach the key BEFORE the primary's
    # protector changes. Docs: configure the secondary first, then the primary.
    if ($PartnerServerName) {
        $pSub = if ($PartnerSubscriptionId) { $PartnerSubscriptionId } else { $IsvSubscriptionId }
        $pRg  = if ($PartnerResourceGroup) { $PartnerResourceGroup } else { $SqlResourceGroup }
        $partnerPath = "/subscriptions/$pSub/resourceGroups/$pRg/providers/Microsoft.Sql/servers/$($PartnerServerName.Split('.')[0])"
        Write-Step "ISV: configure geo-DR partner server $PartnerServerName (identity + key)"
        Set-ServerCrossTenantIdentity $partnerPath
        Write-Info 'Partner identity configured'
        Invoke-Arm PUT "$partnerPath/keys/$serverKeyName" @{ properties = @{ serverKeyType = 'AzureKeyVault'; uri = $keyUri } } | Out-Null
        Write-Info "Partner server key registered: $serverKeyName"
    }

    if ($DatabaseLevel) {
        if (-not $DatabaseName) { throw '-DatabaseLevel requires -DatabaseName.' }
        $dbPath = "$serverPath/databases/$DatabaseName"
        Write-Step "ISV: database-level cross-tenant CMK on $DatabaseName (server protector unchanged)"
        $dbCur = (Invoke-Arm GET $dbPath).Content | ConvertFrom-Json
        $dbUamis = @{}
        if ($dbCur.identity.userAssignedIdentities) {
            foreach ($p in $dbCur.identity.userAssignedIdentities.PSObject.Properties) { $dbUamis[$p.Name] = @{} }
        }
        $dbUamis[$uami.Id] = @{}
        Invoke-Arm PATCH $dbPath @{
            identity   = @{ type = 'UserAssigned'; userAssignedIdentities = $dbUamis }
            properties = @{ encryptionProtector = $keyUri; keys = @{ $keyUri = @{} }; federatedClientId = $script:AppId }
        } | Out-Null

        Write-Step 'Validation'
        $db = (Invoke-Arm GET "$dbPath`?api-version=$SqlApiVersion&`$expand=keys").Content | ConvertFrom-Json
        Write-Info "Database           : $($db.name)  ($($db.sku.tier))"
        Write-Info "Encryption protector: $($db.properties.encryptionProtector)"
        Write-Info "Federated client id : $($db.properties.federatedClientId)"
        Write-Info "Identities          : $(($db.identity.userAssignedIdentities.PSObject.Properties.Name) -join ', ')"
        if ($db.properties.encryptionProtector -ne $keyUri) { throw 'Database encryption protector does not match the customer key.' }
        Write-Host "`nDatabase-level cross-tenant CMK TDE configured on $DatabaseName." -ForegroundColor Green
        return
    }

    Write-Step 'ISV: assign UAMI (primary) + federated client identity on SQL server'
    Set-ServerCrossTenantIdentity $serverPath
    Write-Info 'Identity configured'

    Write-Step 'ISV: register customer key and set TDE protector'
    Invoke-Arm PUT "$serverPath/keys/$serverKeyName" @{ properties = @{ serverKeyType = 'AzureKeyVault'; uri = $keyUri } } | Out-Null
    Write-Info "Server key registered: $serverKeyName"
    Invoke-Arm PUT "$serverPath/encryptionProtector/current" @{
        properties = @{ serverKeyType = 'AzureKeyVault'; serverKeyName = $serverKeyName }
    } | Out-Null
    Write-Info 'TDE protector set'

    Write-Step 'Validation'
    $server = Get-AzSqlServer -ResourceGroupName $SqlResourceGroup -ServerName $SqlServerName
    Write-Info "Primary identity   : $($server.PrimaryUserAssignedIdentityId)"
    Write-Info "Federated client id: $($server.FederatedClientId)"
    $prot = Get-AzSqlServerTransparentDataEncryptionProtector -ResourceGroupName $SqlResourceGroup -ServerName $SqlServerName
    $prot | Format-List ServerName, Type, ServerKeyVaultKeyName, KeyId | Out-String | Write-Host
    if ($prot.Type -ne 'AzureKeyVault') { throw 'TDE protector is not AzureKeyVault.' }

    $dbs = if ($DatabaseName) { @(Get-AzSqlDatabase -ResourceGroupName $SqlResourceGroup -ServerName $SqlServerName -DatabaseName $DatabaseName) }
           else { Get-AzSqlDatabase -ResourceGroupName $SqlResourceGroup -ServerName $SqlServerName | Where-Object DatabaseName -ne 'master' }
    foreach ($db in $dbs) {
        $tde = Get-AzSqlDatabaseTransparentDataEncryption -ResourceGroupName $SqlResourceGroup -ServerName $SqlServerName -DatabaseName $db.DatabaseName
        Write-Info ("{0,-30} edition={1,-12} TDE={2}" -f $db.DatabaseName, $db.Edition, $tde.State)
    }
    Write-Host "`nCross-tenant CMK TDE configured." -ForegroundColor Green
}

# ------------------------------------------------------------------ main
Install-RequiredModules

switch ($Phase) {
    'IsvPrepare'    { Invoke-IsvPrepare }
    'CustomerSetup' { Invoke-CustomerSetup }
    'IsvConfigure'  { Invoke-IsvConfigure }
    'All' {
        Invoke-IsvPrepare
        Invoke-CustomerSetup
        Invoke-IsvConfigure
    }
}
