#Requires -Version 5.1
#Requires -Modules ActiveDirectory
<#
.SYNOPSIS
    Converges patchwork.internal to ad/org.json.

.DESCRIPTION
    org.json is the source of truth for the OU tree, the people in it and their
    org attributes, the role groups (global) and the resource groups (domain
    local). The script only changes what differs, and it logs every change.

    Three phases. Run each with -WhatIf first.

      Build    Make the new tree and groups, create missing users, set
               attributes and group membership. Moves nothing. Deletes only
               the host groups of the hosts in retiredHosts.
      Migrate  Copy GPO links from the old tree, then move every object out of
               the old tree (migration.oldRoot) into the new one. Converts the
               old Linux and app groups to domain local. Objects it cannot map
               stay where they are and are reported.
      Prune    Delete the old tree. Refuses while any non-OU object is still
               in it.

    New users are created disabled with "change password at next logon" and
    with no password. The script never reads, writes or logs a password.

    A user entry is found by its sAMAccountName ("sam") first, then by its
    UPN. If the two find different accounts, the script reports it and does
    not change that user.

    It also sets the default domain password policy and the fine-grained
    password policies (PSOs) in passwordPolicy, and the groups each PSO
    applies to.

    It disables the built-in Administrator (found by its RID 500 SID) when
    builtinAdministrator.enabled is false, but only while an admin account
    in org.json is enabled and is in Domain Admins. It removes that account
    from the groups in builtinAdministrator.removeFrom.

    The tiering block makes the Tier 0 authentication policies and the
    authentication policy silo, and puts the listed users and computers in
    the silo. "enforce": false keeps the silo and its policies in audit mode.
    An account that does not exist (a jump host that is not built yet) is
    reported and skipped. The built-in Administrator is never added: the KDC
    exempts it from every policy.

    tiering.jit prepares just-in-time admin. While jit.enabled is false, or
    while the Privileged Access Management optional feature is off, the JIT
    group is managed like every other role group. When both are on, Build
    stops managing the members of the JIT group, so it never removes a grant
    with a time to live, and it reports each standing member. Standing admin
    memberships are removed only when jit.removeStanding is also true.

    The delegation block gives the domain local groups in delegation.grants
    their rights on OUs (helpdesk on the people OUs, computer admin on
    Servers and Computers). A grant can also name one service account
    ("principal"): svc-weave-ldap gets the Weave rights on the people OUs
    and on Users/Members. It puts explicit deny ACEs on the OUs in
    delegation.deny (Admin-Accounts, Service-Accounts, Servers/Tier0). ACEs
    are added only when missing. Extra ACEs are reported, never removed. It
    also reports the AdminSDHolder state (adminCount=1 accounts, extra ACEs).

    Build moves an object only down, into a child OU of the OU it is in now
    (Admin-Accounts -> Admin-Accounts/Tier0, Servers -> Servers/Tier0 for
    the Tier 0 member servers in tiering.computers). Other moves are Migrate.

    "weaveId" on a person is the Weave public id (PWL..., the OIDC sub).
    Build writes it to employeeID. A person without one is reported. A
    weaveId that another account already holds is reported and not set.

    A group with "formerNames" is renamed, never made again: Build finds it
    by its name, else by a former name, and changes its sAMAccountName, its
    CN and (when it holds a former name) its displayName. The SID stays, so
    members, ACEs, PSO links and other references stay. When the name and a
    former name both exist, Build reports it and does not touch that group
    or anything that names it.

    It never touches the contents of an OU marked "managed": false
    (Users/Members, which Weave owns) or the members of a group marked
    "manageMembers": false.

.EXAMPLE
    .\converge.ps1 -WhatIf
.EXAMPLE
    .\converge.ps1 -Phase Migrate -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('Build', 'Migrate', 'Prune')]
    [string]$Phase = 'Build',
    [string]$DataFile = (Join-Path $PSScriptRoot 'org.json'),
    [string]$LogDir = (Join-Path $env:ProgramData 'Patchwork\ad-converge'),
    # Defaults to the PDC emulator, so every read sees the writes before it.
    [string]$Server
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module ActiveDirectory

$data = Get-Content -Raw -Path $DataFile | ConvertFrom-Json
if (-not $Server) { $Server = (Get-ADDomain).PDCEmulator }
$ad = @{ Server = $Server }
$domain = Get-ADDomain @ad
if ($domain.DNSRoot -ne $data.domain) {
    throw "Connected to $($domain.DNSRoot), but org.json is for $($data.domain)."
}
$domainDN = $domain.DistinguishedName

# --- Logging -----------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $LogDir -WhatIf:$false | Out-Null
$mode = if ($WhatIfPreference) { '-whatif' } else { '' }
$logFile = Join-Path $LogDir ('{0:yyyyMMdd-HHmmss}-{1}{2}.log' -f (Get-Date), $Phase.ToLower(), $mode)
$script:changeCount = 0
$script:errorCount = 0
$script:reportCount = 0

function Write-Log([string]$Level, [string]$Message) {
    $line = '{0:s} {1,-7} {2}' -f (Get-Date), $Level, $Message
    Write-Host $line
    Add-Content -Path $logFile -Value $line -WhatIf:$false
}

# One change. Under -WhatIf it only logs WOULD. Advanced, so it inherits
# -WhatIf from the script through $WhatIfPreference.
function Invoke-Change {
    [CmdletBinding(SupportsShouldProcess)]
    # The block runs in this function's scope chain (PowerShell scoping is
    # dynamic), so these names must not match any variable a caller's block
    # uses. Hence the prefix.
    param([string]$ChgTarget, [string]$ChgAction, [scriptblock]$ChgBlock)
    $script:changeCount++
    if ($PSCmdlet.ShouldProcess($ChgTarget, $ChgAction)) {
        try {
            & $ChgBlock
            Write-Log 'CHANGE' "$ChgAction : $ChgTarget"
        } catch {
            $script:errorCount++
            Write-Log 'ERROR' "$ChgAction : $ChgTarget : $($_.Exception.Message)"
        }
    } else {
        Write-Log 'WOULD' "$ChgAction : $ChgTarget"
    }
}

# Something an operator must look at. Changes nothing.
function Write-Report([string]$Message) {
    $script:reportCount++
    Write-Log 'REPORT' $Message
}

# --- Lookups -----------------------------------------------------------------
$rootDN = "OU=$($data.root),$domainDN"
$oldRootDN = "OU=$($data.migration.oldRoot),$domainDN"

# "Users/Sponsored-Projects/HackBoston" -> "OU=HackBoston,OU=Sponsored-Projects,OU=Users,<root>"
function ConvertTo-OUDN([string]$Path, [string]$Root = $rootDN) {
    if (-not $Path) { return $Root }
    $parts = $Path.Split('/')
    [array]::Reverse($parts)
    (@($parts | ForEach-Object { "OU=$_" }) + $Root) -join ','
}

function Get-ParentDN([string]$DN) {
    # Split on the first comma that is not escaped.
    ($DN -split '(?<!\\),', 2)[1]
}

function Find-Object([string]$Filter, [string[]]$Properties = @()) {
    # Get-ADObject rejects an empty -Properties, so pass it only when set.
    $extra = @{}
    if ($Properties.Count -gt 0) { $extra.Properties = $Properties }
    Get-ADObject -Filter $Filter @extra @ad
}

function Find-User([string]$Sam) {
    Get-ADUser -Filter "SamAccountName -eq '$Sam'" @ad -Properties `
        company, division, department, title, givenName, sn, displayName, manager, `
        userPrincipalName, mail, employeeID, Enabled, ProtectedFromAccidentalDeletion
}

function Find-UserByEmployeeId([string]$Id) {
    Get-ADUser -Filter "employeeID -eq '$Id'" @ad
}

function Find-UserByUpn([string]$Upn) {
    Get-ADUser -Filter "UserPrincipalName -eq '$Upn'" @ad
}

# The UPN that org.json manages for an entry, or $null. "upn" is the part
# before the @. It defaults to "sam".
# The UPN suffix for an entry: its own "upnSuffix", else the nearest OU
# (walking up its path) that sets one, else the forest-wide upnSuffix. A
# sponsored project's OU sets the project's domain, so its organizers log in
# with that domain unless org.json gives a person a different one.
function Get-UpnSuffixFor($u) {
    if (Test-Field $u 'upnSuffix') { return $u.upnSuffix }
    $parts = $u.ou -split '/'
    for ($i = $parts.Count; $i -ge 1; $i--) {
        $path = ($parts[0..($i - 1)]) -join '/'
        $ou = $data.ous | Where-Object { $_.path -eq $path -and $_.PSObject.Properties['upnSuffix'] } | Select-Object -First 1
        if ($ou) { return $ou.upnSuffix }
    }
    $data.upnSuffix
}

# Every UPN suffix that org.json uses.
function Get-UpnSuffixes {
    @(@($data.upnSuffix) + @($data.ous | Where-Object { $_.PSObject.Properties['upnSuffix'] } | ForEach-Object { $_.upnSuffix }) +
        @($data.users | Where-Object { $_.PSObject.Properties['upnSuffix'] } | ForEach-Object { $_.upnSuffix })) |
        Sort-Object -Unique
}

function Get-WantedUpn($u) {
    $local = if (Test-Field $u 'upn') { $u.upn } else { $u.sam }
    $create = -not ($u.PSObject.Properties['create'] -and -not $u.create)
    switch ($u.kind) {
        'person' { return "$local@$(Get-UpnSuffixFor $u)" }
        'admin' { if ($create) { return "$local@$($data.domain)" } }
        # A service account gets a UPN only when org.json sets "upn", for
        # example to match a Workspace address.
        'service' { if (Test-Field $u 'upn') { return "$local@$(Get-UpnSuffixFor $u)" } }
    }
    $null
}

# The group with this exact sAMAccountName, or $null.
function Find-GroupExact([string]$Name) {
    Get-ADGroup -Filter "SamAccountName -eq '$Name'" @ad -Properties Description, DisplayName, ProtectedFromAccidentalDeletion
}

# --- Group renames -------------------------------------------------------------
# A managed group can list "formerNames". Build finds the group by its name
# first, then by a former name, and renames the group it found. A rename
# keeps the object, so the SID, the members, the ACEs, the PSO links and the
# silo references stay. Under -WhatIf the group keeps its old name, so every
# lookup below also follows the former names.
#
# When a group exists under its name AND under a former name (or under two
# former names), the script cannot know which object is right. It reports
# the conflict and does not touch that group, its members, or any group,
# PSO or ACE that names it.

# name -> former names, for every managed group that has them.
$script:formerNames = @{}
foreach ($fg in @($data.roleGroups) + @($data.resourceGroups)) {
    if ($fg.PSObject.Properties['formerNames'] -and @($fg.formerNames).Count) {
        $script:formerNames[$fg.name] = @($fg.formerNames)
    }
}
# ObjectGUID -> managed name, for groups found under a former name.
$script:renamedGuids = @{}
# Managed names with a rename conflict.
$script:groupConflicts = @()

# The group for a managed name: by the name, else by a former name. $null
# for a name with a conflict, so nothing is done to either object.
function Find-Group([string]$Name) {
    if ($script:groupConflicts -contains $Name) { return $null }
    $g = Find-GroupExact $Name
    if ($g -or -not $script:formerNames.ContainsKey($Name)) { return $g }
    foreach ($old in $script:formerNames[$Name]) {
        $g = Find-GroupExact $old
        if ($g) { return $g }
    }
    $null
}

# The name org.json uses for an AD principal: the managed name of a group
# that still has a former name (under -WhatIf), else its sAMAccountName.
function Get-ManagedName($Principal) {
    $guid = "$(Get-Prop $Principal 'ObjectGUID')"
    if ($guid -and $script:renamedGuids.ContainsKey($guid)) { return $script:renamedGuids[$guid] }
    $Principal.SamAccountName
}

# True when one of the names has a rename conflict.
function Test-GroupConflict([string[]]$Names) {
    [bool]@($Names | Where-Object { $script:groupConflicts -contains $_ }).Count
}

# Finds the conflicts and the pending renames. Build calls this first, before
# any other lookup.
function Initialize-GroupNames {
    foreach ($name in @($script:formerNames.Keys | Sort-Object)) {
        $found = @()
        $current = Find-GroupExact $name
        if ($current) { $found += $current }
        # sAMAccountName is one namespace. A user or computer with the new
        # name would get the group's ACEs and memberships.
        $other = @(Find-Object "SamAccountName -eq '$name'" | Where-Object { $_.ObjectClass -ne 'group' })
        if ($other.Count) {
            $script:groupConflicts += $name
            Write-Report "Group ${name}: a $($other[0].ObjectClass) has this sAMAccountName ($($other[0].DistinguishedName)). Nothing was renamed or changed for $name, or for the groups, PSOs and ACEs that name it. Rename that object by hand, then run Build again."
            continue
        }
        foreach ($old in $script:formerNames[$name]) {
            $g = Find-GroupExact $old
            if ($g -and -not ($found | Where-Object { "$($_.ObjectGUID)" -eq "$($g.ObjectGUID)" })) { $found += $g }
        }
        if ($found.Count -gt 1) {
            $script:groupConflicts += $name
            $list = ($found | ForEach-Object { "$($_.SamAccountName) ($($_.DistinguishedName))" }) -join ', '
            Write-Report "Group $name exists more than once: $list. Nothing was renamed or changed for $name, or for the groups, PSOs and ACEs that name it. Delete or rename the wrong object by hand, then run Build again."
        } elseif ($found.Count -eq 1 -and $found[0].SamAccountName -ne $name) {
            $script:renamedGuids["$($found[0].ObjectGUID)"] = $name
        }
    }
}

# Renames a group that org.json lists under another name: sAMAccountName,
# then the CN (Rename-ADObject), then displayName when it holds a former
# name. Each part is its own change, so a run that stops half way is
# finished by the next run.
function Sync-GroupName($G, [string]$Name) {
    $former = @(if ($script:formerNames.ContainsKey($Name)) { $script:formerNames[$Name] })
    if (-not $former.Count) { return }
    if ($G.SamAccountName -ne $Name) {
        Invoke-Change $G.DistinguishedName "Rename group $($G.SamAccountName) to $Name (sAMAccountName)" {
            Set-ADGroup -Identity $G -SamAccountName $Name @ad
        }
    }
    $cn = "$(Get-Prop $G 'Name')"
    if ($cn -cne $Name -and $former -contains $cn) {
        Invoke-Change $G.DistinguishedName "Rename group CN $cn to $Name" {
            Rename-ADObject -Identity $G -NewName $Name @ad
        }
    }
    $disp = "$(Get-Prop $G 'DisplayName')"
    if ($disp -and $former -contains $disp) {
        Invoke-Change $G.DistinguishedName "Set displayName '$Name' (was $disp)" {
            # By GUID: a CN rename above changed the DN of $G.
            Set-ADGroup -Identity $G.ObjectGUID -DisplayName $Name @ad
        }
    }
}

function Test-DN([string]$DN) {
    [bool](Find-Object "distinguishedName -eq '$DN'")
}

$unmanagedPaths = @($data.ous | Where-Object { $_.PSObject.Properties['managed'] -and -not $_.managed } |
        ForEach-Object { $_.path })
# The OUs another system owns, and the old-tree OUs that Migrate maps to them
# (Patchwork-Objects/Members -> Users/Members).
$unmanagedOUs = @($unmanagedPaths | ForEach-Object { ConvertTo-OUDN $_ }) + @($data.migration.ouMap |
        Where-Object { $_.from -and $unmanagedPaths -contains $_.to } | ForEach-Object { ConvertTo-OUDN $_.from $oldRootDN })
# The service accounts that own those OUs ("owner"). An account they created
# has them as its owner, and an owner can change the ACL of the account.
$unmanagedOwners = @($data.ous | Where-Object { $_.PSObject.Properties['managed'] -and -not $_.managed -and $_.PSObject.Properties['owner'] } |
        ForEach-Object { $_.owner })

function Test-InUnmanagedOU([string]$DN) {
    foreach ($ou in $unmanagedOUs) { if ($DN -like "*,$ou") { return $true } }
    $false
}

# A key that is absent is not managed. A key set to null clears the attribute.
function Test-Field($Object, [string]$Name) {
    [bool]$Object.PSObject.Properties[$Name]
}

# The value of a property, or $null when the object does not carry it. AD
# objects can leave out an attribute that is not set.
function Get-Prop($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { $p.Value } else { $null }
}

# Accounts that org.json marks as admin accounts and that the script manages.
function Get-AdminSams {
    @($data.users | Where-Object { $_.kind -eq 'admin' } | ForEach-Object { $_.sam })
}

$builtinSid = "$($domain.DomainSID)-500"

# Every resource group, with {host} expanded for each Linux host. A host can
# add role groups to its own groups with hostGroupMembers.<host>.<kind>, where
# <kind> is the end of the template name (lnx-{host}-<kind>). The template
# members stay.
function Get-ResourceGroups {
    foreach ($h in $data.linuxHosts) {
        # Strict mode: read optional properties through PSObject.Properties.
        $all = $data.PSObject.Properties['hostGroupMembers']
        $extra = if ($all) { $all.Value.PSObject.Properties[$h] }
        foreach ($t in $data.hostGroups) {
            $kind = $t.name.Replace('lnx-{host}-', '')
            $list = if ($extra) { $extra.Value.PSObject.Properties[$kind] }
            $more = if ($list) { @($list.Value) } else { @() }
            [pscustomobject]@{
                name        = $t.name.Replace('{host}', $h)
                description = $t.description.Replace('{host}', $h)
                members     = @(@($t.members) + @($more) | Select-Object -Unique)
            }
        }
    }
    foreach ($g in $data.resourceGroups) { $g }
}

# Reports a hostGroupMembers host that is not in linuxHosts, or a kind that is
# not a hostGroups template. Such an entry gives nobody access.
function Test-HostGroupMembers {
    $all = $data.PSObject.Properties['hostGroupMembers']
    if (-not $all) { return }
    $kinds = @($data.hostGroups | ForEach-Object { $_.name.Replace('lnx-{host}-', '') })
    foreach ($hp in $all.Value.PSObject.Properties) {
        if ($data.linuxHosts -notcontains $hp.Name) {
            Write-Report "hostGroupMembers.$($hp.Name): $($hp.Name) is not in linuxHosts. Nobody gets access from it."
            continue
        }
        foreach ($kp in $hp.Value.PSObject.Properties) {
            if ($kinds -notcontains $kp.Name) {
                Write-Report "hostGroupMembers.$($hp.Name).$($kp.Name): $($kp.Name) is not a hostGroups kind ($($kinds -join ', ')). Nobody gets access from it."
            }
        }
    }
}

# --- Build: pieces -----------------------------------------------------------
function Sync-UpnSuffix {
    $forest = Get-ADForest @ad
    foreach ($suffix in Get-UpnSuffixes) {
        if ($forest.UPNSuffixes -notcontains $suffix) {
            Invoke-Change $forest.Name "Add UPN suffix $suffix" {
                Set-ADForest -Identity $forest -UPNSuffixes @{ Add = $suffix } @ad
            }
        }
    }
}

function Sync-OU([string]$DN, [string]$Description) {
    $ou = Get-ADOrganizationalUnit -Filter "distinguishedName -eq '$DN'" -Properties Description @ad
    if (-not $ou) {
        $name = ($DN -split '(?<!\\),', 2)[0] -replace '^OU=', ''
        Invoke-Change $DN 'Create OU' {
            New-ADOrganizationalUnit -Name $name -Path (Get-ParentDN $DN) -Description $Description `
                -ProtectedFromAccidentalDeletion $true @ad
        }
    } elseif ($ou.Description -ne $Description) {
        Invoke-Change $DN "Set description '$Description'" {
            Set-ADOrganizationalUnit -Identity $DN -Description $Description @ad
        }
    }
}

function Sync-Group([string]$Name, [string]$Description, [string]$Scope, [string]$OUPath) {
    # Initialize-GroupNames reported it.
    if (Test-GroupConflict $Name) { return }
    $g = Find-Group $Name
    $target = ConvertTo-OUDN $OUPath
    if ($g) {
        Sync-GroupName $g $Name
        # Read it again by GUID: a rename changed its name and DN.
        if (-not $WhatIfPreference) {
            $g = Get-ADGroup -Identity $g.ObjectGUID -Properties Description, DisplayName, ProtectedFromAccidentalDeletion @ad
        }
    }
    if (-not $g) {
        Invoke-Change "CN=$Name,$target" "Create $Scope group" {
            New-ADGroup -Name $Name -SamAccountName $Name -GroupCategory Security -GroupScope $Scope `
                -Path $target -Description $Description @ad
        }
        return
    }
    if ($g.Description -ne $Description) {
        Invoke-Change $g.DistinguishedName "Set description '$Description'" {
            Set-ADGroup -Identity $g -Description $Description @ad
        }
    }
    if ((Get-ParentDN $g.DistinguishedName) -ne $target) {
        Write-Report "$Name is in $(Get-ParentDN $g.DistinguishedName), not $target. Migrate moves it."
    }
    if ("$($g.GroupScope)" -ne $Scope) {
        Write-Report "$Name is $($g.GroupScope), not $Scope. Migrate converts it."
    }
}

# Makes the direct members of a group exactly $Desired (sAMAccountNames).
function Sync-Members([string]$Group, [string[]]$Desired) {
    # A member with a rename conflict could be swapped for the wrong object.
    if (Test-GroupConflict (@($Group) + $Desired)) {
        Write-Report "Members of $Group were not changed: $Group or one of its members has a rename conflict (see above)."
        return
    }
    $g = Find-Group $Group
    if (-not $g) {
        if ($Desired.Count) {
            Write-Log 'WOULD' "Add $($Desired -join ', ') : $Group (after it is created)"
        }
        return
    }
    $current = @(Get-ADGroupMember -Identity $g @ad | ForEach-Object { Get-ManagedName $_ })
    foreach ($m in $Desired | Where-Object { $current -notcontains $_ }) {
        # Under -WhatIf a new user does not exist yet. In a real run a missing
        # member is a user that Sync-User skipped.
        $mu = Find-User $m
        if (-not $WhatIfPreference -and -not $mu -and -not (Find-Group $m)) {
            Write-Report "$m does not exist, so it was not added to $Group. Read the reports for $m above."
            continue
        }
        if ($mu -and (Test-InUnmanagedOU $mu.DistinguishedName)) {
            Write-Report "$m is $($mu.DistinguishedName), in an OU that another system owns, so it was not added to $Group."
            continue
        }
        Invoke-Change $Group "Add member $m" {
            # The resolved object, not the name: a managed group goes by
            # Find-Group, so a user with the same name is never added.
            $mObj = if ($script:formerNames.ContainsKey($m)) { Find-Group $m } else { $m }
            Add-ADGroupMember -Identity $g -Members $mObj @ad
        }
    }
    foreach ($m in $current | Where-Object { $Desired -notcontains $_ }) {
        Invoke-Change $Group "Remove member $m" {
            Remove-ADGroupMember -Identity $g -Members $m -Confirm:$false @ad
        }
    }
}

function Sync-User($u) {
    $target = ConvertTo-OUDN $u.ou
    $existing = Find-User $u.sam
    $create = -not ($u.PSObject.Properties['create'] -and -not $u.create)
    $upn = Get-WantedUpn $u

    # Match on both: the sAMAccountName first, then the UPN. If the UPN
    # belongs to another account, a create or a rename would make a
    # duplicate person. A person must decide which account is right.
    if ($upn) {
        $byUpn = Find-UserByUpn $upn
        if ($byUpn -and (-not $existing -or "$($byUpn.ObjectGUID)" -ne "$($existing.ObjectGUID)")) {
            $samText = if ($existing) { "$($u.sam) is $($existing.DistinguishedName)" } else { "$($u.sam) does not exist" }
            Write-Report "$($u.sam): UPN $upn belongs to $($byUpn.SamAccountName) ($($byUpn.DistinguishedName)), but $samText. Nothing changed for this user. Fix org.json or the accounts."
            return
        }
    }

    # Attributes this entry manages: LDAP name -> value ($null clears).
    $want = [ordered]@{}
    if ($u.kind -eq 'person') { $want.company = $data.company }
    if ($upn) { $want.userPrincipalName = $upn }
    foreach ($pair in @(
            @('company', 'company'), @('division', 'division'), @('department', 'department'),
            @('title', 'title'), @('givenName', 'givenName'), @('surname', 'sn'),
            @('displayName', 'displayName'), @('mail', 'mail'))) {
        if (Test-Field $u $pair[0]) { $want[$pair[1]] = $u.($pair[0]) }
    }
    # The Weave link. Only a person has one. Weave sets employeeID itself
    # for the members it creates in Users/Members.
    if ($u.kind -eq 'person') {
        if (Test-Field $u 'weaveId') {
            $want.employeeID = $u.weaveId
            if ($u.weaveId) {
                $holder = Find-UserByEmployeeId $u.weaveId
                if ($holder -and (-not $existing -or "$($holder.ObjectGUID)" -ne "$($existing.ObjectGUID)")) {
                    Write-Report "$($u.sam): weaveId $($u.weaveId) is the employeeID of $($holder.SamAccountName) ($($holder.DistinguishedName)). employeeID was not set. Fix org.json or the accounts."
                    $want.Remove('employeeID')
                }
            }
        } else {
            Write-Report "$($u.sam) has no weaveId. Weave cannot link this account. Add the Weave public id (PWL...) to org.json."
        }
    }
    if (-not $want.Contains('displayName') -and $want.Contains('givenName') -and $want.Contains('sn')) {
        $want.displayName = "$($want.givenName) $($want.sn)"
    }
    if (Test-Field $u 'manager') {
        $managerSam = $u.manager
        $want.manager = if ($managerSam) {
            $m = Find-User $managerSam
            if ($m) { $m.DistinguishedName } else {
                Write-Report "$($u.sam): manager $managerSam does not exist yet. Run Build again after it is created."
                $null
            }
        } else { $null }
    }

    # An account in an OU that another system owns (a Weave member) is never
    # taken over by a name match. Weave picks member names, so a member could
    # otherwise get the name of a future entry and, with it, its groups.
    if ($existing -and (Test-InUnmanagedOU $existing.DistinguishedName)) {
        Write-Report "$($u.sam) is $($existing.DistinguishedName), in an OU that another system owns. Nothing changed for this user. Pick another sam, or move the account out by hand and set its owner to Domain Admins."
        return
    }
    if ($existing) { Test-ForeignOwner $existing $u.sam }

    if (-not $existing) {
        if (-not $create) {
            Write-Report "$($u.sam) does not exist. org.json says not to create it."
            return
        }
        $name = if ($want.Contains('displayName') -and $want.displayName) { $want.displayName } else { $u.sam }
        $other = @{}
        foreach ($k in $want.Keys) { if ($null -ne $want[$k]) { $other[$k] = $want[$k] } }
        # New-ADUser rejects an empty -OtherAttributes (users with no
        # attributes, such as the disabled ones), so pass it only when set.
        $newArgs = @{}
        if ($other.Count -gt 0) { $newArgs.OtherAttributes = $other }
        Invoke-Change "CN=$name,$target" 'Create user (disabled, must change password)' {
            New-ADUser -Name $name -SamAccountName $u.sam -Path $target -Enabled $false `
                -ChangePasswordAtLogon $true @newArgs @ad
        }
        return
    }

    $replace = @{}
    $clear = @()
    foreach ($k in $want.Keys) {
        $have = $existing.$k
        if ($null -eq $want[$k]) {
            if ($null -ne $have -and "$have" -ne '') { $clear += $k }
        } elseif ("$have" -cne "$($want[$k])") {
            $replace[$k] = $want[$k]
        }
    }
    if ($replace.Count) {
        $desc = ($replace.Keys | Sort-Object | ForEach-Object { "$_='$($replace[$_])'" }) -join ', '
        Invoke-Change $existing.DistinguishedName "Set $desc" {
            Set-ADUser -Identity $existing -Replace $replace @ad
        }
    }
    if ($clear.Count) {
        Invoke-Change $existing.DistinguishedName "Clear $($clear -join ', ')" {
            Set-ADUser -Identity $existing -Clear $clear @ad
        }
    }

    if ($u.kind -eq 'disabled') {
        if ($existing.Enabled) {
            Invoke-Change $existing.DistinguishedName 'Disable account' { Disable-ADAccount -Identity $existing @ad }
        }
        foreach ($grp in Get-ADPrincipalGroupMembership -Identity $existing @ad) {
            if ($grp.Name -eq 'Domain Users') { continue }
            Invoke-Change $grp.Name "Remove disabled user $($u.sam)" {
                Remove-ADGroupMember -Identity $grp -Members $existing -Confirm:$false @ad
            }
        }
    } elseif (-not $existing.Enabled -and $create) {
        Write-Report "$($u.sam) is disabled. Enable it after the person sets a password."
    }

    Sync-Placement $existing $target $u.sam
}

# Reports a managed account whose owner is the service account of an
# unmanaged OU (a Weave member that became staff). The owner can change the
# ACL of the account, so it can give itself any right on it.
function Test-ForeignOwner($Obj, [string]$Label) {
    if (-not $unmanagedOwners.Count) { return }
    $owner = "$((Get-Acl -Path (Get-AclPath $Obj.DistinguishedName)).Owner)"
    foreach ($o in $unmanagedOwners) {
        if ($owner -eq $o -or $owner -like "*\$o") {
            Write-Report "$Label is owned by $owner. The owner can change its ACL. Set the owner to Domain Admins: dsacls `"$($Obj.DistinguishedName)`" /takeownership, as a Domain Admin."
        }
    }
}

# True when $Child is an OU below $Parent, and $Parent is in the new tree.
function Test-BelowInNewTree([string]$Child, [string]$Parent) {
    ($Parent -eq $rootDN -or $Parent -like "*,$rootDN") -and $Child -like "*,$Parent"
}

# Puts an object in its target OU. Build moves it only DOWN, into a child OU
# of the OU it is in now, inside the new tree (Admin-Accounts ->
# Admin-Accounts/Tier0, Servers -> Servers/Tier0). The GPOs of the old OU
# still apply there by inheritance. Every other difference is reported.
function Sync-Placement($Obj, [string]$Target, [string]$Label) {
    $parent = Get-ParentDN $Obj.DistinguishedName
    if ($parent -eq $Target) { return }
    if (-not (Test-BelowInNewTree $Target $parent)) {
        Write-Report "$Label is in $parent, not $Target. Migrate moves it."
        return
    }
    $wasProtected = [bool](Get-Prop $Obj 'ProtectedFromAccidentalDeletion')
    Invoke-Change $Obj.DistinguishedName "Move to $Target (a child OU of its OU)" {
        if ($wasProtected) { Set-ADObject -Identity $Obj -ProtectedFromAccidentalDeletion $false @ad }
        $movedObj = Move-ADObject -Identity $Obj -TargetPath $Target -PassThru @ad
        if ($wasProtected) { Set-ADObject -Identity $movedObj -ProtectedFromAccidentalDeletion $true @ad }
    }
}

# Tier 0 member servers (tiering.computers that are not DCs) belong in
# tiering.serverOU, where the delegation block denies Tier 1 rights.
function Sync-Tier0Servers {
    $t = $data.tiering
    if (-not (Test-Field $t 'serverOU')) { return }
    $target = ConvertTo-OUDN $t.serverOU
    foreach ($c in @($t.computers)) {
        # A computer that does not exist is reported by Sync-SiloMembers.
        $o = Find-Object "SamAccountName -eq '$c`$'" @('ProtectedFromAccidentalDeletion')
        if (-not $o) { continue }
        if ((Get-ParentDN $o.DistinguishedName) -eq "OU=Domain Controllers,$domainDN") { continue }
        Sync-Placement $o $target $c
    }
}

# Deletes the host groups of hosts that no longer exist (retiredHosts).
function Remove-RetiredHostGroups {
    foreach ($h in $data.retiredHosts) {
        foreach ($t in $data.hostGroups) {
            $name = $t.name.Replace('{host}', $h)
            $g = Find-Group $name
            if (-not $g) { continue }
            Invoke-Change $g.DistinguishedName "Delete group of retired host $h" {
                if ($g.ProtectedFromAccidentalDeletion) {
                    Set-ADObject -Identity $g -ProtectedFromAccidentalDeletion $false @ad
                }
                Remove-ADGroup -Identity $g -Confirm:$false @ad
            }
        }
    }
}

# The accounts that have a Domain Admins path before this run changes
# anything: direct members, and members of the tier 0 group if that group is
# already in Domain Admins. Build calls this first.
function Get-DomainAdminPaths {
    $da = Get-ADGroup -Identity 'Domain Admins' @ad
    $direct = @(Get-ADGroupMember -Identity $da @ad)
    $paths = @($direct | ForEach-Object { $_.SamAccountName })
    $tier0 = Find-Group $data.privileged.tier0Group
    if ($tier0 -and ($paths -contains $tier0.SamAccountName)) {
        $paths += @(Get-ADGroupMember -Identity $tier0 @ad | ForEach-Object { $_.SamAccountName })
    }
    $paths
}

function Sync-Privileged([string[]]$PathsAtStart) {
    $p = $data.privileged
    $tier0 = Find-Group $p.tier0Group
    $da = Get-ADGroup -Identity "Domain Admins" @ad
    if (Test-GroupConflict $p.tier0Group) {
        Write-Report "$($p.tier0Group) was not checked in Domain Admins: it has a rename conflict (see above)."
    } elseif ($tier0) {
        $daMembers = @(Get-ADGroupMember -Identity $da @ad | ForEach-Object { $_.SamAccountName })
        if ($daMembers -notcontains $tier0.SamAccountName) {
            Invoke-Change 'Domain Admins' "Add member $($p.tier0Group)" {
                Add-ADGroupMember -Identity $da -Members $tier0 @ad
            }
        }
    } else {
        Write-Log 'WOULD' "Add member $($p.tier0Group) : Domain Admins (after it is created)"
    }

    # Daily accounts lose admin rights only when every admin account can log
    # in and already had a Domain Admins path when this run started. A path
    # that this run adds does not count, so one run never removes the old
    # path and adds the new one. Otherwise this could lock the operator out.
    # Admin accounts themselves are never removed here, only reported.
    $admins = @($data.users | Where-Object { $_.kind -eq 'admin' -and -not ($_.PSObject.Properties['create'] -and -not $_.create) })
    $adminsReady = $admins.Count -gt 0
    foreach ($a in $admins) {
        $acct = Find-User $a.sam
        if (-not $acct -or -not $acct.Enabled -or ($PathsAtStart -notcontains $a.sam)) { $adminsReady = $false }
    }
    $people = @($data.users | Where-Object { $_.kind -eq 'person' } | ForEach-Object { $_.sam })
    $adminSams = Get-AdminSams
    # Sync-BuiltinAdministrator removes the built-in account from these.
    $builtinLeaves = @()
    if ($data.PSObject.Properties['builtinAdministrator'] -and (Test-Field $data.builtinAdministrator 'removeFrom')) {
        $builtinLeaves = @($data.builtinAdministrator.removeFrom)
    }

    foreach ($name in $p.groups) {
        $g = Get-ADGroup -Identity $name @ad
        $allowed = @($p.allowedDirectMembers.$name)
        foreach ($m in Get-ADGroupMember -Identity $g @ad) {
            if ("$($m.SID)" -eq $builtinSid -and $builtinLeaves -contains $name) { continue }
            $mName = Get-ManagedName $m
            if ($adminSams -contains $m.SamAccountName -and $allowed -notcontains $m.SamAccountName) {
                if ($script:removeStanding) {
                    Invoke-Change $name "Remove standing admin $($m.SamAccountName) (JIT is on)" {
                        Remove-ADGroupMember -Identity $g -Members $m -Confirm:$false @ad
                    }
                } else {
                    Write-Report "$($m.SamAccountName) is a direct member of $name and is not allowed in org.json. It stays until tiering.jit.removeStanding is true."
                }
                continue
            }
            if ($people -contains $m.SamAccountName) {
                if ($adminsReady) {
                    Invoke-Change $name "Remove daily account $($m.SamAccountName)" {
                        Remove-ADGroupMember -Identity $g -Members $m -Confirm:$false @ad
                    }
                } else {
                    Write-Report "$($m.SamAccountName) is in $name. It stays until every admin account is enabled and had a Domain Admins path before the run."
                }
            } elseif ($allowed -notcontains $mName) {
                Write-Report "$($m.SamAccountName) is a direct member of $name and is not allowed in org.json."
            }
        }
    }
}

# --- Password policy ---------------------------------------------------------
# org.json key -> cmdlet parameter and unit. A key that is absent is not
# managed. A time of 0 means never (AD stores it as Int64.MinValue).
$policyKeys = [ordered]@{
    minPasswordLength               = @('MinPasswordLength', 'int')
    passwordHistoryCount            = @('PasswordHistoryCount', 'int')
    complexityEnabled               = @('ComplexityEnabled', 'bool')
    reversibleEncryptionEnabled     = @('ReversibleEncryptionEnabled', 'bool')
    minPasswordAgeDays              = @('MinPasswordAge', 'days')
    maxPasswordAgeDays              = @('MaxPasswordAge', 'days')
    lockoutThreshold                = @('LockoutThreshold', 'int')
    lockoutDurationMinutes          = @('LockoutDuration', 'minutes')
    lockoutObservationWindowMinutes = @('LockoutObservationWindow', 'minutes')
}

# Cmdlet parameters for one policy entry in org.json.
function Get-PolicyParams($Spec) {
    $params = @{}
    foreach ($k in $policyKeys.Keys) {
        if (-not (Test-Field $Spec $k)) { continue }
        $param, $unit = $policyKeys[$k]
        $v = $Spec.$k
        $params[$param] = switch ($unit) {
            'int' { [int]$v }
            'bool' { [bool]$v }
            'days' { [TimeSpan]::FromDays($v) }
            'minutes' { [TimeSpan]::FromMinutes($v) }
        }
    }
    $params
}

function ConvertTo-PolicyValue($Value) {
    if ($Value -is [TimeSpan]) {
        # Never is 0 when it is set, and can be Int64.MinValue when it is read.
        if ($Value.Ticks -le 0) { return 'never' }
        return $Value.ToString()
    }
    "$Value"
}

# The parameters in $Want whose value differs from $Current.
function Get-PolicyDiff($Current, $Want) {
    $diff = @{}
    foreach ($k in $Want.Keys) {
        $have = if ($Current) { $Current.$k } else { $null }
        if ((ConvertTo-PolicyValue $have) -ne (ConvertTo-PolicyValue $Want[$k])) { $diff[$k] = $Want[$k] }
    }
    $diff
}

function Format-Policy($Params) {
    ($Params.Keys | Sort-Object | ForEach-Object { "$_=$(ConvertTo-PolicyValue $Params[$_])" }) -join ', '
}

function Sync-DefaultPasswordPolicy {
    $spec = $data.passwordPolicy.default
    $current = Get-ADDefaultDomainPasswordPolicy -Identity $domainDN @ad
    $diff = Get-PolicyDiff $current (Get-PolicyParams $spec)
    if ($diff.Count) {
        Invoke-Change "default domain password policy ($($data.domain))" "Set $(Format-Policy $diff)" {
            Set-ADDefaultDomainPasswordPolicy -Identity $domainDN @diff @ad
        }
    }
}

# Makes the subjects of a PSO exactly the groups in $Desired.
function Sync-PsoSubjects($Pso, [string]$PsoName, [string[]]$Desired) {
    if (Test-GroupConflict $Desired) {
        Write-Report "Subjects of $PsoName were not changed: one of them has a rename conflict (see above)."
        return
    }
    $current = @()
    if ($Pso) {
        $current = @(Get-ADFineGrainedPasswordPolicySubject -Identity $Pso @ad | ForEach-Object { Get-ManagedName $_ })
    }
    foreach ($s in $Desired | Where-Object { $current -notcontains $_ }) {
        $g = Find-Group $s
        if (-not $Pso -or -not $g) {
            Write-Log 'WOULD' "Apply to $s : $PsoName (after it is created)"
            continue
        }
        Invoke-Change $PsoName "Apply to $s" {
            Add-ADFineGrainedPasswordPolicySubject -Identity $Pso -Subjects $g @ad
        }
    }
    foreach ($s in $current | Where-Object { $Desired -notcontains $_ }) {
        Invoke-Change $PsoName "Stop applying to $s" {
            Remove-ADFineGrainedPasswordPolicySubject -Identity $Pso -Subjects $s -Confirm:$false @ad
        }
    }
}

function Sync-PasswordPolicies {
    if (-not $data.PSObject.Properties['passwordPolicy']) { return }
    Sync-DefaultPasswordPolicy

    $names = @($data.passwordPolicy.psos | ForEach-Object { $_.name })
    foreach ($p in $data.passwordPolicy.psos) {
        $pso = Get-ADFineGrainedPasswordPolicy -Filter "Name -eq '$($p.name)'" -Properties Description @ad
        $want = Get-PolicyParams $p
        $want.Precedence = [int]$p.precedence
        $description = if (Test-Field $p 'description') { $p.description } else { $null }
        if (-not $pso) {
            Invoke-Change "PSO $($p.name)" "Create PSO, $(Format-Policy $want)" {
                New-ADFineGrainedPasswordPolicy -Name $p.name -Description $description `
                    -ProtectedFromAccidentalDeletion $true @want @ad
            }
            $pso = Get-ADFineGrainedPasswordPolicy -Filter "Name -eq '$($p.name)'" @ad
        } else {
            $diff = Get-PolicyDiff $pso $want
            if ($diff.Count) {
                Invoke-Change "PSO $($p.name)" "Set $(Format-Policy $diff)" {
                    Set-ADFineGrainedPasswordPolicy -Identity $pso @diff @ad
                }
            }
            if ("$($pso.Description)" -ne "$description") {
                Invoke-Change "PSO $($p.name)" "Set description '$description'" {
                    Set-ADFineGrainedPasswordPolicy -Identity $pso -Description $description @ad
                }
            }
        }
        Sync-PsoSubjects $pso "PSO $($p.name)" @($p.appliesTo)
    }

    foreach ($pso in @(Get-ADFineGrainedPasswordPolicy -Filter * @ad)) {
        if ($names -notcontains $pso.Name) {
            Write-Report "PSO $($pso.Name) is in AD but not in org.json. Add it to org.json or delete it."
        }
    }
}

# The built-in Administrator, found by SID (<domain SID>-500), because it can
# be renamed. It is disabled only while an admin account from org.json is
# enabled and is in Domain Admins (direct or nested) now. Otherwise nobody
# could log in as a domain admin, except with DSRM on a DC.
function Sync-BuiltinAdministrator {
    if (-not $data.PSObject.Properties['builtinAdministrator']) { return }
    $wantEnabled = [bool]$data.builtinAdministrator.enabled
    $sid = $builtinSid
    $acct = Get-ADUser -Identity $sid @ad
    $label = "built-in Administrator $($acct.SamAccountName) ($sid)"

    # As a Domain Admin in the forest root it can add itself back when it
    # is needed, so it does not need Enterprise Admins or Schema Admins.
    if (Test-Field $data.builtinAdministrator 'removeFrom') {
        foreach ($name in @($data.builtinAdministrator.removeFrom)) {
            $g = Find-Group $name
            if (-not $g) { continue }
            $sids = @(Get-ADGroupMember -Identity $g @ad | ForEach-Object { "$($_.SID)" })
            if ($sids -contains $sid) {
                Invoke-Change $name "Remove $label" {
                    Remove-ADGroupMember -Identity $g -Members $acct -Confirm:$false @ad
                }
            }
        }
    }

    if ($wantEnabled) {
        if (-not $acct.Enabled) {
            Invoke-Change $acct.DistinguishedName "Enable $label" { Enable-ADAccount -Identity $acct @ad }
        }
        return
    }
    if (-not $acct.Enabled) { return }

    $daUsers = @(Get-ADGroupMember -Identity 'Domain Admins' -Recursive @ad | ForEach-Object { $_.SamAccountName })
    $admins = @($data.users | Where-Object { $_.kind -eq 'admin' -and -not ($_.PSObject.Properties['create'] -and -not $_.create) })
    $ready = @($admins | Where-Object {
            $a = Find-User $_.sam
            $a -and $a.Enabled -and ($daUsers -contains $_.sam)
        })
    if (-not $ready.Count) {
        Write-Report "$label stays enabled. No admin account in org.json is enabled and in Domain Admins."
        return
    }
    Invoke-Change $acct.DistinguishedName "Disable $label ($(($ready | ForEach-Object { $_.sam }) -join ', ') is enabled and in Domain Admins)" {
        Disable-ADAccount -Identity $acct @ad
    }
}

# --- Tiering: authentication policies and the Tier 0 silo ----------------------
# "allowed to authenticate from" = the device is in the silo. In this
# attribute @USER means the device account.
function Get-SiloSddl([string]$Silo) {
    'O:SYG:SYD:(XA;OICI;CR;;;WD;(@USER.ad://ext/AuthenticationSilo == "{0}"))' -f $Silo
}

# AD can give the SDDL back with other spacing or case.
function ConvertTo-SddlKey([string]$Sddl) { ($Sddl -replace '\s', '').ToLowerInvariant() }

# "CN=T0-User,CN=AuthN Policies,..." -> "T0-User"
function Get-RdnName($DN) {
    if (-not $DN) { return $null }
    (("$DN" -split '(?<!\\),', 2)[0] -split '=', 2)[1]
}

# One authentication policy. A TGT lifetime makes the TGT short. AD has no
# separate "renewable" switch: the KDC does not renew a TGT past the policy
# lifetime, so the user must log on again when it ends.
function Sync-AuthPolicy($Spec, [bool]$Enforce, [string]$Silo) {
    $name = $Spec.name
    $label = "authentication policy $name"
    $desc = if (Test-Field $Spec 'description') { $Spec.description } else { $null }
    $tgt = if (Test-Field $Spec 'tgtMinutes') { [int]$Spec.tgtMinutes } else { 0 }
    $sddl = if ((Test-Field $Spec 'deviceInSilo') -and $Spec.deviceInSilo) { Get-SiloSddl $Silo } else { $null }

    $p = Get-ADAuthenticationPolicy -Filter "Name -eq '$name'" @ad `
        -Properties Description, Enforce, UserTGTLifetimeMins, UserAllowedToAuthenticateFrom
    if (-not $p) {
        $newArgs = @{}
        if ($desc) { $newArgs.Description = $desc }
        if ($tgt) { $newArgs.UserTGTLifetimeMins = $tgt }
        if ($sddl) { $newArgs.UserAllowedToAuthenticateFrom = $sddl }
        $what = "enforce=$Enforce, tgtMinutes=$(if ($tgt) { $tgt } else { 'none' }), deviceInSilo=$([bool]$sddl)"
        Invoke-Change $label "Create, $what" {
            New-ADAuthenticationPolicy -Name $name -Enforce:$Enforce -ProtectedFromAccidentalDeletion $true @newArgs @ad
        }
        return
    }

    $set = @{}
    $clear = @()
    if ([bool](Get-Prop $p 'Enforce') -ne $Enforce) { $set.Enforce = $Enforce }
    if ("$(Get-Prop $p 'Description')" -ne "$desc") {
        if ($desc) { $set.Description = $desc } else { $clear += 'description' }
    }
    $haveTgt = [int](Get-Prop $p 'UserTGTLifetimeMins')
    if ($tgt -and $haveTgt -ne $tgt) { $set.UserTGTLifetimeMins = $tgt }
    if (-not $tgt -and $haveTgt) { $clear += 'msDS-UserTGTLifetime' }
    $haveSddl = "$(Get-Prop $p 'UserAllowedToAuthenticateFrom')"
    if ($sddl -and (ConvertTo-SddlKey $haveSddl) -ne (ConvertTo-SddlKey $sddl)) { $set.UserAllowedToAuthenticateFrom = $sddl }
    if (-not $sddl -and $haveSddl) { $clear += 'msDS-UserAllowedToAuthenticateFrom' }

    if ($set.Count) {
        $desc2 = ($set.Keys | Sort-Object | ForEach-Object { "$_=$($set[$_])" }) -join ', '
        Invoke-Change $label "Set $desc2" { Set-ADAuthenticationPolicy -Identity $p @set @ad }
    }
    if ($clear.Count) {
        Invoke-Change $label "Clear $($clear -join ', ')" { Set-ADAuthenticationPolicy -Identity $p -Clear $clear @ad }
    }
}

# The silo and the policies it points at. Returns the silo, or $null when
# it does not exist yet (under -WhatIf).
function Sync-Silo {
    $t = $data.tiering
    $enforce = [bool]$t.enforce
    $want = [ordered]@{
        UserAuthenticationPolicy     = $t.userPolicy.name
        ComputerAuthenticationPolicy = $t.computerPolicy.name
        ServiceAuthenticationPolicy  = $null
    }
    if ((Test-Field $t 'servicePolicy') -and (Test-Field $t.servicePolicy 'inSilo') -and $t.servicePolicy.inSilo) {
        $want.ServiceAuthenticationPolicy = $t.servicePolicy.name
    }
    $desc = if (Test-Field $t 'description') { $t.description } else { $null }
    $label = "authentication policy silo $($t.silo)"

    $s = Get-ADAuthenticationPolicySilo -Filter "Name -eq '$($t.silo)'" @ad -Properties Description, Enforce, `
        UserAuthenticationPolicy, ComputerAuthenticationPolicy, ServiceAuthenticationPolicy
    if (-not $s) {
        $newArgs = @{}
        foreach ($k in $want.Keys) { if ($want[$k]) { $newArgs[$k] = $want[$k] } }
        if ($desc) { $newArgs.Description = $desc }
        $what = ($want.Keys | ForEach-Object { "$_=$(if ($want[$_]) { $want[$_] } else { 'none' })" }) -join ', '
        Invoke-Change $label "Create, enforce=$enforce, $what" {
            New-ADAuthenticationPolicySilo -Name $t.silo -Enforce:$enforce -ProtectedFromAccidentalDeletion $true @newArgs @ad
        }
        return Get-ADAuthenticationPolicySilo -Filter "Name -eq '$($t.silo)'" @ad
    }

    $set = @{}
    $clear = @()
    if ([bool](Get-Prop $s 'Enforce') -ne $enforce) { $set.Enforce = $enforce }
    if ("$(Get-Prop $s 'Description')" -ne "$desc") {
        if ($desc) { $set.Description = $desc } else { $clear += 'description' }
    }
    $ldap = @{
        UserAuthenticationPolicy     = 'msDS-UserAuthNPolicy'
        ComputerAuthenticationPolicy = 'msDS-ComputerAuthNPolicy'
        ServiceAuthenticationPolicy  = 'msDS-ServiceAuthNPolicy'
    }
    foreach ($k in $want.Keys) {
        $have = Get-RdnName (Get-Prop $s $k)
        if ($want[$k] -and $have -ne $want[$k]) { $set[$k] = $want[$k] }
        if (-not $want[$k] -and $have) { $clear += $ldap[$k] }
    }
    if ($set.Count) {
        $desc2 = ($set.Keys | Sort-Object | ForEach-Object { "$_=$($set[$_])" }) -join ', '
        Invoke-Change $label "Set $desc2" { Set-ADAuthenticationPolicySilo -Identity $s @set @ad }
    }
    if ($clear.Count) {
        Invoke-Change $label "Clear $($clear -join ', ')" { Set-ADAuthenticationPolicySilo -Identity $s -Clear $clear @ad }
    }
    $s
}

# Each account needs two things: access to the silo (the silo's member list)
# and the silo assigned to it. Accounts are never taken out of the silo
# here, only reported, so a run cannot cut the admin off a Tier 0 host.
function Sync-SiloMembers($Silo) {
    $t = $data.tiering
    $siloName = $t.silo
    $builtinSam = (Get-ADUser -Identity $builtinSid @ad).SamAccountName
    $granted = @()
    if ($Silo) {
        $granted = @(Get-Prop (Get-ADObject -Identity $Silo.DistinguishedName -Properties 'msDS-AuthNPolicySiloMembers' @ad) `
                'msDS-AuthNPolicySiloMembers' | ForEach-Object { "$_" })
    }
    $sams = @($t.users) + @($t.computers | ForEach-Object { "$_`$" })
    $wantedDNs = @()
    foreach ($sam in $sams) {
        if ($sam -eq $builtinSam) {
            Write-Report "$sam is the built-in Administrator. Authentication policies never apply to it, so it is not added to $siloName."
            continue
        }
        $o = Find-Object "SamAccountName -eq '$sam'" @('msDS-AssignedAuthNPolicySilo')
        if (-not $o) {
            Write-Report "$sam does not exist, so it is not in $siloName. Run Build again after it is created or joined."
            continue
        }
        $dn = $o.DistinguishedName
        $wantedDNs += $dn
        if (-not $Silo) {
            Write-Log 'WOULD' "Grant access to $sam, assign the silo : $siloName (after it is created)"
            continue
        }
        if ($granted -notcontains $dn) {
            Invoke-Change $siloName "Grant access to $sam" {
                Grant-ADAuthenticationPolicySiloAccess -Identity $Silo.DistinguishedName -Account $dn @ad
            }
        }
        if ("$(Get-Prop $o 'msDS-AssignedAuthNPolicySilo')" -ne $Silo.DistinguishedName) {
            Invoke-Change $dn "Assign silo $siloName" {
                Set-ADAccountAuthenticationPolicySilo -Identity $dn -AuthenticationPolicySilo $Silo.DistinguishedName @ad
            }
        }
    }
    foreach ($dn in $granted | Where-Object { $wantedDNs -notcontains $_ }) {
        Write-Report "$dn has access to $siloName, but it is not in tiering in org.json. Add it to org.json, or remove it by hand with Revoke-ADAuthenticationPolicySiloAccess."
    }
}

function Sync-Tiering {
    if (-not $data.PSObject.Properties['tiering']) { return }
    $t = $data.tiering
    $enforce = [bool]$t.enforce
    Sync-AuthPolicy $t.userPolicy $enforce $t.silo
    Sync-AuthPolicy $t.computerPolicy $enforce $t.silo
    if (Test-Field $t 'servicePolicy') {
        $svcEnforce = if (Test-Field $t.servicePolicy 'enforce') { [bool]$t.servicePolicy.enforce } else { $enforce }
        Sync-AuthPolicy $t.servicePolicy $svcEnforce $t.silo
    }
    Sync-Tier0Servers
    $silo = Sync-Silo
    Sync-SiloMembers $silo
}

# --- Tiering: just-in-time admin ----------------------------------------------
function Get-Jit {
    if (-not $data.PSObject.Properties['tiering'] -or -not (Test-Field $data.tiering 'jit')) { return $null }
    $data.tiering.jit
}

function Test-PamFeature {
    $f = Get-ADOptionalFeature -Identity 'Privileged Access Management Feature' @ad
    @(Get-Prop $f 'EnabledScopes').Count -gt 0
}

# JIT is active only when org.json turns it on AND the forest can expire a
# membership. Without the PAM feature a "grant" would be standing admin.
function Test-JitActive {
    $jit = Get-Jit
    if (-not $jit -or -not $jit.enabled) { return $false }
    if (-not (Test-PamFeature)) {
        Write-Report "tiering.jit.enabled is true, but the Privileged Access Management optional feature is off. $($jit.group) is managed as if JIT were off."
        return $false
    }
    $true
}

# Standing admin is removed only when JIT is active, removeStanding is true,
# and a Domain Admins path that does not depend on JIT stays: an enabled
# admin account (svc-ansible) that is a direct member of Domain Admins.
function Test-RemoveStanding {
    $jit = Get-Jit
    if (-not $jit -or -not (Test-Field $jit 'removeStanding') -or -not $jit.removeStanding) { return $false }
    if (-not $script:jitActive) {
        Write-Report 'tiering.jit.removeStanding is true, but JIT is not active. No standing admin membership is removed.'
        return $false
    }
    # Only an allowed direct member counts. A standing member that this run
    # would remove is not a fallback.
    $direct = @(Get-ADGroupMember -Identity 'Domain Admins' @ad | ForEach-Object { $_.SamAccountName })
    $allowed = @($data.privileged.allowedDirectMembers.'Domain Admins')
    $fallback = @(Get-AdminSams | Where-Object { $direct -contains $_ -and $allowed -contains $_ } | Where-Object {
            $u = Find-User $_
            $u -and $u.Enabled
        })
    if (-not $fallback.Count) {
        Write-Report 'tiering.jit.removeStanding is true, but no enabled admin account is a direct member of Domain Admins. No standing admin membership is removed.'
        return $false
    }
    $true
}

# With JIT active, Build does not manage the JIT group's members. A member
# with a time to live is a grant. Any other member is standing admin.
function Sync-JitGroup($Jit) {
    $g = Find-Group $Jit.group
    if (-not $g) { return }
    $full = Get-ADGroup -Identity $g -Properties member -ShowMemberTimeToLive @ad
    foreach ($m in @(Get-Prop $full 'member')) {
        if ("$m" -match '^<TTL=(\d+)>,(.+)$') {
            Write-Log 'INFO' "JIT grant in $($Jit.group): $($Matches[2]), $([math]::Ceiling([int]$Matches[1] / 60)) min left"
            continue
        }
        if ($script:removeStanding) {
            Invoke-Change $Jit.group "Remove standing member $m (JIT is on)" {
                Remove-ADGroupMember -Identity $g -Members "$m" -Confirm:$false @ad
            }
        } else {
            Write-Report "$m is a standing member of $($Jit.group). JIT is on: remove it after a grant is tested (tiering.jit.removeStanding)."
        }
    }
}

# Other groups that give a path to Domain Admins (decision 6 in TIERING.md).
# An admin account in them is reported, or removed when removeStanding is on.
function Sync-StandingGroups($Jit) {
    if (-not (Test-Field $Jit 'standingGroups')) { return }
    $adminSams = Get-AdminSams
    foreach ($name in @($Jit.standingGroups)) {
        $g = Find-Group $name
        if (-not $g) { continue }
        foreach ($m in Get-ADGroupMember -Identity $g @ad) {
            if ($adminSams -notcontains $m.SamAccountName) { continue }
            if ($script:removeStanding) {
                Invoke-Change $name "Remove standing admin $($m.SamAccountName) (JIT is on)" {
                    Remove-ADGroupMember -Identity $g -Members $m -Confirm:$false @ad
                }
            } else {
                Write-Report "$($m.SamAccountName) is a standing member of $name. TIERING.md moves it inside the JIT grant (tiering.jit.removeStanding)."
            }
        }
    }
}

# --- Delegation ----------------------------------------------------------------
# The delegation block gives domain local resource groups rights on OUs, and
# puts explicit deny ACEs on the OUs that hold admin, service and Tier 0
# objects. ACEs are added only when missing. An extra ACE that a person made
# is reported, never removed. No ACE can stop a Domain Admin, so Domain
# Admins stays Tier 0 only.
#
# The ACLs are read and written through the AD: drive of the ActiveDirectory
# module (Get-Acl / Set-Acl), as ansible/ad.yml -t join-delegation does. On a
# DC the drive binds to that DC. Run Build on the PDC emulator.

# Schema GUIDs (Microsoft Learn, adschema).
$guids = @{
    user          = [guid]'bf967aba-0de6-11d0-a285-00aa003049e2'  # class user
    computer      = [guid]'bf967a86-0de6-11d0-a285-00aa003049e2'  # class computer
    resetPassword = [guid]'00299570-246d-11d0-a768-00aa006e0529'  # User-Force-Change-Password
    lockoutTime   = [guid]'28630ebf-41d5-11d1-a9c1-0000f80367c1'  # attribute lockoutTime
    pwdLastSet    = [guid]'bf967a0a-0de6-11d0-a285-00aa003049e2'  # attribute pwdLastSet
    changePassword     = [guid]'ab721a53-1e2f-11d0-9819-00aa0040529b'  # User-Change-Password
    userAccountControl = [guid]'bf967a68-0de6-11d0-a285-00aa003049e2'  # attribute userAccountControl
    employeeID         = [guid]'bf967962-0de6-11d0-a285-00aa003049e2'  # attribute employeeID
    givenName          = [guid]'f0f8ff8e-1191-11d0-a060-00aa006c33ed'  # attribute givenName
    sn                 = [guid]'bf967a41-0de6-11d0-a285-00aa003049e2'  # attribute sn
    displayName        = [guid]'bf967953-0de6-11d0-a285-00aa003049e2'  # attribute displayName
    mail               = [guid]'bf967961-0de6-11d0-a285-00aa003049e2'  # attribute mail
    userPrincipalName  = [guid]'28630ebb-41d5-11d1-a9c1-0000f80367c1'  # attribute userPrincipalName
    none          = [guid]::Empty
}

# ActiveDirectoryRights values, so a mask needs no System.DirectoryServices type.
$adRights = @{
    CreateChild = 1; DeleteChild = 2; ListChildren = 4; Self = 8; ReadProperty = 16; WriteProperty = 32
    DeleteTree = 64; ListObject = 128; ExtendedRight = 256; Delete = 65536; ReadControl = 131072
    WriteDacl = 262144; WriteOwner = 524288; GenericRead = 131220; GenericAll = 983551
}

# What each rights template gives. Inheritance "All": this OU and every
# object below it. "Descendents": only the objects below it, of the class in
# inheritedObjectType.
$rightsTemplates = @{
    # Reset password, unlock, force a change at next logon and read all, on
    # the user objects below the OU. Nothing on the OU itself.
    'user-helpdesk'  = @(
        @{ label = 'reset password'; rights = @('ExtendedRight'); objectType = 'resetPassword'; inheritance = 'Descendents'; inheritedObjectType = 'user' }
        @{ label = 'unlock (lockoutTime)'; rights = @('ReadProperty', 'WriteProperty'); objectType = 'lockoutTime'; inheritance = 'Descendents'; inheritedObjectType = 'user' }
        @{ label = 'change at next logon (pwdLastSet)'; rights = @('ReadProperty', 'WriteProperty'); objectType = 'pwdLastSet'; inheritance = 'Descendents'; inheritedObjectType = 'user' }
        @{ label = 'read all'; rights = @('GenericRead'); objectType = 'none'; inheritance = 'Descendents'; inheritedObjectType = 'user' }
    )
    # Weave on the people that converge.ps1 manages: set a new password
    # (reset), change it, unlock (a reset does not unlock), and read all.
    # Weave writes no other attribute here. converge.ps1 owns the
    # attributes, employeeID too.
    'weave-password' = @(
        @{ label = 'reset password'; rights = @('ExtendedRight'); objectType = 'resetPassword'; inheritance = 'Descendents'; inheritedObjectType = 'user' }
        @{ label = 'change password'; rights = @('ExtendedRight'); objectType = 'changePassword'; inheritance = 'Descendents'; inheritedObjectType = 'user' }
        @{ label = 'unlock (lockoutTime)'; rights = @('ReadProperty', 'WriteProperty'); objectType = 'lockoutTime'; inheritance = 'Descendents'; inheritedObjectType = 'user' }
        @{ label = 'read all'; rights = @('GenericRead'); objectType = 'none'; inheritance = 'Descendents'; inheritedObjectType = 'user' }
    )
    # Weave on Users/Members, which it owns: create user objects, set and
    # change passwords, enable, disable and unlock, and write the attributes
    # it manages. No delete: Weave disables a member.
    'weave-members'  = @(
        @{ label = 'create users'; rights = @('CreateChild'); objectType = 'user'; inheritance = 'All'; inheritedObjectType = 'none' }
        @{ label = 'reset password'; rights = @('ExtendedRight'); objectType = 'resetPassword'; inheritance = 'Descendents'; inheritedObjectType = 'user' }
        @{ label = 'change password'; rights = @('ExtendedRight'); objectType = 'changePassword'; inheritance = 'Descendents'; inheritedObjectType = 'user' }
        @{ label = 'pwdLastSet'; rights = @('ReadProperty', 'WriteProperty'); objectType = 'pwdLastSet'; inheritance = 'Descendents'; inheritedObjectType = 'user' }
        @{ label = 'unlock (lockoutTime)'; rights = @('ReadProperty', 'WriteProperty'); objectType = 'lockoutTime'; inheritance = 'Descendents'; inheritedObjectType = 'user' }
        @{ label = 'enable and disable (userAccountControl)'; rights = @('ReadProperty', 'WriteProperty'); objectType = 'userAccountControl'; inheritance = 'Descendents'; inheritedObjectType = 'user' }
        @{ label = 'employeeID'; rights = @('ReadProperty', 'WriteProperty'); objectType = 'employeeID'; inheritance = 'Descendents'; inheritedObjectType = 'user' }
        @{ label = 'givenName'; rights = @('ReadProperty', 'WriteProperty'); objectType = 'givenName'; inheritance = 'Descendents'; inheritedObjectType = 'user' }
        @{ label = 'sn'; rights = @('ReadProperty', 'WriteProperty'); objectType = 'sn'; inheritance = 'Descendents'; inheritedObjectType = 'user' }
        @{ label = 'displayName'; rights = @('ReadProperty', 'WriteProperty'); objectType = 'displayName'; inheritance = 'Descendents'; inheritedObjectType = 'user' }
        @{ label = 'mail'; rights = @('ReadProperty', 'WriteProperty'); objectType = 'mail'; inheritance = 'Descendents'; inheritedObjectType = 'user' }
        @{ label = 'userPrincipalName'; rights = @('ReadProperty', 'WriteProperty'); objectType = 'userPrincipalName'; inheritance = 'Descendents'; inheritedObjectType = 'user' }
        @{ label = 'read all'; rights = @('GenericRead'); objectType = 'none'; inheritance = 'Descendents'; inheritedObjectType = 'user' }
    )
    # Create and delete computer objects in the OU and its child OUs, and full
    # control of each computer object below it (reset password, DNS host
    # name, SPN and the rest).
    'computer-admin' = @(
        @{ label = 'create and delete computers'; rights = @('CreateChild', 'DeleteChild'); objectType = 'computer'; inheritance = 'All'; inheritedObjectType = 'none' }
        @{ label = 'full control of computers'; rights = @('GenericAll'); objectType = 'none'; inheritance = 'Descendents'; inheritedObjectType = 'computer' }
    )
    # The deny on admin, service and Tier 0 OUs, for the OU and everything
    # below it. Read stays allowed. An explicit deny on a child OU beats an
    # allow inherited from the parent OU (Servers -> Servers/Tier0).
    'deny-write'     = @(
        @{ label = 'deny reset password and every extended right'; rights = @('ExtendedRight'); objectType = 'none'; inheritance = 'All'; inheritedObjectType = 'none' }
        @{ label = 'deny write, create, delete, permissions and owner'
            rights = @('WriteProperty', 'Self', 'CreateChild', 'DeleteChild', 'Delete', 'DeleteTree', 'WriteDacl', 'WriteOwner')
            objectType = 'none'; inheritance = 'All'; inheritedObjectType = 'none' }
    )
}

$inheritanceFlags = @{
    All         = @('ContainerInherit', 'None')
    Descendents = @('ContainerInherit', 'InheritOnly')
}

function Get-Delegation {
    if (-not $data.PSObject.Properties['delegation']) { return $null }
    $data.delegation
}

# The objectSid of a principal (a SecurityIdentifier from AD), or $null.
function Get-PrincipalSid([string]$Sam) {
    if (Test-GroupConflict $Sam) { return $null }
    # A managed group with former names: only Find-Group, so a user or a
    # computer with the same name never gets the group's ACEs.
    $o = if ($script:formerNames.ContainsKey($Sam)) { Find-Group $Sam } else { Find-Object "SamAccountName -eq '$Sam'" }
    if (-not $o) { return $null }
    Get-Prop (Get-ADObject -Identity $o.DistinguishedName -Properties objectSid @ad) 'objectSid'
}

# The wanted rules of one template for one principal, as plain objects.
function Get-WantedRules([string]$Sid, [string]$Template, [string]$Type) {
    foreach ($r in $rightsTemplates[$Template]) {
        $inh, $prop = $inheritanceFlags[$r.inheritance]
        $mask = 0
        foreach ($n in $r.rights) { $mask = $mask -bor $adRights[$n] }
        [pscustomobject]@{
            Sid = $Sid; Type = $Type; Mask = $mask; Label = $r.label
            ObjectType = $guids[$r.objectType]; InheritedObjectType = $guids[$r.inheritedObjectType]
            InheritanceFlags = $inh; PropagationFlags = $prop
        }
    }
}

# Same principal, type, object types and inheritance as the wanted rule.
function Test-SameAceKey($Ace, $Want) {
    "$($Ace.IdentityReference.Value)" -eq $Want.Sid -and
    "$($Ace.AccessControlType)" -eq $Want.Type -and
    "$($Ace.ObjectType)" -eq "$($Want.ObjectType)" -and
    "$($Ace.InheritedObjectType)" -eq "$($Want.InheritedObjectType)" -and
    "$($Ace.InheritanceFlags)" -eq $Want.InheritanceFlags -and
    "$($Ace.PropagationFlags)" -eq $Want.PropagationFlags
}

function Get-AclPath([string]$DN) { "AD:\$DN" }

function Get-ExplicitAces($Acl) {
    @($Acl.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier]))
}

# SID -> a readable name for a report line.
function Get-SidName([string]$Sid) {
    $o = Find-Object "objectSid -eq '$Sid'"
    if ($o -and (Get-Prop $o 'SamAccountName')) { return "$($o.SamAccountName) ($Sid)" }
    $Sid
}

# Adds the missing rules of one template for one principal on one OU, with
# one Set-Acl. Returns the wanted rules, for the extra-ACE report.
function Sync-Aces([string]$DN, [string]$Principal, [string]$Template, [string]$Type) {
    if (Test-GroupConflict $Principal) {
        Write-Report "$Type $Template for $Principal was not checked on ${DN}: $Principal has a rename conflict (see above)."
        return
    }
    $sidObj = Get-PrincipalSid $Principal
    if (-not $sidObj) {
        if ($WhatIfPreference) {
            Write-Log 'WOULD' "$Type $Template for $Principal : $DN (after it is created)"
        } else {
            Write-Report "$Principal does not exist, so $Template was not set on $DN."
        }
        return
    }
    $wanted = @(Get-WantedRules "$sidObj" $Template $Type)
    if (-not (Test-DN $DN)) {
        Write-Log 'WOULD' "$Type $Template for $Principal : $DN (after the OU is created)"
        return $wanted
    }
    $acl = Get-Acl -Path (Get-AclPath $DN)
    $have = Get-ExplicitAces $acl
    $missing = @($wanted | Where-Object {
            $w = $_
            -not ($have | Where-Object { (Test-SameAceKey $_ $w) -and (([int]$_.ActiveDirectoryRights -band $w.Mask) -eq $w.Mask) })
        })
    if ($missing.Count) {
        Invoke-Change $DN "$Type for ${Principal}: $(($missing | ForEach-Object { $_.Label }) -join ', ')" {
            foreach ($m in $missing) {
                $acl.AddAccessRule($acl.AccessRuleFactory($sidObj, [int]$m.Mask, $false, $m.InheritanceFlags, $m.PropagationFlags,
                        $m.Type, $m.ObjectType, $m.InheritedObjectType))
            }
            Set-Acl -Path (Get-AclPath $DN) -AclObject $acl
        }
    }
    $wanted
}

# Principals with explicit ACEs on a new OU by default (the schema default
# security descriptor), or that are Tier 0 anyway.
function Get-DefaultAceSids {
    $d = "$($domain.DomainSID)"
    @('S-1-5-18', 'S-1-5-10', 'S-1-3-0', 'S-1-5-9', 'S-1-5-32-544', 'S-1-5-32-548', 'S-1-5-32-550', "$d-512", "$d-516", "$d-519")
}

# Reports each explicit allow ACE that gives more than read, unless
# converge.ps1 manages it, a default principal holds it, or
# delegation.knownAces lists its principal for this OU.
function Write-ExtraAceReport([string]$DN, [object[]]$Wanted, [string[]]$KnownSids) {
    if (-not (Test-DN $DN)) { return }
    $defaults = Get-DefaultAceSids
    foreach ($ace in Get-ExplicitAces (Get-Acl -Path (Get-AclPath $DN))) {
        if ("$($ace.AccessControlType)" -ne 'Allow') { continue }
        $sid = "$($ace.IdentityReference.Value)"
        if ($defaults -contains $sid -or $KnownSids -contains $sid) { continue }
        $mask = [int]$ace.ActiveDirectoryRights
        if (($mask -band (-bnot $adRights.GenericRead)) -eq 0) { continue }
        # $Wanted is $null when every principal on the OU was skipped.
        $same = @($Wanted | Where-Object { $null -ne $_ -and (Test-SameAceKey $ace $_) })
        $allowed = 0
        foreach ($w in $same) { $allowed = $allowed -bor $w.Mask }
        if ($same.Count -and ($mask -band (-bnot $allowed)) -eq 0) { continue }
        Write-Report "$DN has an extra ACE: allow $($ace.ActiveDirectoryRights) for $(Get-SidName $sid) (object $($ace.ObjectType), inherited object $($ace.InheritedObjectType)). It stays. Remove it by hand if nobody needs it."
    }
}

function Sync-Delegation {
    $del = Get-Delegation
    if (-not $del) { return }
    $wantedByOU = @{}
    $pairs = @()
    foreach ($g in @($del.grants)) {
        # A grant names a domain local group (AGDLP), or one service account
        # ("principal") whose rights belong to that one integration.
        $who = if (Test-Field $g 'group') { $g.group } else { $g.principal }
        foreach ($ou in @($g.ous)) { $pairs += , @((ConvertTo-OUDN $ou), $who, $g.rights, 'Allow') }
    }
    foreach ($d in @($del.deny)) {
        foreach ($ou in @($d.ous)) {
            foreach ($p in @($d.principals)) { $pairs += , @((ConvertTo-OUDN $ou), $p, 'deny-write', 'Deny') }
        }
    }
    foreach ($pair in $pairs) {
        $dn, $principal, $template, $type = $pair
        $w = @(Sync-Aces $dn $principal $template $type)
        if (-not $wantedByOU.ContainsKey($dn)) { $wantedByOU[$dn] = @() }
        $wantedByOU[$dn] += $w
    }

    # Extra ACEs: each OU in the block, and the Domain Controllers OU.
    $paths = @(@($del.grants | ForEach-Object { $_.ous }) + @($del.deny | ForEach-Object { $_.ous }) + @($del.noDelegation))
    $scan = @($paths | Sort-Object -Unique | ForEach-Object { ConvertTo-OUDN $_ }) + "OU=Domain Controllers,$domainDN"
    foreach ($dn in $scan) {
        $known = @()
        foreach ($k in @(if (Test-Field $del 'knownAces') { $del.knownAces })) {
            if (@($k.ous | ForEach-Object { ConvertTo-OUDN $_ }) -contains $dn) {
                $s = Get-PrincipalSid $k.principal
                if ($s) { $known += "$s" }
            }
        }
        $wanted = if ($wantedByOU.ContainsKey($dn)) { $wantedByOU[$dn] } else { @() }
        Write-ExtraAceReport $dn $wanted $known
    }
}

# Report only. SDProp copies the ACL of CN=AdminSDHolder to each protected
# account (adminCount=1) every 60 minutes, so a delegation on an OU never
# reaches them. This checks that the expected accounts are protected, lists
# protected accounts that org.json does not expect, and reports each ACE on
# AdminSDHolder from a principal that is not there by default.
function Test-AdminSDHolder {
    $del = Get-Delegation
    if (-not $del) { return }
    $d = "$($domain.DomainSID)"
    $expected = @(if (Test-Field $del 'expectAdminCount') { $del.expectAdminCount })
    $protected = @(Get-ADUser -Filter 'adminCount -eq 1' @ad)
    $protectedSams = @($protected | ForEach-Object { $_.SamAccountName })
    foreach ($sam in $expected | Where-Object { $protectedSams -notcontains $_ }) {
        Write-Report "$sam has no adminCount=1. SDProp has not protected it yet, or it is not in a protected group."
    }
    foreach ($u in $protected | Where-Object { $expected -notcontains $_.SamAccountName }) {
        # The built-in Administrator and krbtgt are protected by design.
        if (@("$d-500", "$d-502") -contains "$($u.SID)") { continue }
        Write-Report "$($u.SamAccountName) has adminCount=1, but delegation.expectAdminCount does not list it. If it left the protected groups, its ACL inheritance is still off, so no delegated right reaches it. A Domain Admin can clear adminCount and turn inheritance on again."
    }

    $holder = "CN=AdminSDHolder,CN=System,$domainDN"
    if (-not (Test-DN $holder)) {
        Write-Report "$holder was not found."
        return
    }
    $default = @('S-1-1-0', 'S-1-5-9', 'S-1-5-10', 'S-1-5-11', 'S-1-5-18', 'S-1-5-32-544', 'S-1-5-32-554', 'S-1-5-32-560',
        'S-1-5-32-561', "$d-512", "$d-517", "$d-519", "$d-526", "$d-527", "$d-553")
    foreach ($ace in Get-ExplicitAces (Get-Acl -Path (Get-AclPath $holder))) {
        $sid = "$($ace.IdentityReference.Value)"
        if ($default -contains $sid) { continue }
        Write-Report "AdminSDHolder has a non-default ACE: $($ace.AccessControlType) $($ace.ActiveDirectoryRights) for $(Get-SidName $sid). SDProp copies it to every protected account. Check it."
    }

    $ao = Find-Group 'Account Operators'
    if ($ao) {
        $members = @(Get-ADGroupMember -Identity $ao @ad | ForEach-Object { $_.SamAccountName })
        if ($members.Count) {
            Write-Report "Account Operators has members ($($members -join ', ')). By default it can create and delete accounts in every OU. Keep it empty."
        }
    }
}

function Invoke-Build {
    # First, so every lookup below knows the renames and the conflicts.
    Initialize-GroupNames
    $daPathsAtStart = @(Get-DomainAdminPaths)
    $jit = Get-Jit
    $script:jitActive = Test-JitActive
    $script:removeStanding = Test-RemoveStanding
    Sync-UpnSuffix

    Sync-OU $rootDN 'Patchwork Labs inc.'
    foreach ($ou in $data.ous | Sort-Object { $_.path.Split('/').Count }) {
        Sync-OU (ConvertTo-OUDN $ou.path) $ou.description
    }

    foreach ($g in $data.roleGroups) { Sync-Group $g.name $g.description 'Global' 'Groups/Roles' }
    foreach ($g in Get-ResourceGroups) { Sync-Group $g.name $g.description 'DomainLocal' 'Groups/Resources' }

    # Managers first, so their DN exists when a report line names them.
    foreach ($u in $data.users) { Sync-User $u }

    foreach ($g in $data.roleGroups) {
        if ($g.PSObject.Properties['manageMembers'] -and -not $g.manageMembers) { continue }
        # With JIT active, the members of the JIT group are grants.
        if ($script:jitActive -and $g.name -eq $jit.group) { continue }
        Sync-Members $g.name @($g.members)
    }
    Test-HostGroupMembers
    foreach ($g in Get-ResourceGroups) { Sync-Members $g.name @($g.members) }
    Remove-RetiredHostGroups

    Sync-PasswordPolicies
    Sync-Privileged $daPathsAtStart
    Sync-BuiltinAdministrator
    if ($jit) {
        if ($script:jitActive) { Sync-JitGroup $jit }
        Sync-StandingGroups $jit
    }
    Sync-Tiering
    Sync-Delegation
    Test-AdminSDHolder
}

# --- Migrate -----------------------------------------------------------------
# Destination for one object in the old tree, as a new-tree OU path, or $null.
function Get-Destination($obj) {
    $parent = Get-ParentDN $obj.DistinguishedName
    $oldPath = ''
    if ($parent -ne $oldRootDN) {
        $rel = $parent.Substring(0, $parent.Length - $oldRootDN.Length - 1)
        $parts = $rel -split '(?<!\\),' | ForEach-Object { $_ -replace '^OU=', '' }
        [array]::Reverse($parts)
        $oldPath = $parts -join '/'
    }
    $samProp = $obj.PSObject.Properties['sAMAccountName']
    $sam = if ($samProp) { $samProp.Value } else { $null }
    switch ($obj.ObjectClass) {
        'user' {
            $u = $data.users | Where-Object { $_.sam -eq $sam }
            if ($u) { return $u.ou }
            if ($oldPath -eq 'Members') { return 'Users/Members' }
            return $null
        }
        'group' {
            # Also by a former name: Build renames the group later.
            $isGroup = { param($g) $g.name -eq $sam -or ($g.PSObject.Properties['formerNames'] -and @($g.formerNames) -contains $sam) }
            if ($data.roleGroups | Where-Object { & $isGroup $_ }) { return 'Groups/Roles' }
            if (Get-ResourceGroups | Where-Object { & $isGroup $_ }) { return 'Groups/Resources' }
            if ($oldPath -like 'Security-Groups/*') { return 'Groups/Resources' }
            return $null
        }
        'computer' {
            $t = if ($data.PSObject.Properties['tiering']) { $data.tiering } else { $null }
            if ($t -and (Test-Field $t 'serverOU') -and $sam -and @($t.computers) -contains $sam.TrimEnd('$')) { return $t.serverOU }
            if ($oldPath -like '*Computers*') { return 'Computers' }
            return 'Servers'
        }
    }
    $null
}

function Copy-GPLinks {
    if (-not (Get-Module -ListAvailable GroupPolicy)) {
        Write-Report 'The GroupPolicy module is missing. GPO links were not copied. Install GPMC and run Migrate again.'
        return
    }
    Import-Module GroupPolicy
    foreach ($entry in $data.migration.ouMap) {
        $from = ConvertTo-OUDN $entry.from $oldRootDN
        $to = ConvertTo-OUDN $entry.to
        if (-not (Test-DN $from)) { continue }
        $have = @((Get-GPInheritance -Target $to -Domain $data.domain -Server $Server).GpoLinks | ForEach-Object { $_.GpoId })
        foreach ($link in (Get-GPInheritance -Target $from -Domain $data.domain -Server $Server).GpoLinks) {
            if ($have -contains $link.GpoId) { continue }
            Invoke-Change $to "Link GPO '$($link.DisplayName)' (from $from)" {
                New-GPLink -Guid $link.GpoId -Target $to -Domain $data.domain -Server $Server `
                    -LinkEnabled $(if ($link.Enabled) { 'Yes' } else { 'No' }) `
                    -Enforced $(if ($link.Enforced) { 'Yes' } else { 'No' }) | Out-Null
            }
        }
    }
}

function Invoke-Migrate {
    foreach ($ou in $data.ous) {
        if (-not (Test-DN (ConvertTo-OUDN $ou.path))) {
            throw "OU $($ou.path) does not exist. Run Build without -WhatIf first."
        }
    }
    if (-not (Test-DN $oldRootDN)) {
        Write-Log 'INFO' "$oldRootDN does not exist. Nothing to migrate."
        return
    }

    Copy-GPLinks

    $objects = Get-ADObject -SearchBase $oldRootDN -SearchScope Subtree @ad `
        -Filter "objectClass -ne 'organizationalUnit'" -Properties sAMAccountName, ProtectedFromAccidentalDeletion
    foreach ($obj in $objects) {
        $dest = Get-Destination $obj
        if ($null -eq $dest) {
            Write-Report "No destination for $($obj.ObjectClass) $($obj.DistinguishedName). Add it to org.json, then run Migrate again."
            continue
        }
        $target = ConvertTo-OUDN $dest

        if ($obj.ObjectClass -eq 'group' -and $dest -eq 'Groups/Resources') {
            $g = Get-ADGroup -Identity $obj @ad
            if ("$($g.GroupScope)" -eq 'Global') {
                # AD has no direct Global -> DomainLocal change.
                Invoke-Change $obj.DistinguishedName 'Convert scope Global -> Universal -> DomainLocal' {
                    Set-ADGroup -Identity $g -GroupScope Universal @ad
                    Set-ADGroup -Identity $g -GroupScope DomainLocal @ad
                }
            }
        }

        $protected = [bool]$obj.ProtectedFromAccidentalDeletion
        Invoke-Change $obj.DistinguishedName "Move to $target" {
            if ($protected) { Set-ADObject -Identity $obj -ProtectedFromAccidentalDeletion $false @ad }
            $moved = Move-ADObject -Identity $obj -TargetPath $target -PassThru @ad
            if ($protected) { Set-ADObject -Identity $moved -ProtectedFromAccidentalDeletion $true @ad }
        }
    }
}

# --- Prune -------------------------------------------------------------------
function Invoke-Prune {
    if (-not (Test-DN $oldRootDN)) {
        Write-Log 'INFO' "$oldRootDN does not exist. Nothing to prune."
        return
    }
    $left = @(Get-ADObject -SearchBase $oldRootDN -SearchScope Subtree @ad `
            -Filter "objectClass -ne 'organizationalUnit'")
    if ($left.Count) {
        foreach ($o in $left) { Write-Report "Still in the old tree: $($o.DistinguishedName)" }
        throw "Refusing to prune: $($left.Count) objects are still in $oldRootDN. Run Migrate and handle the reports first."
    }
    # Deepest first, so each OU is empty when it is deleted.
    $ous = Get-ADOrganizationalUnit -SearchBase $oldRootDN -SearchScope Subtree -Filter * @ad |
        Sort-Object { ($_.DistinguishedName -split '(?<!\\),').Count } -Descending
    foreach ($ou in $ous) {
        Invoke-Change $ou.DistinguishedName 'Delete empty OU' {
            Set-ADObject -Identity $ou -ProtectedFromAccidentalDeletion $false @ad
            Remove-ADOrganizationalUnit -Identity $ou -Confirm:$false @ad
        }
    }
}

# --- Main --------------------------------------------------------------------
Write-Log 'START' "Phase $Phase against $Server ($($data.domain))$(if ($WhatIfPreference) { ', -WhatIf' })"
switch ($Phase) {
    'Build' { Invoke-Build }
    'Migrate' { Invoke-Migrate }
    'Prune' { Invoke-Prune }
}
Write-Log 'END' "$script:changeCount changes, $script:reportCount reports, $script:errorCount errors. Log: $logFile"
if ($script:errorCount) { exit 1 }
