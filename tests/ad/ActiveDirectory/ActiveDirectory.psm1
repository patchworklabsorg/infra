# In-memory stand-in for the ActiveDirectory module, for tests/ad/run.ps1.
# It implements only the cmdlets and the filter forms that ad/converge.ps1
# uses, and it enforces the AD rules the script depends on: a parent must
# exist, a protected object cannot move or be deleted, an OU with children
# cannot be deleted, and Global cannot change straight to DomainLocal.

$script:domainDN = 'DC=patchwork,DC=internal'
$script:objects = [System.Collections.Generic.List[object]]::new()
$script:upnSuffixes = [System.Collections.Generic.List[string]]::new()

$userAttrs = 'company', 'division', 'department', 'title', 'givenName', 'sn', 'displayName',
'manager', 'userPrincipalName', 'mail'

function Reset-FakeAD {
    $script:objects.Clear()
    $script:upnSuffixes.Clear()
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
    }) + ($script:upnSuffixes -join ';') -join "`n"
}

function Add-FakeObject([string]$DN, [string]$Class, [hashtable]$Extra = @{}) {
    $o = [pscustomobject]@{
        Id = [guid]::NewGuid(); DN = $DN; Class = $Class; Sam = $null; Enabled = $true
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
        $o = $script:objects | Where-Object { $_.DN -eq $s -or $_.Sam -eq $s -or (Get-RdnValue $_.DN) -eq $s } |
            Select-Object -First 1
    }
    if (-not $o) { throw "Cannot find an object with identity: '$Identity'" }
    $o
}

function ConvertTo-Fake($o) {
    $h = [ordered]@{
        ObjectGUID = $o.Id; DistinguishedName = $o.DN; ObjectClass = $o.Class; Name = (Get-RdnValue $o.DN)
        SamAccountName = $o.Sam; Enabled = $o.Enabled
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
    [pscustomobject]@{ DNSRoot = 'patchwork.internal'; DistinguishedName = $script:domainDN; PDCEmulator = 'loom.patchwork.internal' }
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
function Get-ADGroupMember { param($Identity, $Server)
    $g = Find-Fake $Identity
    foreach ($id in $g.Members) { ConvertTo-Fake ($script:objects | Where-Object { $_.Id -eq $id }) }
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

Export-ModuleMember -Function *
