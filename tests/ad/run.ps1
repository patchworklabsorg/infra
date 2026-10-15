# Runs ad/converge.ps1 against the in-memory directory in ./ActiveDirectory.
#   pwsh -NoProfile -File tests/ad/run.ps1
# Exits non-zero on the first failed check.
param([string]$Converge = (Join-Path $PSScriptRoot '../../ad/converge.ps1'))

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$env:PSModulePath = $PSScriptRoot + [IO.Path]::PathSeparator + $env:PSModulePath
Import-Module ActiveDirectory -Force

$logDir = Join-Path ([IO.Path]::GetTempPath()) ("ad-converge-test-" + [guid]::NewGuid())
$dom = 'DC=patchwork,DC=internal'
$old = "OU=Patchwork-Objects,$dom"
$new = "OU=Patchwork,$dom"
$script:failed = 0

function Check([string]$Name, [bool]$Ok) {
    if ($Ok) { Write-Host "ok    $Name" } else { Write-Host "FAIL  $Name"; $script:failed++ }
}

# Runs one phase, returns @{ Changes; Reports; Errors; Output }.
function Converge([string]$Phase, [switch]$WhatIf, [string]$DataFile = (Join-Path $PSScriptRoot '../../ad/org.json')) {
    $out = & $Converge -Phase $Phase -LogDir $logDir -DataFile $DataFile -WhatIf:$WhatIf 6>&1 2>&1 | Out-String
    if ($out -notmatch 'END\s+(\d+) changes, (\d+) reports, (\d+) errors') { throw "No END line:`n$out" }
    @{ Changes = [int]$Matches[1]; Reports = [int]$Matches[2]; Errors = [int]$Matches[3]; Output = $out }
}

function U([string]$Sam) { Get-ADUser -Filter "SamAccountName -eq '$Sam'" }
function G([string]$Sam) { Get-ADGroup -Filter "SamAccountName -eq '$Sam'" }
function MembersOf([string]$Group) { @(Get-ADGroupMember -Identity $Group | ForEach-Object { $_.SamAccountName }) }

# A copy of org.json with changes, for the JIT checks.
function New-OrgJson([scriptblock]$Change) {
    $o = Get-Content -Raw (Join-Path $PSScriptRoot '../../ad/org.json') | ConvertFrom-Json
    & $Change $o
    $f = Join-Path $logDir ("org-" + [guid]::NewGuid() + '.json')
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    $o | ConvertTo-Json -Depth 20 | Set-Content -Path $f
    $f
}

# --- Base objects that every domain has ---------------------------------------
$domainSid = (Get-ADDomain).DomainSID

function New-BaseDirectory([string]$AdminName = 'Administrator') {
    Reset-FakeAD
    Add-FakeObject "CN=Users,$dom" 'container' | Out-Null
    Add-FakeObject "CN=Builtin,$dom" 'container' | Out-Null
    foreach ($g in 'Domain Admins', 'Enterprise Admins', 'Schema Admins') {
        Add-FakeObject "CN=$g,CN=Users,$dom" 'group' @{ Sam = $g; Scope = 'Global' } | Out-Null
    }
    Add-FakeObject "CN=Administrators,CN=Builtin,$dom" 'group' @{ Sam = 'Administrators'; Scope = 'DomainLocal' } | Out-Null
    Add-FakeObject "CN=$AdminName,CN=Users,$dom" 'user' @{ Sam = $AdminName; Sid = "$domainSid-500" } | Out-Null
    Add-ADGroupMember -Identity 'Domain Admins' -Members $AdminName
    Add-FakeObject "OU=Domain Controllers,$dom" 'organizationalUnit' @{ Protected = $true } | Out-Null
    foreach ($dc in 'LOOM', 'SPINDLE') {
        Add-FakeObject "CN=$dc,OU=Domain Controllers,$dom" 'computer' @{ Sam = "$dc`$" } | Out-Null
    }
}

function Set-Attrs($Object, [hashtable]$Attrs) { foreach ($k in $Attrs.Keys) { $Object.Attrs[$k] = $Attrs[$k] } }

# --- The directory as recorded on loom on 2026-10-14, plus test objects --------
New-BaseDirectory
foreach ($ou in 'Patchwork-Objects', 'Staff-Production,OU=Patchwork-Objects', 'Staff-Computers,OU=Staff-Production,OU=Patchwork-Objects',
    'Infrastructure,OU=Patchwork-Objects', 'Member-Servers,OU=Infrastructure,OU=Patchwork-Objects',
    'Security-Groups,OU=Patchwork-Objects', 'Linux-Access-Control,OU=Security-Groups,OU=Patchwork-Objects',
    'Box-Users,OU=Linux-Access-Control,OU=Security-Groups,OU=Patchwork-Objects',
    'Box-Admins,OU=Linux-Access-Control,OU=Security-Groups,OU=Patchwork-Objects',
    'Service-Accounts,OU=Patchwork-Objects', 'Governance,OU=Patchwork-Objects',
    'Board-of-Directors,OU=Governance,OU=Patchwork-Objects', 'Administrative,OU=Patchwork-Objects',
    'Admin-Accounts,OU=Administrative,OU=Patchwork-Objects', 'Members,OU=Patchwork-Objects') {
    Add-FakeObject "OU=$ou,$dom" 'organizationalUnit' @{ Protected = $true } | Out-Null
}
$board = "OU=Board-of-Directors,OU=Governance,$old"
$mayonej = Add-FakeObject "CN=Jasper Mayone,$board" 'user' @{ Sam = 'mayonej'; Protected = $true }
Set-Attrs $mayonej @{ title = 'Founder'; givenName = 'Jasper'; sn = 'Mayone'; displayName = 'Jasper Mayone'; userPrincipalName = 'mayonej@patchwork.internal' }
$adm = Add-FakeObject "CN=Jasper Mayone (Admin),OU=Admin-Accounts,OU=Administrative,$old" 'user' @{ Sam = 'adm_mayonej' }
Set-Attrs $adm @{ givenName = 'Jasper'; sn = 'Mayone'; displayName = 'Jasper Mayone (Admin)'; userPrincipalName = 'adm_mayonej@patchwork.internal' }
$klukask = Add-FakeObject "CN=Kieran Klukas,$board" 'user' @{ Sam = 'klukask'; Enabled = $false }
Set-Attrs $klukask @{ givenName = 'Kieran'; sn = 'Klukas'; displayName = 'Kieran Klukas' }
$petrarcad = Add-FakeObject "CN=Dominic Petrarca,$board" 'user' @{ Sam = 'petrarcad'; Enabled = $false }
Set-Attrs $petrarcad @{ givenName = 'Dominic'; sn = 'Petrarca'; displayName = 'Dominic Petrarca' }
foreach ($svc in 'svc-ansible', 'svc-lnx-join', 'svc-dhcp-dns', 'svc-pve-ldap') {
    Add-FakeObject "CN=$svc,OU=Service-Accounts,$old" 'user' @{ Sam = $svc } | Out-Null
}
Add-FakeObject "CN=vi,OU=Governance,$old" 'user' @{ Sam = 'vi' } | Out-Null
Add-FakeObject "CN=member1,OU=Members,$old" 'user' @{ Sam = 'member1' } | Out-Null
# Test objects: a user that org.json does not know, and two UPN conflicts.
# logan does not exist, but a Weave member already has its UPN. imposter
# holds the UPN that org.json gives to petrarcad.
$stranger = Add-FakeObject "CN=stranger,OU=Governance,$old" 'user' @{ Sam = 'stranger' }
$loganUpn = Add-FakeObject "CN=logan2,OU=Members,$old" 'user' @{ Sam = 'logan2' }
Set-Attrs $loganUpn @{ userPrincipalName = 'logan@hackboston.dev' }
$imposter = Add-FakeObject "CN=imposter,OU=Members,$old" 'user' @{ Sam = 'imposter' }
Set-Attrs $imposter @{ userPrincipalName = 'dominic@patchworklabs.org' }
$lnxUsers = Add-FakeObject "CN=lnx-skein-users,OU=Box-Users,OU=Linux-Access-Control,OU=Security-Groups,$old" 'group' @{ Sam = 'lnx-skein-users'; Scope = 'Global'; Description = 'Linux logon on skein' }
Add-FakeObject "CN=lnx-skein-admins,OU=Box-Admins,OU=Linux-Access-Control,OU=Security-Groups,$old" 'group' @{ Sam = 'lnx-skein-admins'; Scope = 'Global'; Description = 'Linux sudo on skein' } | Out-Null
Add-FakeObject "CN=lnx-sampler-users,OU=Box-Users,OU=Linux-Access-Control,OU=Security-Groups,$old" 'group' @{ Sam = 'lnx-sampler-users'; Scope = 'Global'; Protected = $true } | Out-Null
Add-FakeObject "CN=lnx-swatch-admins,OU=Box-Admins,OU=Linux-Access-Control,OU=Security-Groups,$old" 'group' @{ Sam = 'lnx-swatch-admins'; Scope = 'Global' } | Out-Null
Add-FakeObject "CN=SKEIN,OU=Member-Servers,OU=Infrastructure,$old" 'computer' @{ Sam = 'SKEIN$' } | Out-Null
Add-FakeObject "CN=BOBBIN,OU=Member-Servers,OU=Infrastructure,$old" 'computer' @{ Sam = 'BOBBIN$' } | Out-Null
Add-FakeObject "CN=SHUTTLE,OU=Member-Servers,OU=Infrastructure,$old" 'computer' @{ Sam = 'SHUTTLE$' } | Out-Null
Add-FakeObject "CN=LAPTOP1,OU=Staff-Computers,OU=Staff-Production,$old" 'computer' @{ Sam = 'LAPTOP1$' } | Out-Null
Add-FakeObject "CN=DnsAdmins,CN=Users,$dom" 'group' @{ Sam = 'DnsAdmins'; Scope = 'DomainLocal' } | Out-Null
Add-ADGroupMember -Identity 'Domain Admins' -Members 'adm_mayonej'
Add-ADGroupMember -Identity 'Enterprise Admins' -Members 'adm_mayonej'
Add-ADGroupMember -Identity 'Domain Admins' -Members 'svc-ansible'
Add-ADGroupMember -Identity 'Enterprise Admins' -Members 'Administrator'
Add-ADGroupMember -Identity 'Schema Admins' -Members 'Administrator'
Add-ADGroupMember -Identity 'DnsAdmins' -Members 'adm_mayonej'
# Not live: a daily account with Domain Admins, to test that Build removes it.
Add-ADGroupMember -Identity 'Domain Admins' -Members 'mayonej'
Add-ADGroupMember -Identity 'lnx-skein-users' -Members 'mayonej'
Add-ADGroupMember -Identity 'lnx-skein-users' -Members 'vi'

# --- Build ---------------------------------------------------------------------
$before = Get-FakeADState
$r = Converge Build -WhatIf
Check 'Build -WhatIf changes nothing' ((Get-FakeADState) -eq $before)
Check 'Build -WhatIf lists changes' ($r.Changes -gt 0 -and $r.Errors -eq 0)
Check 'Build -WhatIf creates no existing person' ($r.Output -notmatch 'Create user[^\n]*(Jasper Mayone|Kieran|Dominic|klukask|petrarcad|svc-lnx-join|svc-dhcp-dns|svc-pve-ldap|svc-ansible)')
Check 'Build -WhatIf shows the UPN change' ($r.Output -match "WOULD\s+Set [^\n]*userPrincipalName='jasper@patchworklabs.org'")
Check 'Build -WhatIf shows the silo' ($r.Output -match 'WOULD\s+Create, enforce=False[^\n]*: authentication policy silo T0-Silo' -and
    $r.Output -match 'WOULD\s+Create, enforce=False, tgtMinutes=240, deviceInSilo=True : authentication policy T0-User' -and
    $r.Output -match 'WOULD\s+Grant access to LOOM\$, assign the silo : T0-Silo \(after it is created\)')
Check 'Build -WhatIf shows the PSOs' ($r.Output -match 'WOULD\s+Create PSO[^\n]*PSO-Tier0' -and $r.Output -match 'Apply to GG-Service-Accounts : PSO PSO-Service')

$r = Converge Build
Check 'Build has no errors' ($r.Errors -eq 0)
if ($r.Errors) { Write-Host $r.Output }
Check 'UPN suffix added' ((Get-ADForest).UPNSuffixes -contains 'patchworklabs.org')
Check 'OU hackathon.help exists' ([bool](Get-ADOrganizationalUnit -Filter "distinguishedName -eq 'OU=hackathon.help,OU=Sponsored-Projects,OU=Users,$new'"))
Check 'OU Users/Members exists' ([bool](Get-ADOrganizationalUnit -Filter "distinguishedName -eq 'OU=Members,OU=Users,$new'"))
$adam = U 'adam.sidwa'
Check 'adam.sidwa created disabled in Staff' ($adam -and -not $adam.Enabled -and $adam.DistinguishedName -eq "CN=Adam Sidwa,OU=Staff,OU=Users,$new")
Check 'adam.sidwa attributes' ($adam.division -eq 'Programs' -and $adam.department -eq 'Project Ganymede' -and
    $adam.company -eq 'Patchwork Labs inc.' -and $adam.userPrincipalName -eq 'adam.sidwa@patchworklabs.org')
Check 'adam.sidwa manager is mayonej' ($adam.manager -eq (U 'mayonej').DistinguishedName)
Check 'klukask has no manager' ($null -eq (U 'klukask').manager)
$j = U 'mayonej'
Check 'mayonej updated in place' ($j.title -eq 'Founder & Director of Programs' -and $j.DistinguishedName -eq "CN=Jasper Mayone,$board")
Check 'mayonej UPN is jasper@patchworklabs.org' ($j.userPrincipalName -eq 'jasper@patchworklabs.org')
Check 'klukask UPN is kieran@patchworklabs.org, still disabled' ((U 'klukask').userPrincipalName -eq 'kieran@patchworklabs.org' -and -not (U 'klukask').Enabled)
Check 'one user per person' (@(Get-ADUser -Filter "objectClass -eq 'user'" | Where-Object { $_.Name -like 'Jasper Mayone*' }).Count -eq 2 -and
    -not (U 'jasper') -and -not (U 'kieran') -and -not (U 'dominic') -and -not (U 'jasper.adm'))
Check 'UPN conflict: petrarcad reported and not changed' ($r.Output -match 'petrarcad: UPN dominic@patchworklabs.org belongs to imposter' -and $null -eq (U 'petrarcad').userPrincipalName)
Check 'UPN conflict: logan reported and not created' ($r.Output -match 'logan: UPN logan@hackboston.dev belongs to logan2' -and -not (U 'logan'))
Check 'wei in hackathon.help OU' ((U 'wei').DistinguishedName -eq "CN=wei,OU=hackathon.help,OU=Sponsored-Projects,OU=Users,$new")
Check 'adm_mayonej keeps its UPN and name' ((U 'adm_mayonej').userPrincipalName -eq 'adm_mayonej@patchwork.internal' -and (U 'adm_mayonej').displayName -eq 'Jasper Mayone (Admin)')
Check 'svc-ansible not created or changed' ((U 'svc-ansible').DistinguishedName -like "*,$old")
Check 'GG-Board members' (((MembersOf 'GG-Board') | Sort-Object) -join ',' -eq 'klukask,mayonej,petrarcad')
Check 'GG-Board is Global in Roles' ((G 'GG-Board').GroupScope -eq 'Global' -and (G 'GG-Board').DistinguishedName -like "*,OU=Roles,OU=Groups,$new")
Check 'GG-Service-Accounts members' (((MembersOf 'GG-Service-Accounts') | Sort-Object) -join ',' -eq 'svc-ansible,svc-dhcp-dns,svc-lnx-join,svc-pve-ldap,svc-service')
Check 'svc-service gets UPN service@patchworklabs.org' ((Get-ADUser -Filter "SamAccountName -eq 'svc-service'" -Properties UserPrincipalName).UserPrincipalName -eq 'service@patchworklabs.org')
Check 'cj gets the HackBoston domain from the OU' ((Get-ADUser -Filter "SamAccountName -eq 'cj'" -Properties UserPrincipalName).UserPrincipalName -eq 'cj@hackboston.dev')
Check 'wei gets the hackathon.help domain from the OU' ((Get-ADUser -Filter "SamAccountName -eq 'wei'" -Properties UserPrincipalName).UserPrincipalName -eq 'wei@hackathon.help')
Check 'staff keep patchworklabs.org' ((Get-ADUser -Filter "SamAccountName -eq 'mayonej'" -Properties UserPrincipalName).UserPrincipalName -eq 'jasper@patchworklabs.org')
Check 'project UPN suffixes added to the forest' ((Get-ADForest).UPNSuffixes -contains 'hackboston.dev' -and (Get-ADForest).UPNSuffixes -contains 'hackathon.help')
Check 'lnx-warp-users created DomainLocal' ((G 'lnx-warp-users').GroupScope -eq 'DomainLocal')
Check 'lnx-skein-users holds only GG-Infra' (((MembersOf 'lnx-skein-users') -join ',') -eq 'GG-Infra')
Check 'tier 0 group in Domain Admins' ((MembersOf 'Domain Admins') -contains 'GG-Domain-Admins-Tier0')
Check 'adm_mayonej in tier 0 group' ((MembersOf 'GG-Domain-Admins-Tier0') -contains 'adm_mayonej')
Check 'mayonej leaves Domain Admins, adm_mayonej had a direct path' (-not ((MembersOf 'Domain Admins') -contains 'mayonej'))
Check 'adm_mayonej direct DA and EA kept and reported' ((MembersOf 'Domain Admins') -contains 'adm_mayonej' -and (MembersOf 'Enterprise Admins') -contains 'adm_mayonej' -and
    $r.Output -match 'adm_mayonej is a direct member of Domain Admins')
Check 'svc-ansible stays in Domain Admins' ((MembersOf 'Domain Admins') -contains 'svc-ansible')
Check 'built-in Administrator disabled, adm_mayonej is in Domain Admins' (-not (U 'Administrator').Enabled -and $r.Output -match 'CHANGE\s+Disable built-in Administrator Administrator \(S-1-5-21-[0-9-]+-500\)')
Check 'vi disabled' (-not (U 'vi').Enabled)
Check 'yc (no attributes) created disabled' ((U 'yc') -and -not (U 'yc').Enabled)
Check 'retired host groups deleted' (-not (G 'lnx-sampler-users') -and -not (G 'lnx-swatch-admins'))
Check 'new users must change password' ((Get-FakeADState) -match 'CN=Adam Sidwa,[^|]*\|user\|False\|[^|]*\|[^|]*\|[^|]*pwdLastSet=0')

$dp = Get-ADDefaultDomainPasswordPolicy -Identity $dom
Check 'default policy set' ($dp.MinPasswordLength -eq 12 -and $dp.MaxPasswordAge.Ticks -le 0 -and $dp.PasswordHistoryCount -eq 24 -and
    $dp.ComplexityEnabled -and $dp.LockoutThreshold -eq 10 -and $dp.LockoutDuration -eq [TimeSpan]::FromMinutes(15) -and
    $dp.LockoutObservationWindow -eq [TimeSpan]::FromMinutes(15))
function PsoSubjects([string]$Name) { @(Get-ADFineGrainedPasswordPolicySubject -Identity $Name | ForEach-Object { $_.SamAccountName }) -join ',' }
$t0 = Get-ADFineGrainedPasswordPolicy -Identity 'PSO-Tier0'
Check 'PSO-Tier0' ($t0.Precedence -eq 10 -and $t0.MinPasswordLength -eq 20 -and $t0.LockoutThreshold -eq 5 -and
    $t0.LockoutDuration -eq [TimeSpan]::FromMinutes(30) -and $t0.MaxPasswordAge.Ticks -le 0 -and (PsoSubjects 'PSO-Tier0') -eq 'GG-Domain-Admins-Tier0,GG-T0-Eligible')
$sv = Get-ADFineGrainedPasswordPolicy -Identity 'PSO-Service'
Check 'PSO-Service' ($sv.MinPasswordLength -eq 32 -and $sv.LockoutThreshold -eq 0 -and (PsoSubjects 'PSO-Service') -eq 'GG-Service-Accounts')
$st = Get-ADFineGrainedPasswordPolicy -Identity 'PSO-Staff'
Check 'PSO-Staff' ($st.MinPasswordLength -eq 14 -and $st.LockoutThreshold -eq 10 -and (PsoSubjects 'PSO-Staff') -eq 'GG-All-Staff')

# Tiering
$sddl = 'O:SYG:SYD:(XA;OICI;CR;;;WD;(@USER.ad://ext/AuthenticationSilo == "T0-Silo"))'
$tu = Get-ADAuthenticationPolicy -Identity 'T0-User'
Check 'T0-User: 240 min, device in silo, audit mode, protected' ($tu.UserTGTLifetimeMins -eq 240 -and $tu.UserAllowedToAuthenticateFrom -eq $sddl -and
    -not $tu.Enforce -and $tu.ProtectedFromAccidentalDeletion)
$tc = Get-ADAuthenticationPolicy -Identity 'T0-Computer'
Check 'T0-Computer: no TGT lifetime, no condition' ($null -eq $tc.UserTGTLifetimeMins -and $null -eq $tc.UserAllowedToAuthenticateFrom -and -not $tc.Enforce)
$ts = Get-ADAuthenticationPolicy -Identity 'T0-Service'
Check 'T0-Service: 60 min, no device condition, audit mode' ($ts.UserTGTLifetimeMins -eq 60 -and $null -eq $ts.UserAllowedToAuthenticateFrom -and -not $ts.Enforce)
$silo = Get-ADAuthenticationPolicySilo -Identity 'T0-Silo'
Check 'T0-Silo: audit mode, user and computer policy, no service policy' (-not $silo.Enforce -and $silo.ProtectedFromAccidentalDeletion -and
    $silo.UserAuthenticationPolicy -eq $tu.DistinguishedName -and $silo.ComputerAuthenticationPolicy -eq $tc.DistinguishedName -and
    $null -eq $silo.ServiceAuthenticationPolicy)
function SiloSams {
    @((Get-ADObject -Identity (Get-ADAuthenticationPolicySilo -Identity 'T0-Silo').DistinguishedName -Properties 'msDS-AuthNPolicySiloMembers').'msDS-AuthNPolicySiloMembers' |
        ForEach-Object { (Get-ADObject -Identity $_).SamAccountName } | Sort-Object) -join ','
}
function AssignedSilo([string]$Sam) {
    $p = (Get-ADObject -Filter "SamAccountName -eq '$Sam'" -Properties 'msDS-AssignedAuthNPolicySilo').PSObject.Properties['msDS-AssignedAuthNPolicySilo']
    if ($p) { $p.Value } else { $null }
}
Check 'T0-Silo members' ((SiloSams) -eq 'adm_mayonej,BOBBIN$,LOOM$,SHUTTLE$,SPINDLE$')
Check 'silo assigned to each member' (@('adm_mayonej', 'LOOM$', 'SPINDLE$', 'BOBBIN$', 'SHUTTLE$' | Where-Object { (AssignedSilo $_) -ne $silo.DistinguishedName }).Count -eq 0)
Check 'SPOOL reported, not created' ($r.Output -match 'REPORT\s+SPOOL\$ does not exist, so it is not in T0-Silo' -and -not (Get-ADObject -Filter "SamAccountName -eq 'SPOOL$'"))
Check 'svc-ansible and Administrator not in the silo' ($null -eq (AssignedSilo 'svc-ansible') -and $null -eq (AssignedSilo 'Administrator'))
Check 'GG-T0-Eligible holds adm_mayonej' (((MembersOf 'GG-T0-Eligible') -join ',') -eq 'adm_mayonej')
Check 'Administrator leaves Enterprise Admins and Schema Admins, stays in Domain Admins' (-not ((MembersOf 'Enterprise Admins') -contains 'Administrator') -and
    -not ((MembersOf 'Schema Admins') -contains 'Administrator') -and (MembersOf 'Domain Admins') -contains 'Administrator' -and
    $r.Output -notmatch 'Administrator is a direct member of (Enterprise|Schema) Admins')
Check 'JIT off: standing admin reported, not removed' ((MembersOf 'DnsAdmins') -contains 'adm_mayonej' -and
    $r.Output -match 'adm_mayonej is a standing member of DnsAdmins' -and $r.Output -match 'adm_mayonej is a direct member of Enterprise Admins')

$r = Converge Build
Check 'Build twice: zero changes' ($r.Changes -eq 0 -and $r.Errors -eq 0)
if ($r.Changes) { Write-Host $r.Output }

# Drift: a changed PSO, an extra subject and an unknown PSO.
Set-ADFineGrainedPasswordPolicy -Identity 'PSO-Staff' -MinPasswordLength 8
Add-ADFineGrainedPasswordPolicySubject -Identity 'PSO-Staff' -Subjects 'GG-Board'
New-ADFineGrainedPasswordPolicy -Name 'PSO-Old' -Precedence 99
$r = Converge Build
Check 'PSO drift fixed' ((Get-ADFineGrainedPasswordPolicy -Identity 'PSO-Staff').MinPasswordLength -eq 14 -and (PsoSubjects 'PSO-Staff') -eq 'GG-All-Staff' -and $r.Errors -eq 0)
Check 'unknown PSO reported, not deleted' ($r.Output -match 'PSO PSO-Old is in AD but not in org.json' -and (Get-ADFineGrainedPasswordPolicy -Identity 'PSO-Old'))

# Silo drift: enforce by hand, a changed lifetime and condition, an extra
# member. Build sets org.json values back and only reports the extra member.
Set-ADAuthenticationPolicySilo -Identity 'T0-Silo' -Enforce $true
Set-ADAuthenticationPolicy -Identity 'T0-User' -UserTGTLifetimeMins 600 -Enforce $true
Set-ADAuthenticationPolicy -Identity 'T0-Computer' -UserAllowedToAuthenticateFrom 'O:SYG:SYD:(A;;CR;;;WD)'
Set-ADAuthenticationPolicySilo -Identity 'T0-Silo' -ServiceAuthenticationPolicy 'T0-Service'
Grant-ADAuthenticationPolicySiloAccess -Identity 'T0-Silo' -Account 'SKEIN$'
$r = Converge Build
$tu = Get-ADAuthenticationPolicy -Identity 'T0-User'
$silo = Get-ADAuthenticationPolicySilo -Identity 'T0-Silo'
Check 'silo drift fixed' ($r.Errors -eq 0 -and -not $silo.Enforce -and $null -eq $silo.ServiceAuthenticationPolicy -and $tu.UserTGTLifetimeMins -eq 240 -and
    -not $tu.Enforce -and $null -eq (Get-ADAuthenticationPolicy -Identity 'T0-Computer').UserAllowedToAuthenticateFrom)
Check 'extra silo member reported, not removed' ($r.Output -match 'CN=SKEIN,[^\n]*has access to T0-Silo, but it is not in tiering' -and (SiloSams) -match 'SKEIN')

# Enforce from org.json.
$enforced = New-OrgJson { param($o) $o.tiering.enforce = $true }
$r = Converge Build -DataFile $enforced
Check 'tiering.enforce true enforces the silo and T0-User, not T0-Service' ($r.Errors -eq 0 -and (Get-ADAuthenticationPolicySilo -Identity 'T0-Silo').Enforce -and
    (Get-ADAuthenticationPolicy -Identity 'T0-User').Enforce -and (Get-ADAuthenticationPolicy -Identity 'T0-Computer').Enforce -and
    -not (Get-ADAuthenticationPolicy -Identity 'T0-Service').Enforce)
Converge Build | Out-Null

# --- Migrate -------------------------------------------------------------------
$before = Get-FakeADState
$r = Converge Migrate -WhatIf
Check 'Migrate -WhatIf changes nothing' ((Get-FakeADState) -eq $before)

$r = Converge Migrate
Check 'Migrate has no errors' ($r.Errors -eq 0)
if ($r.Errors) { Write-Host $r.Output }
Check 'mayonej moved to Staff and still protected' ((U 'mayonej').DistinguishedName -eq "CN=Jasper Mayone,OU=Staff,OU=Users,$new" -and (U 'mayonej').ProtectedFromAccidentalDeletion)
Check 'adam.sidwa manager follows the move' ((U 'adam.sidwa').manager -eq (U 'mayonej').DistinguishedName)
Check 'adm_mayonej moved to Admin-Accounts' ((U 'adm_mayonej').DistinguishedName -eq "CN=Jasper Mayone (Admin),OU=Admin-Accounts,$new")
Check 'klukask moved to Board-Only' ((U 'klukask').DistinguishedName -eq "CN=Kieran Klukas,OU=Board-Only,OU=Users,$new")
Check 'svc-ansible moved to Admin-Accounts' ((U 'svc-ansible').DistinguishedName -eq "CN=svc-ansible,OU=Admin-Accounts,$new")
foreach ($svc in 'svc-lnx-join', 'svc-dhcp-dns', 'svc-pve-ldap') {
    Check "$svc moved to Service-Accounts" ((U $svc).DistinguishedName -eq "CN=$svc,OU=Service-Accounts,$new")
}
Check 'vi moved to Disabled' ((U 'vi').DistinguishedName -eq "CN=vi,OU=Disabled,$new")
Check 'member1 moved to Users/Members' ((U 'member1').DistinguishedName -eq "CN=member1,OU=Members,OU=Users,$new")
Check 'lnx-skein-users DomainLocal in Resources' ((G 'lnx-skein-users').GroupScope -eq 'DomainLocal' -and (G 'lnx-skein-users').DistinguishedName -eq "CN=lnx-skein-users,OU=Resources,OU=Groups,$new")
Check 'SKEIN moved to Servers' ([bool](Get-ADObject -Filter "distinguishedName -eq 'CN=SKEIN,OU=Servers,$new'"))
Check 'LAPTOP1 moved to Computers' ([bool](Get-ADObject -Filter "distinguishedName -eq 'CN=LAPTOP1,OU=Computers,$new'"))
Check 'stranger stays and is reported' ((U 'stranger').DistinguishedName -like "*,$old" -and $r.Output -match 'No destination for user CN=stranger')

# --- Prune ---------------------------------------------------------------------
$threw = $false
try { Converge Prune | Out-Null } catch { $threw = $true }
Check 'Prune refuses while stranger is in the old tree' ($threw -and [bool](Get-ADObject -Filter "distinguishedName -eq '$old'"))

Move-ADObject -Identity 'stranger' -TargetPath "OU=Disabled,$new"
$before = Get-FakeADState
Converge Prune -WhatIf | Out-Null
Check 'Prune -WhatIf changes nothing' ((Get-FakeADState) -eq $before)
$r = Converge Prune
Check 'Prune deletes the old tree' ($r.Errors -eq 0 -and -not (Get-ADObject -Filter "distinguishedName -eq '$old'"))

$r = Converge Build
Check 'Build after migration: zero changes' ($r.Changes -eq 0 -and $r.Errors -eq 0 -and $r.Output -notmatch 'Migrate moves it')
if ($r.Changes) { Write-Host $r.Output }

# --- Just-in-time admin ---------------------------------------------------------
$jitOn = New-OrgJson { param($o) $o.tiering.jit.enabled = $true }
$jitRemove = New-OrgJson { param($o) $o.tiering.jit.enabled = $true; $o.tiering.jit.removeStanding = $true }
$removeOnly = New-OrgJson { param($o) $o.tiering.jit.removeStanding = $true }

# PAM feature off: JIT stays off, and the group is managed as before.
Add-ADGroupMember -Identity 'GG-Domain-Admins-Tier0' -Members 'mayonej'
$r = Converge Build -DataFile $jitOn
Check 'JIT without PAM: reported, group still managed' ($r.Errors -eq 0 -and $r.Output -match 'Privileged Access Management optional feature is off' -and
    -not ((MembersOf 'GG-Domain-Admins-Tier0') -contains 'mayonej'))
$r = Converge Build -DataFile $removeOnly
Check 'removeStanding without JIT: refused' ($r.Output -match 'removeStanding is true, but JIT is not active' -and (MembersOf 'Domain Admins') -contains 'adm_mayonej')

# PAM on: a grant with a time to live survives, standing members are reported.
Enable-FakePam
Add-FakeObject "CN=adm_test,OU=Admin-Accounts,$new" 'user' @{ Sam = 'adm_test' } | Out-Null
Add-ADGroupMember -Identity 'GG-Domain-Admins-Tier0' -Members 'adm_test' -MemberTimeToLive (New-TimeSpan -Hours 1)
$r = Converge Build -DataFile $jitOn
Check 'JIT on: TTL grant kept and logged' ($r.Errors -eq 0 -and (MembersOf 'GG-Domain-Admins-Tier0') -contains 'adm_test' -and
    $r.Output -match 'INFO\s+JIT grant in GG-Domain-Admins-Tier0: CN=adm_test,[^\n]*60 min left')
Check 'JIT on: standing member reported, not removed' ((MembersOf 'GG-Domain-Admins-Tier0') -contains 'adm_mayonej' -and
    $r.Output -match 'REPORT\s+CN=Jasper Mayone \(Admin\),[^\n]*is a standing member of GG-Domain-Admins-Tier0')
$r = Converge Build -DataFile $jitOn
Check 'JIT on: rerun has zero changes' ($r.Changes -eq 0 -and $r.Errors -eq 0)

# removeStanding needs a direct Domain Admins path that does not use JIT.
Remove-ADGroupMember -Identity 'Domain Admins' -Members 'svc-ansible'
$r = Converge Build -DataFile $jitRemove
Check 'removeStanding refused without a direct Domain Admins fallback' ($r.Output -match 'no enabled admin account is a direct member of Domain Admins' -and
    (MembersOf 'GG-Domain-Admins-Tier0') -contains 'adm_mayonej')
Add-ADGroupMember -Identity 'Domain Admins' -Members 'svc-ansible'

$before = Get-FakeADState
$r = Converge Build -DataFile $jitRemove -WhatIf
Check 'removeStanding -WhatIf changes nothing' ((Get-FakeADState) -eq $before -and $r.Output -match 'WOULD\s+Remove standing admin adm_mayonej')
$r = Converge Build -DataFile $jitRemove
Check 'removeStanding: adm_mayonej loses standing admin' ($r.Errors -eq 0 -and -not ((MembersOf 'GG-Domain-Admins-Tier0') -contains 'adm_mayonej') -and
    -not ((MembersOf 'Domain Admins') -contains 'adm_mayonej') -and -not ((MembersOf 'Enterprise Admins') -contains 'adm_mayonej') -and
    -not ((MembersOf 'DnsAdmins') -contains 'adm_mayonej'))
Check 'removeStanding: grant, svc-ansible, eligibility and PSO stay' ((MembersOf 'GG-Domain-Admins-Tier0') -contains 'adm_test' -and
    (MembersOf 'Domain Admins') -contains 'svc-ansible' -and (MembersOf 'GG-T0-Eligible') -contains 'adm_mayonej' -and
    (PsoSubjects 'PSO-Tier0') -eq 'GG-Domain-Admins-Tier0,GG-T0-Eligible')

# --- Built-in Administrator guard ---------------------------------------------
# The built-in account is renamed, and another user has its old name. The
# script must find it by SID. The admin account is disabled, so the built-in
# account must stay enabled.
New-BaseDirectory -AdminName 'breakglass'
Add-FakeObject "CN=Administrator,CN=Users,$dom" 'user' @{ Sam = 'Administrator' } | Out-Null
Add-FakeObject "CN=Jasper Mayone (Admin),CN=Users,$dom" 'user' @{ Sam = 'adm_mayonej'; Enabled = $false } | Out-Null
$r = Converge Build
Check 'guard: built-in Administrator stays enabled while no admin account can log in' ($r.Errors -eq 0 -and (U 'breakglass').Enabled -and
    $r.Output -match 'REPORT\s+built-in Administrator breakglass \(S-1-5-21-[0-9-]+-500\) stays enabled')
Enable-FakeUser 'adm_mayonej'
$before = Get-FakeADState
$r = Converge Build -WhatIf
Check 'guard: -WhatIf shows the disable and changes nothing' ((Get-FakeADState) -eq $before -and $r.Output -match 'WOULD\s+Disable built-in Administrator breakglass')
$r = Converge Build
Check 'guard: built-in Administrator found by SID and disabled' ($r.Errors -eq 0 -and -not (U 'breakglass').Enabled -and (U 'Administrator').Enabled)

# --- Tier 0 safety -------------------------------------------------------------
# The admin account is enabled but has no Domain Admins path yet. The run that
# adds the tier 0 path must not also remove the daily account.
New-BaseDirectory
Add-FakeObject "CN=Jasper Mayone,CN=Users,$dom" 'user' @{ Sam = 'mayonej' } | Out-Null
Add-FakeObject "CN=Jasper Mayone (Admin),CN=Users,$dom" 'user' @{ Sam = 'adm_mayonej' } | Out-Null
Add-ADGroupMember -Identity 'Domain Admins' -Members 'mayonej'
$r = Converge Build
Check 'tier 0: path added, daily account kept in the same run' ($r.Errors -eq 0 -and (MembersOf 'Domain Admins') -contains 'mayonej' -and
    (MembersOf 'Domain Admins') -contains 'GG-Domain-Admins-Tier0' -and (MembersOf 'GG-Domain-Admins-Tier0') -contains 'adm_mayonej')
Disable-ADAccount -Identity 'adm_mayonej'
$r = Converge Build
Check 'tier 0: daily account kept while the admin account is disabled' ((MembersOf 'Domain Admins') -contains 'mayonej')
Enable-FakeUser 'adm_mayonej'
$r = Converge Build
Check 'tier 0: daily account removed in the next run' ($r.Errors -eq 0 -and -not ((MembersOf 'Domain Admins') -contains 'mayonej'))

Remove-Item -Recurse -Force $logDir
if ($script:failed) { Write-Host "$script:failed checks failed"; exit 1 }
Write-Host 'all checks passed'
