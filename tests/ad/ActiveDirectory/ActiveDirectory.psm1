# In-memory stand-in for the ActiveDirectory module, for tests/ad/run.ps1.
# It implements only the cmdlets and the filter forms that ad/converge.ps1
# uses, and it enforces the AD rules the script depends on: a parent must
# exist, a protected object cannot move or be deleted, an OU with children
# cannot be deleted, Global cannot change straight to DomainLocal, a PSO
# applies only to global groups and users, and a lockout observation window
# cannot be longer than the lockout duration.

$script:domainDN = 'DC=patchwork,DC=internal'
$script:domainSid = 'S-1-5-21-1111111111-2222222222-3333333333'
$script:objects = [System.Collections.Generic.List[object]]::new()
$script:upnSuffixes = [System.Collections.Generic.List[string]]::new()
$script:psos = [System.Collections.Generic.List[object]]::new()
$script:defaultPolicy = $null

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
}

# An operator enabling an account after the person set a password.
function Enable-FakeUser([string]$Sam) { (Find-Fake $Sam).Enabled = $true }

function Get-FakeADState {
    # Deep enough copy to compare before and after a -WhatIf run.
    ($script:objects | ForEach-Object {
        $o = $_
        '{0}|{1}|{2}|{3}|{4}|{5}|{6}' -f $o.DN, $o.Class, $o.Enabled, $o.Scope, $o.Protected,
            (($o.Attrs.GetEnumerator() | Sort-Object Key | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ';'),
            (($o.Members | Sort-Object) -join ';')
    }) + ($script:upnSuffixes -join ';') + (Format-FakePolicy $script:defaultPolicy) + ($script:psos | ForEach-Object {
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
        Members = [System.Collections.Generic.List[guid]]::new()
    }
    foreach ($k in $Extra.Keys) { $o.$k = $Extra[$k] }
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
        SamAccountName = $o.Sam; SID = $o.Sid; Enabled = $o.Enabled
        GroupScope = $o.Scope; Description = $o.Description; ProtectedFromAccidentalDeletion = $o.Protected
    }
    foreach ($a in $userAttrs) { $h[$a] = $o.Attrs[$a] }
    [pscustomobject]$h
}

function Select-Fake([string]$Filter, [string]$SearchBase, [string[]]$Classes) {
    $set = $script:objects | Where-Object { -not $Classes -or $Classes -contains $_.Class }
    if ($SearchBase) { $set = $set | Where-Object { $_.DN -eq $SearchBase -or $_.DN -like "*,$SearchBase" } }
    if ($Filter -eq '*') { return $set }
    if ($Filter -notmatch "^(\w+) -(eq|ne) '(.*)'$") { throw "Fake AD does not support filter: $Filter" }
    $attr, $op, $value = $Matches[1], $Matches[2], $Matches[3]
    $get = switch ($attr) {
        'SamAccountName' { { param($o) $o.Sam } }
        'distinguishedName' { { param($o) $o.DN } }
        'UserPrincipalName' { { param($o) $o.Attrs['userPrincipalName'] } }
        'objectClass' { { param($o) $o.Class } }
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
    # manager is a linked attribute: AD follows the move.
    foreach ($x in $script:objects) { if ($x.Attrs['manager'] -eq $oldDN) { $x.Attrs['manager'] = $o.DN } }
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
    Add-FakeObject $dn 'organizationalUnit' @{ Description = $Description; Protected = [bool]$ProtectedFromAccidentalDeletion } | Out-Null
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
function Get-ADGroup { param([string]$Filter, $Properties, $Server, $Identity)
    if ($Identity) { return ConvertTo-Fake (Find-Fake $Identity) }
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
function Add-ADGroupMember { param($Identity, $Members, $Server)
    $g = Find-Fake $Identity
    foreach ($m in @($Members)) {
        $o = Find-Fake $m
        if ($g.Members -contains $o.Id) { throw "Already a member: $($o.Sam)" }
        $g.Members.Add($o.Id)
    }
}
function Remove-ADGroupMember { param($Identity, $Members, $Confirm, $Server)
    $g = Find-Fake $Identity
    foreach ($m in @($Members)) { $g.Members.Remove((Find-Fake $m).Id) | Out-Null }
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

Export-ModuleMember -Function *
