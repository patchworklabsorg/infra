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
    in org.json is enabled and is in Domain Admins.

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
        userPrincipalName, mail, Enabled, ProtectedFromAccidentalDeletion
}

function Find-UserByUpn([string]$Upn) {
    Get-ADUser -Filter "UserPrincipalName -eq '$Upn'" @ad
}

# The UPN that org.json manages for an entry, or $null. "upn" is the part
# before the @. It defaults to "sam".
function Get-WantedUpn($u) {
    $local = if (Test-Field $u 'upn') { $u.upn } else { $u.sam }
    $create = -not ($u.PSObject.Properties['create'] -and -not $u.create)
    switch ($u.kind) {
        'person' { return "$local@$($data.upnSuffix)" }
        'admin' { if ($create) { return "$local@$($data.domain)" } }
        # A service account gets a UPN only when org.json sets "upn", for
        # example to match a Workspace address.
        'service' { if (Test-Field $u 'upn') { return "$local@$($data.upnSuffix)" } }
    }
    $null
}

function Find-Group([string]$Name) {
    Get-ADGroup -Filter "SamAccountName -eq '$Name'" @ad -Properties Description, ProtectedFromAccidentalDeletion
}

function Test-DN([string]$DN) {
    [bool](Find-Object "distinguishedName -eq '$DN'")
}

$unmanagedOUs = @($data.ous | Where-Object { $_.PSObject.Properties['managed'] -and -not $_.managed } |
        ForEach-Object { ConvertTo-OUDN $_.path })

function Test-InUnmanagedOU([string]$DN) {
    foreach ($ou in $unmanagedOUs) { if ($DN -like "*,$ou") { return $true } }
    $false
}

# A key that is absent is not managed. A key set to null clears the attribute.
function Test-Field($Object, [string]$Name) {
    [bool]$Object.PSObject.Properties[$Name]
}

# Every resource group, with {host} expanded for each Linux host.
function Get-ResourceGroups {
    foreach ($h in $data.linuxHosts) {
        foreach ($t in $data.hostGroups) {
            [pscustomobject]@{
                name        = $t.name.Replace('{host}', $h)
                description = $t.description.Replace('{host}', $h)
                members     = @($t.members)
            }
        }
    }
    foreach ($g in $data.resourceGroups) { $g }
}

# --- Build: pieces -----------------------------------------------------------
function Sync-UpnSuffix {
    $forest = Get-ADForest @ad
    if ($forest.UPNSuffixes -notcontains $data.upnSuffix) {
        Invoke-Change $forest.Name "Add UPN suffix $($data.upnSuffix)" {
            Set-ADForest -Identity $forest -UPNSuffixes @{ Add = $data.upnSuffix } @ad
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
    $g = Find-Group $Name
    $target = ConvertTo-OUDN $OUPath
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
    $g = Find-Group $Group
    if (-not $g) {
        if ($Desired.Count) {
            Write-Log 'WOULD' "Add $($Desired -join ', ') : $Group (after it is created)"
        }
        return
    }
    $current = @(Get-ADGroupMember -Identity $g @ad | ForEach-Object { $_.SamAccountName })
    foreach ($m in $Desired | Where-Object { $current -notcontains $_ }) {
        # Under -WhatIf a new user does not exist yet. In a real run a missing
        # member is a user that Sync-User skipped.
        if (-not $WhatIfPreference -and -not (Find-User $m) -and -not (Find-Group $m)) {
            Write-Report "$m does not exist, so it was not added to $Group. Read the reports for $m above."
            continue
        }
        Invoke-Change $Group "Add member $m" { Add-ADGroupMember -Identity $g -Members $m @ad }
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

    if ((Get-ParentDN $existing.DistinguishedName) -ne $target) {
        Write-Report "$($u.sam) is in $(Get-ParentDN $existing.DistinguishedName), not $target. Migrate moves it."
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
    if ($tier0) {
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

    foreach ($name in $p.groups) {
        $g = Get-ADGroup -Identity $name @ad
        $allowed = @($p.allowedDirectMembers.$name)
        foreach ($m in Get-ADGroupMember -Identity $g @ad) {
            if ($people -contains $m.SamAccountName) {
                if ($adminsReady) {
                    Invoke-Change $name "Remove daily account $($m.SamAccountName)" {
                        Remove-ADGroupMember -Identity $g -Members $m -Confirm:$false @ad
                    }
                } else {
                    Write-Report "$($m.SamAccountName) is in $name. It stays until every admin account is enabled and had a Domain Admins path before the run."
                }
            } elseif ($allowed -notcontains $m.SamAccountName) {
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
    $current = @()
    if ($Pso) {
        $current = @(Get-ADFineGrainedPasswordPolicySubject -Identity $Pso @ad | ForEach-Object { $_.SamAccountName })
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
    $sid = "$($domain.DomainSID)-500"
    $acct = Get-ADUser -Identity $sid @ad
    $label = "built-in Administrator $($acct.SamAccountName) ($sid)"
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

function Invoke-Build {
    $daPathsAtStart = @(Get-DomainAdminPaths)
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
        Sync-Members $g.name @($g.members)
    }
    foreach ($g in Get-ResourceGroups) { Sync-Members $g.name @($g.members) }
    Remove-RetiredHostGroups

    Sync-PasswordPolicies
    Sync-Privileged $daPathsAtStart
    Sync-BuiltinAdministrator
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
            if ($data.roleGroups | Where-Object { $_.name -eq $sam }) { return 'Groups/Roles' }
            if (Get-ResourceGroups | Where-Object { $_.name -eq $sam }) { return 'Groups/Resources' }
            if ($oldPath -like 'Security-Groups/*') { return 'Groups/Resources' }
            return $null
        }
        'computer' {
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
