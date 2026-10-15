# In-memory stand-in for the ActiveDirectory module, for tests/ad/run.ps1.
# It implements only the cmdlets and the filter forms that ad/converge.ps1
# uses, and it enforces the AD rules the script depends on: a parent must
# exist, a protected object cannot move or be deleted, an OU with children
# cannot be deleted, Global cannot change straight to DomainLocal, a PSO
# applies only to global groups and users, and a lockout observation window
# cannot be longer than the lockout duration. For tiering: an account must
# have access to a silo before the silo is assigned to it, a member with a
# time to live needs the PAM optional feature, and the RID 500 account
# cannot be a silo member in a way that matters (the test checks the
# script never tries).
#
# ACLs: Get-Acl and Set-Acl on "AD:\<dn>" paths. An object keeps only its
# explicit ACEs. A fake security object has the methods converge.ps1 uses
# (GetAccessRules, AccessRuleFactory, AddAccessRule), because the real
# System.DirectoryServices ACL types do not work outside Windows. A new OU
# gets the default ACEs of the schema (SYSTEM, Domain Admins, Account
# Operators, Authenticated Users read).

$script:domainDN = 'DC=patchwork,DC=internal'
$script:domainSid = 'S-1-5-21-1111111111-2222222222-3333333333'
$script:objects = [System.Collections.Generic.List[object]]::new()
$script:upnSuffixes = [System.Collections.Generic.List[string]]::new()
$script:psos = [System.Collections.Generic.List[object]]::new()
$script:defaultPolicy = $null
$script:pamEnabled = $false
$script:nextRid = 1100
$script:configDN = "CN=Configuration,$script:domainDN"
$script:policyBase = "CN=AuthN Policies,CN=AuthN Policy Configuration,CN=Services,$script:configDN"
$script:siloBase = "CN=AuthN Silos,CN=AuthN Policy Configuration,CN=Services,$script:configDN"

$policyParams = 'MinPasswordLength', 'PasswordHistoryCount', 'ComplexityEnabled', 'ReversibleEncryptionEnabled',
'MinPasswordAge', 'MaxPasswordAge', 'LockoutThreshold', 'LockoutDuration', 'LockoutObservationWindow'

# The values a new domain (and a new PSO) gets.
function New-PolicyDefaults {
    [ordered]@{
        MinPasswordLength = 7; PasswordHistoryCount = 24; ComplexityEnabled = $true; ReversibleEncryptionEnabled = $false
        MinPasswordAge = [TimeSpan]::FromDays(1); MaxPasswordAge = [TimeSpan]::FromDays(42)
        LockoutThreshold = 0; LockoutDuration = [TimeSpan]::FromMinutes(10); LockoutObservationWindow = [TimeSpan]::FromMinutes(10)
    }
}

$userAttrs = 'company', 'division', 'department', 'title', 'givenName', 'sn', 'displayName',
'manager', 'userPrincipalName', 'mail'

function Reset-FakeAD {
    $script:objects.Clear()
    $script:upnSuffixes.Clear()
    $script:psos.Clear()
    $script:defaultPolicy = New-PolicyDefaults
    $script:pamEnabled = $false
    $script:nextRid = 1100
}

# An operator running Enable-ADOptionalFeature for PAM.
function Enable-FakePam { $script:pamEnabled = $true }

# An operator enabling an account after the person set a password.
function Enable-FakeUser([string]$Sam) { (Find-Fake $Sam).Enabled = $true }

function Get-FakeADState {
    # Deep enough copy to compare before and after a -WhatIf run.
    ($script:objects | ForEach-Object {
        $o = $_
        '{0}|{1}|{2}|{3}|{4}|{5}|{6}' -f $o.DN, $o.Class, $o.Enabled, $o.Scope, $o.Protected,
            (($o.Attrs.GetEnumerator() | Sort-Object Key | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ';'),
            (($o.Members | Sort-Object | ForEach-Object { if ($o.Ttl.ContainsKey($_)) { "$_<TTL>" } else { "$_" } }) -join ';')
    }) + ($script:objects | Where-Object { $_.Acl.Count } | ForEach-Object { "ACL $($_.DN)|$(($_.Acl | ForEach-Object { Format-FakeAce $_ }) -join ';')" }) + ($script:upnSuffixes -join ';') + (Format-FakePolicy $script:defaultPolicy) + ($script:psos | ForEach-Object {
        "PSO $($_.Name)|$($_.Precedence)|$($_.Description)|$(Format-FakePolicy $_.Policy)|$(($_.Subjects | Sort-Object) -join ';')"
    }) -join "`n"
}

function Format-FakePolicy($Policy) {
    ($Policy.Keys | ForEach-Object { "$_=$($Policy[$_])" }) -join ';'
}

function Add-FakeObject([string]$DN, [string]$Class, [hashtable]$Extra = @{}) {
    $o = [pscustomobject]@{
        Id = [guid]::NewGuid(); DN = $DN; Class = $Class; Sam = $null; Sid = $null; Enabled = $true
        Scope = $null; Protected = $false; Description = $null; Attrs = @{}
        Members = [System.Collections.Generic.List[guid]]::new(); Ttl = @{}
        Acl = [System.Collections.Generic.List[object]]::new()
    }
    foreach ($k in $Extra.Keys) { $o.$k = $Extra[$k] }
    if (-not $o.Sid -and $Class -in 'user', 'group', 'computer') { $o.Sid = "$script:domainSid-$($script:nextRid)"; $script:nextRid++ }
    $script:objects.Add($o)
    $o
}

function Get-ParentOf([string]$DN) { ($DN -split '(?<!\\),', 2)[1] }
function Get-RdnValue([string]$DN) { (($DN -split '(?<!\\),', 2)[0] -split '=', 2)[1] }

function Find-Fake($Identity) {
    if ($null -eq $Identity) { throw 'Identity is null' }
    if ($Identity -is [psobject] -and $Identity.PSObject.Properties['ObjectGUID']) {
        $id = $Identity.ObjectGUID
        $o = $script:objects | Where-Object { $_.Id -eq $id }
    } else {
        $s = "$Identity"
        $o = $script:objects | Where-Object { $_.DN -eq $s -or $_.Sam -eq $s -or ($_.Sid -and $_.Sid -eq $s) -or (Get-RdnValue $_.DN) -eq $s } |
            Select-Object -First 1
    }
    if (-not $o) { throw "Cannot find an object with identity: '$Identity'" }
    $o
}

function ConvertTo-Fake($o) {
    $h = [ordered]@{
        ObjectGUID = $o.Id; DistinguishedName = $o.DN; ObjectClass = $o.Class; Name = (Get-RdnValue $o.DN)
        SamAccountName = $o.Sam; SID = $o.Sid; objectSid = $o.Sid; Enabled = $o.Enabled
        GroupScope = $o.Scope; Description = $o.Description; ProtectedFromAccidentalDeletion = $o.Protected
    }
    foreach ($a in $userAttrs) { $h[$a] = $o.Attrs[$a] }
    foreach ($k in $o.Attrs.Keys) { if (-not $h.Contains($k)) { $h[$k] = $o.Attrs[$k] } }
    [pscustomobject]$h
}

function Select-Fake([string]$Filter, [string]$SearchBase, [string[]]$Classes) {
    $set = $script:objects | Where-Object { -not $Classes -or $Classes -contains $_.Class }
    if ($SearchBase) { $set = $set | Where-Object { $_.DN -eq $SearchBase -or $_.DN -like "*,$SearchBase" } }
    if ($Filter -eq '*') { return $set }
    if ($Filter -notmatch "^(\w+) -(eq|ne) '(.*)'$" -and $Filter -notmatch '^(\w+) -(eq|ne) (\d+)$') { throw "Fake AD does not support filter: $Filter" }
    $attr, $op, $value = $Matches[1], $Matches[2], $Matches[3]
    $get = switch ($attr) {
        'SamAccountName' { { param($o) $o.Sam } }
        'distinguishedName' { { param($o) $o.DN } }
        'UserPrincipalName' { { param($o) $o.Attrs['userPrincipalName'] } }
        'objectClass' { { param($o) $o.Class } }
        'Name' { { param($o) Get-RdnValue $o.DN } }
        'objectSid' { { param($o) $o.Sid } }
        'adminCount' { { param($o) "$($o.Attrs['adminCount'])" } }
        default { throw "Fake AD does not support attribute: $attr" }
    }
    if ($op -eq 'eq') { $set | Where-Object { (& $get $_) -eq $value } }
    else { $set | Where-Object { (& $get $_) -ne $value } }
}

function Assert-Parent([string]$Path) {
    if (-not ($script:objects | Where-Object { $_.DN -eq $Path }) -and $Path -ne $script:domainDN) {
        throw "Parent does not exist: $Path"
    }
}

# --- Domain and forest -------------------------------------------------------
function Get-ADDomain { param($Server)
    [pscustomobject]@{ DNSRoot = 'patchwork.internal'; DistinguishedName = $script:domainDN; PDCEmulator = 'loom.patchwork.internal'; DomainSID = $script:domainSid }
}
function Get-ADForest { param($Server)
    [pscustomobject]@{ Name = 'patchwork.internal'; UPNSuffixes = @($script:upnSuffixes) }
}
function Set-ADForest { param($Identity, [hashtable]$UPNSuffixes, $Server)
    foreach ($s in @($UPNSuffixes.Add)) { $script:upnSuffixes.Add($s) }
}

# --- Generic objects ---------------------------------------------------------
function Get-ADObject { param([string]$Filter, $SearchBase, $SearchScope, $Properties, $Server, $Identity)
    # Like the real cmdlet: an empty -Properties fails validation.
    if ($PSBoundParameters.ContainsKey('Properties') -and @($Properties).Count -eq 0) {
        throw "Cannot validate argument on parameter 'Properties'."
    }
    if ($Identity) { return ConvertTo-Fake (Find-Fake $Identity) }
    Select-Fake $Filter $SearchBase | ForEach-Object { ConvertTo-Fake $_ }
}
function Set-ADObject { param($Identity, $ProtectedFromAccidentalDeletion, $Server)
    (Find-Fake $Identity).Protected = [bool]$ProtectedFromAccidentalDeletion
}
function Move-ADObject { param($Identity, [string]$TargetPath, [switch]$PassThru, $Server)
    $o = Find-Fake $Identity
    if ($o.Protected) { throw "Access is denied: $($o.DN) is protected from accidental deletion" }
    Assert-Parent $TargetPath
    $oldDN = $o.DN
    $o.DN = (($o.DN -split '(?<!\\),', 2)[0]) + ',' + $TargetPath
    # manager and the silo member list are linked attributes: AD follows the move.
    foreach ($x in $script:objects) {
        if ($x.Attrs['manager'] -eq $oldDN) { $x.Attrs['manager'] = $o.DN }
        if ($x.Attrs.ContainsKey('msDS-AuthNPolicySiloMembers')) {
            $x.Attrs['msDS-AuthNPolicySiloMembers'] = @($x.Attrs['msDS-AuthNPolicySiloMembers'] | ForEach-Object { if ($_ -eq $oldDN) { $o.DN } else { $_ } })
        }
    }
    if ($PassThru) { ConvertTo-Fake $o }
}

# --- OUs ---------------------------------------------------------------------
function Get-ADOrganizationalUnit { param([string]$Filter, $SearchBase, $SearchScope, $Properties, $Server)
    Select-Fake $Filter $SearchBase @('organizationalUnit') | ForEach-Object { ConvertTo-Fake $_ }
}
function New-ADOrganizationalUnit { param([string]$Name, [string]$Path, $Description, $ProtectedFromAccidentalDeletion, $Server)
    Assert-Parent $Path
    $dn = "OU=$Name,$Path"
    if ($script:objects | Where-Object { $_.DN -eq $dn }) { throw "Already exists: $dn" }
    $o = Add-FakeObject $dn 'organizationalUnit' @{ Description = $Description; Protected = [bool]$ProtectedFromAccidentalDeletion }
    Add-FakeDefaultOUAces $o
}
function Set-ADOrganizationalUnit { param($Identity, $Description, $Server)
    (Find-Fake $Identity).Description = $Description
}
function Remove-ADOrganizationalUnit { param($Identity, $Confirm, $Server)
    $o = Find-Fake $Identity
    if ($o.Protected) { throw "Access is denied: $($o.DN) is protected" }
    if ($script:objects | Where-Object { $_.DN -like "*,$($o.DN)" }) { throw "Not empty: $($o.DN)" }
    $script:objects.Remove($o) | Out-Null
}

# --- Users -------------------------------------------------------------------
function Get-ADUser { param([string]$Filter, $Properties, $Server, $Identity)
    if ($Identity) { return ConvertTo-Fake (Find-Fake $Identity) }
    Select-Fake $Filter $null @('user') | ForEach-Object { ConvertTo-Fake $_ }
}
function New-ADUser { param([string]$Name, [string]$SamAccountName, [string]$Path, $Enabled, $ChangePasswordAtLogon, [hashtable]$OtherAttributes, $AccountPassword, $Server)
    if ($AccountPassword) { throw 'Test: converge.ps1 must never set a password' }
    if (-not $ChangePasswordAtLogon) { throw 'Test: new users must change the password at next logon' }
    # Like the real cmdlet: an empty -OtherAttributes fails validation.
    if ($PSBoundParameters.ContainsKey('OtherAttributes') -and ($null -eq $OtherAttributes -or $OtherAttributes.Count -eq 0)) {
        throw "Cannot validate argument on parameter 'OtherAttributes'."
    }
    if (-not $OtherAttributes) { $OtherAttributes = @{} }
    Assert-Parent $Path
    $upn = $OtherAttributes['userPrincipalName']
    if ($upn -and $script:upnSuffixes -notcontains ($upn -split '@')[1] -and ($upn -split '@')[1] -ne 'patchwork.internal') {
        throw "UPN suffix not registered: $upn"
    }
    $o = Add-FakeObject "CN=$Name,$Path" 'user' @{ Sam = $SamAccountName; Enabled = [bool]$Enabled }
    foreach ($k in $OtherAttributes.Keys) { $o.Attrs[$k] = $OtherAttributes[$k] }
    $o.Attrs['pwdLastSet'] = 0
}
function Set-ADUser { param($Identity, [hashtable]$Replace, [string[]]$Clear, $Server)
    $o = Find-Fake $Identity
    if ($Replace) { foreach ($k in $Replace.Keys) { $o.Attrs[$k] = $Replace[$k] } }
    foreach ($k in @($Clear)) { if ($k) { $o.Attrs.Remove($k) } }
}
function Disable-ADAccount { param($Identity, $Server) (Find-Fake $Identity).Enabled = $false }
function Enable-ADAccount { param($Identity, $Server) (Find-Fake $Identity).Enabled = $true }

# --- Groups ------------------------------------------------------------------
function Get-ADGroup { param([string]$Filter, $Properties, $Server, $Identity, [switch]$ShowMemberTimeToLive)
    if ($Identity) {
        $o = Find-Fake $Identity
        $g = ConvertTo-Fake $o
        if (@($Properties) -contains 'member') {
            $list = foreach ($id in $o.Members) {
                $dn = ($script:objects | Where-Object { $_.Id -eq $id }).DN
                if ($ShowMemberTimeToLive -and $o.Ttl.ContainsKey($id)) { "<TTL=$($o.Ttl[$id])>,$dn" } else { $dn }
            }
            $g | Add-Member -NotePropertyName member -NotePropertyValue @($list)
        }
        return $g
    }
    Select-Fake $Filter $null @('group') | ForEach-Object { ConvertTo-Fake $_ }
}
function New-ADGroup { param([string]$Name, [string]$SamAccountName, $GroupCategory, [string]$GroupScope, [string]$Path, $Description, $Server)
    Assert-Parent $Path
    Add-FakeObject "CN=$Name,$Path" 'group' @{ Sam = $SamAccountName; Scope = $GroupScope; Description = $Description } | Out-Null
}
function Set-ADGroup { param($Identity, $Description, [string]$GroupScope, $Server)
    $o = Find-Fake $Identity
    if ($PSBoundParameters.ContainsKey('Description')) { $o.Description = $Description }
    if ($GroupScope) {
        if ($o.Scope -eq 'Global' -and $GroupScope -eq 'DomainLocal') { throw 'Global cannot change straight to DomainLocal' }
        $o.Scope = $GroupScope
    }
}
function Remove-ADGroup { param($Identity, $Confirm, $Server)
    $o = Find-Fake $Identity
    if ($o.Protected) { throw "Access is denied: $($o.DN) is protected" }
    foreach ($x in $script:objects) { $x.Members.Remove($o.Id) | Out-Null }
    $script:objects.Remove($o) | Out-Null
}
function Get-ADGroupMember { param($Identity, [switch]$Recursive, $Server)
    $g = Find-Fake $Identity
    if (-not $Recursive) {
        foreach ($id in $g.Members) { ConvertTo-Fake ($script:objects | Where-Object { $_.Id -eq $id }) }
        return
    }
    # Like AD: every user and computer below the group, no groups, no repeats.
    $seen = @{}; $queue = [System.Collections.Generic.Queue[object]]::new(); $queue.Enqueue($g)
    while ($queue.Count) {
        foreach ($id in $queue.Dequeue().Members) {
            if ($seen[$id]) { continue }
            $seen[$id] = $true
            $o = $script:objects | Where-Object { $_.Id -eq $id }
            if ($o.Class -eq 'group') { $queue.Enqueue($o) } else { ConvertTo-Fake $o }
        }
    }
}
function Add-ADGroupMember { param($Identity, $Members, [TimeSpan]$MemberTimeToLive, $Server)
    $g = Find-Fake $Identity
    if ($PSBoundParameters.ContainsKey('MemberTimeToLive') -and -not $script:pamEnabled) { throw 'The parameter is incorrect (PAM feature is off)' }
    foreach ($m in @($Members)) {
        $o = Find-Fake $m
        if ($g.Members -contains $o.Id) { throw "Already a member: $($o.Sam)" }
        $g.Members.Add($o.Id)
        if ($PSBoundParameters.ContainsKey('MemberTimeToLive')) { $g.Ttl[$o.Id] = [int]$MemberTimeToLive.TotalSeconds }
    }
}
function Remove-ADGroupMember { param($Identity, $Members, $Confirm, $Server)
    $g = Find-Fake $Identity
    foreach ($m in @($Members)) { $id = (Find-Fake $m).Id; $g.Members.Remove($id) | Out-Null; $g.Ttl.Remove($id) }
}
function Get-ADPrincipalGroupMembership { param($Identity, $Server)
    $o = Find-Fake $Identity
    $groups = @($script:objects | Where-Object { $_.Class -eq 'group' -and $_.Members -contains $o.Id } | ForEach-Object { ConvertTo-Fake $_ })
    $groups + [pscustomobject]@{ Name = 'Domain Users'; DistinguishedName = "CN=Domain Users,CN=Users,$script:domainDN" }
}

# --- Password policy ---------------------------------------------------------
# AD writes a "never" time as Int64.MinValue, and reads it back that way.
function Set-FakePolicy($Policy, [hashtable]$Bound) {
    foreach ($k in $policyParams) {
        if (-not $Bound.ContainsKey($k)) { continue }
        $v = $Bound[$k]
        if ($v -is [TimeSpan] -and $v.Ticks -eq 0 -and $k -in 'MaxPasswordAge', 'LockoutDuration') { $v = [TimeSpan]::MinValue }
        $Policy[$k] = $v
    }
    $d = $Policy['LockoutDuration']; $w = $Policy['LockoutObservationWindow']
    if ($d.Ticks -gt 0 -and $w -gt $d) { throw 'LockoutObservationWindow cannot be longer than LockoutDuration' }
}

function ConvertTo-FakePolicy($Policy, [hashtable]$Extra = @{}) {
    $h = [ordered]@{}
    foreach ($k in $Extra.Keys) { $h[$k] = $Extra[$k] }
    foreach ($k in $policyParams) { $h[$k] = $Policy[$k] }
    [pscustomobject]$h
}

function Get-ADDefaultDomainPasswordPolicy { param($Identity, $Server)
    ConvertTo-FakePolicy $script:defaultPolicy @{ DistinguishedName = $script:domainDN }
}
function Set-ADDefaultDomainPasswordPolicy { param($Identity, [int]$MinPasswordLength, [int]$PasswordHistoryCount,
        $ComplexityEnabled, $ReversibleEncryptionEnabled, [TimeSpan]$MinPasswordAge, [TimeSpan]$MaxPasswordAge,
        [int]$LockoutThreshold, [TimeSpan]$LockoutDuration, [TimeSpan]$LockoutObservationWindow, $Server)
    Set-FakePolicy $script:defaultPolicy $PSBoundParameters
}

function Find-FakePso($Identity) {
    $o = if ($Identity -is [psobject] -and $Identity.PSObject.Properties['ObjectGUID']) {
        $script:psos | Where-Object { $_.Id -eq $Identity.ObjectGUID }
    } else { $script:psos | Where-Object { $_.Name -eq "$Identity" } }
    if (-not $o) { throw "Cannot find a PSO with identity: '$Identity'" }
    $o
}
function ConvertTo-FakePso($o) {
    ConvertTo-FakePolicy $o.Policy @{
        ObjectGUID = $o.Id; Name = $o.Name; Precedence = $o.Precedence; Description = $o.Description
        DistinguishedName = "CN=$($o.Name),CN=Password Settings Container,CN=System,$script:domainDN"
    }
}
function Get-ADFineGrainedPasswordPolicy { param([string]$Filter, $Identity, $Properties, $Server)
    if ($Identity) { return ConvertTo-FakePso (Find-FakePso $Identity) }
    $set = if ($Filter -eq '*') { $script:psos } elseif ($Filter -match "^Name -eq '(.*)'$") {
        $n = $Matches[1]; $script:psos | Where-Object { $_.Name -eq $n }
    } else { throw "Fake AD does not support PSO filter: $Filter" }
    $set | ForEach-Object { ConvertTo-FakePso $_ }
}
function New-ADFineGrainedPasswordPolicy { param([string]$Name, [int]$Precedence, $Description, $ProtectedFromAccidentalDeletion,
        [int]$MinPasswordLength, [int]$PasswordHistoryCount, $ComplexityEnabled, $ReversibleEncryptionEnabled,
        [TimeSpan]$MinPasswordAge, [TimeSpan]$MaxPasswordAge, [int]$LockoutThreshold, [TimeSpan]$LockoutDuration,
        [TimeSpan]$LockoutObservationWindow, $Server)
    if ($script:psos | Where-Object { $_.Name -eq $Name }) { throw "Already exists: PSO $Name" }
    if (-not $PSBoundParameters.ContainsKey('Precedence')) { throw 'Precedence is required' }
    $o = [pscustomobject]@{ Id = [guid]::NewGuid(); Name = $Name; Precedence = $Precedence; Description = $Description
        Policy = (New-PolicyDefaults); Subjects = [System.Collections.Generic.List[guid]]::new() }
    Set-FakePolicy $o.Policy $PSBoundParameters
    $script:psos.Add($o)
}
function Set-ADFineGrainedPasswordPolicy { param($Identity, [int]$Precedence, $Description,
        [int]$MinPasswordLength, [int]$PasswordHistoryCount, $ComplexityEnabled, $ReversibleEncryptionEnabled,
        [TimeSpan]$MinPasswordAge, [TimeSpan]$MaxPasswordAge, [int]$LockoutThreshold, [TimeSpan]$LockoutDuration,
        [TimeSpan]$LockoutObservationWindow, $Server)
    $o = Find-FakePso $Identity
    if ($PSBoundParameters.ContainsKey('Precedence')) { $o.Precedence = $Precedence }
    if ($PSBoundParameters.ContainsKey('Description')) { $o.Description = $Description }
    Set-FakePolicy $o.Policy $PSBoundParameters
}
function Get-ADFineGrainedPasswordPolicySubject { param($Identity, $Server)
    foreach ($id in (Find-FakePso $Identity).Subjects) { ConvertTo-Fake ($script:objects | Where-Object { $_.Id -eq $id }) }
}
function Add-ADFineGrainedPasswordPolicySubject { param($Identity, $Subjects, $Server)
    $pso = Find-FakePso $Identity
    foreach ($s in @($Subjects)) {
        $o = Find-Fake $s
        if ($o.Class -eq 'group' -and $o.Scope -ne 'Global') { throw "A PSO applies only to global groups: $($o.Sam)" }
        if ($pso.Subjects -contains $o.Id) { throw "Already applied: $($o.Sam)" }
        $pso.Subjects.Add($o.Id)
    }
}
function Remove-ADFineGrainedPasswordPolicySubject { param($Identity, $Subjects, $Confirm, $Server)
    $pso = Find-FakePso $Identity
    foreach ($s in @($Subjects)) { $pso.Subjects.Remove((Find-Fake $s).Id) | Out-Null }
}

# --- Optional features -------------------------------------------------------
function Get-ADOptionalFeature { param($Identity, $Server)
    if ("$Identity" -ne 'Privileged Access Management Feature') { throw "Fake AD does not know feature: $Identity" }
    [pscustomobject]@{ Name = "$Identity"; EnabledScopes = @(if ($script:pamEnabled) { "CN=Partitions,$script:configDN" }) }
}

# --- Authentication policies and silos ---------------------------------------
# Kept as directory objects, so Get-FakeADState covers them.
function ConvertTo-FakeAuthN($o) {
    $h = [ordered]@{ ObjectGUID = $o.Id; DistinguishedName = $o.DN; Name = (Get-RdnValue $o.DN); ObjectClass = $o.Class
        Description = $o.Description; ProtectedFromAccidentalDeletion = $o.Protected }
    foreach ($k in $o.Attrs.Keys) { $h[$k] = $o.Attrs[$k] }
    [pscustomobject]$h
}
function Find-FakeAuthN($Identity, [string]$Class) {
    $o = Find-Fake $Identity
    if ($o.Class -ne $Class) { throw "Not a $Class : $Identity" }
    $o
}
function Get-ADAuthenticationPolicy { param([string]$Filter, $Identity, $Properties, $Server)
    if ($Identity) { return ConvertTo-FakeAuthN (Find-FakeAuthN $Identity 'msDS-AuthNPolicy') }
    Select-Fake $Filter $null @('msDS-AuthNPolicy') | ForEach-Object { ConvertTo-FakeAuthN $_ }
}
function New-ADAuthenticationPolicy { param([string]$Name, $Description, [switch]$Enforce, $ProtectedFromAccidentalDeletion,
        [int]$UserTGTLifetimeMins, [string]$UserAllowedToAuthenticateFrom, $Server)
    $dn = "CN=$Name,$script:policyBase"
    if ($script:objects | Where-Object { $_.DN -eq $dn }) { throw "Already exists: $dn" }
    $o = Add-FakeObject $dn 'msDS-AuthNPolicy' @{ Description = $Description; Protected = [bool]$ProtectedFromAccidentalDeletion }
    $o.Attrs['Enforce'] = [bool]$Enforce
    $o.Attrs['UserTGTLifetimeMins'] = if ($PSBoundParameters.ContainsKey('UserTGTLifetimeMins')) { $UserTGTLifetimeMins } else { $null }
    $o.Attrs['UserAllowedToAuthenticateFrom'] = if ($UserAllowedToAuthenticateFrom) { $UserAllowedToAuthenticateFrom } else { $null }
}
function Set-ADAuthenticationPolicy { param($Identity, $Description, [bool]$Enforce, [int]$UserTGTLifetimeMins,
        [string]$UserAllowedToAuthenticateFrom, [string[]]$Clear, $Server)
    $o = Find-FakeAuthN $Identity 'msDS-AuthNPolicy'
    if ($PSBoundParameters.ContainsKey('Description')) { $o.Description = $Description }
    if ($PSBoundParameters.ContainsKey('Enforce')) { $o.Attrs['Enforce'] = $Enforce }
    if ($PSBoundParameters.ContainsKey('UserTGTLifetimeMins')) { $o.Attrs['UserTGTLifetimeMins'] = $UserTGTLifetimeMins }
    if ($PSBoundParameters.ContainsKey('UserAllowedToAuthenticateFrom')) { $o.Attrs['UserAllowedToAuthenticateFrom'] = $UserAllowedToAuthenticateFrom }
    foreach ($c in @($Clear)) {
        switch ($c) {
            'description' { $o.Description = $null }
            'msDS-UserTGTLifetime' { $o.Attrs['UserTGTLifetimeMins'] = $null }
            'msDS-UserAllowedToAuthenticateFrom' { $o.Attrs['UserAllowedToAuthenticateFrom'] = $null }
            $null { }
            default { throw "Fake AD cannot clear $c" }
        }
    }
}
function Get-ADAuthenticationPolicySilo { param([string]$Filter, $Identity, $Properties, $Server)
    if ($Identity) { return ConvertTo-FakeAuthN (Find-FakeAuthN $Identity 'msDS-AuthNPolicySilo') }
    Select-Fake $Filter $null @('msDS-AuthNPolicySilo') | ForEach-Object { ConvertTo-FakeAuthN $_ }
}
function Resolve-FakePolicyDN($Name) {
    if (-not $Name) { return $null }
    (Find-FakeAuthN $Name 'msDS-AuthNPolicy').DN
}
function New-ADAuthenticationPolicySilo { param([string]$Name, $Description, [switch]$Enforce, $ProtectedFromAccidentalDeletion,
        $UserAuthenticationPolicy, $ComputerAuthenticationPolicy, $ServiceAuthenticationPolicy, $Server)
    $dn = "CN=$Name,$script:siloBase"
    if ($script:objects | Where-Object { $_.DN -eq $dn }) { throw "Already exists: $dn" }
    $o = Add-FakeObject $dn 'msDS-AuthNPolicySilo' @{ Description = $Description; Protected = [bool]$ProtectedFromAccidentalDeletion }
    $o.Attrs['Enforce'] = [bool]$Enforce
    $o.Attrs['UserAuthenticationPolicy'] = Resolve-FakePolicyDN $UserAuthenticationPolicy
    $o.Attrs['ComputerAuthenticationPolicy'] = Resolve-FakePolicyDN $ComputerAuthenticationPolicy
    $o.Attrs['ServiceAuthenticationPolicy'] = Resolve-FakePolicyDN $ServiceAuthenticationPolicy
    $o.Attrs['msDS-AuthNPolicySiloMembers'] = @()
}
function Set-ADAuthenticationPolicySilo { param($Identity, $Description, [bool]$Enforce, $UserAuthenticationPolicy,
        $ComputerAuthenticationPolicy, $ServiceAuthenticationPolicy, [string[]]$Clear, $Server)
    $o = Find-FakeAuthN $Identity 'msDS-AuthNPolicySilo'
    if ($PSBoundParameters.ContainsKey('Description')) { $o.Description = $Description }
    if ($PSBoundParameters.ContainsKey('Enforce')) { $o.Attrs['Enforce'] = $Enforce }
    foreach ($k in 'UserAuthenticationPolicy', 'ComputerAuthenticationPolicy', 'ServiceAuthenticationPolicy') {
        if ($PSBoundParameters.ContainsKey($k)) { $o.Attrs[$k] = Resolve-FakePolicyDN $PSBoundParameters[$k] }
    }
    foreach ($c in @($Clear)) {
        switch ($c) {
            'description' { $o.Description = $null }
            'msDS-UserAuthNPolicy' { $o.Attrs['UserAuthenticationPolicy'] = $null }
            'msDS-ComputerAuthNPolicy' { $o.Attrs['ComputerAuthenticationPolicy'] = $null }
            'msDS-ServiceAuthNPolicy' { $o.Attrs['ServiceAuthenticationPolicy'] = $null }
            $null { }
            default { throw "Fake AD cannot clear $c" }
        }
    }
}
function Grant-ADAuthenticationPolicySiloAccess { param($Identity, $Account, $Server)
    $silo = Find-FakeAuthN $Identity 'msDS-AuthNPolicySilo'
    $a = Find-Fake $Account
    if ($a.Sid -and $a.Sid -like '*-500') { throw 'Test: converge.ps1 must not put the built-in Administrator in a silo' }
    $have = @($silo.Attrs['msDS-AuthNPolicySiloMembers'])
    if ($have -contains $a.DN) { throw "Already has access: $($a.DN)" }
    $silo.Attrs['msDS-AuthNPolicySiloMembers'] = @($have + $a.DN)
}
function Set-ADAccountAuthenticationPolicySilo { param($Identity, $AuthenticationPolicySilo, $Server)
    $a = Find-Fake $Identity
    if ($a.Class -notin 'user', 'computer') { throw "Not an account: $($a.DN)" }
    $silo = Find-FakeAuthN $AuthenticationPolicySilo 'msDS-AuthNPolicySilo'
    if (@($silo.Attrs['msDS-AuthNPolicySiloMembers']) -notcontains $a.DN) { throw "Grant access to the silo first: $($a.DN)" }
    $a.Attrs['msDS-AssignedAuthNPolicySilo'] = $silo.DN
}

# --- ACLs ----------------------------------------------------------------------
function New-FakeAce([string]$Sid, [int]$Rights, [string]$Type = 'Allow', [guid]$ObjectType = [guid]::Empty,
    [string]$InheritanceFlags = 'None', [string]$PropagationFlags = 'None', [guid]$InheritedObjectType = [guid]::Empty) {
    [pscustomobject]@{
        IdentityReference = [pscustomobject]@{ Value = $Sid }; ActiveDirectoryRights = $Rights; AccessControlType = $Type
        ObjectType = $ObjectType; InheritedObjectType = $InheritedObjectType
        InheritanceFlags = $InheritanceFlags; PropagationFlags = $PropagationFlags; IsInherited = $false
    }
}

function Format-FakeAce($a) {
    '{0},{1},{2},{3},{4},{5},{6}' -f $a.IdentityReference.Value, $a.ActiveDirectoryRights, $a.AccessControlType, $a.ObjectType,
        $a.InheritedObjectType, $a.InheritanceFlags, $a.PropagationFlags
}

# A part of the defaultSecurityDescriptor of organizationalUnit.
function Add-FakeDefaultOUAces($o) {
    $d = $script:domainSid
    $o.Acl.Add((New-FakeAce 'S-1-5-18' 983551))
    $o.Acl.Add((New-FakeAce "$d-512" 983551))
    $o.Acl.Add((New-FakeAce 'S-1-5-11' 131220))
    $o.Acl.Add((New-FakeAce 'S-1-5-32-548' 3 'Allow' ([guid]'bf967aba-0de6-11d0-a285-00aa003049e2')))
    $o.Acl.Add((New-FakeAce 'S-1-5-32-548' 3 'Allow' ([guid]'bf967a86-0de6-11d0-a285-00aa003049e2')))
}

# A test adds an ACE by hand, as a person would in ADUC.
function Add-FakeAce([string]$DN, $Ace) { (Find-Fake $DN).Acl.Add($Ace) }
function Remove-FakeAces([string]$DN, [scriptblock]$Where) {
    $o = Find-Fake $DN
    foreach ($a in @($o.Acl | Where-Object $Where)) { $o.Acl.Remove($a) | Out-Null }
}
function Get-FakeAces([string]$DN) { @((Find-Fake $DN).Acl) }

function Get-Acl { param([string]$Path)
    if ($Path -notmatch '^AD:\\(.+)$') { throw "Fake AD supports only AD:\<dn> paths: $Path" }
    $o = Find-Fake $Matches[1]
    $sd = [pscustomobject]@{ Path = $Path; Rules = [System.Collections.Generic.List[object]]::new() }
    foreach ($a in $o.Acl) { $sd.Rules.Add($a) }
    $sd | Add-Member -MemberType ScriptMethod -Name GetAccessRules -Value {
        param($IncludeExplicit, $IncludeInherited, $TargetType)
        if ($TargetType -ne [System.Security.Principal.SecurityIdentifier]) { throw 'Test: ask for SIDs, not names' }
        if ($IncludeExplicit) { @($this.Rules) } else { @() }
    }
    $sd | Add-Member -MemberType ScriptMethod -Name AccessRuleFactory -Value {
        param($Identity, $Mask, $IsInherited, $InheritanceFlags, $PropagationFlags, $Type, $ObjectType, $InheritedObjectType)
        if ($null -eq $Identity -or "$Identity" -notmatch '^S-1-') { throw "Test: AccessRuleFactory needs a SID, got '$Identity'" }
        New-FakeAce "$Identity" ([int]$Mask) "$Type" ([guid]$ObjectType) "$InheritanceFlags" "$PropagationFlags" ([guid]$InheritedObjectType)
    }
    $sd | Add-Member -MemberType ScriptMethod -Name AddAccessRule -Value { param($Rule) $this.Rules.Add($Rule) }
    $sd
}
function Set-Acl { param([string]$Path, $AclObject)
    if ($Path -ne $AclObject.Path) { throw "Test: Set-Acl on $Path with the ACL of $($AclObject.Path)" }
    $o = Find-Fake ($Path -replace '^AD:\\', '')
    $o.Acl.Clear()
    foreach ($a in $AclObject.Rules) { $o.Acl.Add($a) }
}

Export-ModuleMember -Function *
