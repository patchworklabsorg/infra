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
    foreach ($g in @(@('Domain Admins', 512), @('Enterprise Admins', 519), @('Schema Admins', 518))) {
        Add-FakeObject "CN=$($g[0]),CN=Users,$dom" 'group' @{ Sam = $g[0]; Scope = 'Global'; Sid = "$domainSid-$($g[1])" } | Out-Null
    }
    Add-FakeObject "CN=Administrators,CN=Builtin,$dom" 'group' @{ Sam = 'Administrators'; Scope = 'DomainLocal'; Sid = 'S-1-5-32-544' } | Out-Null
    Add-FakeObject "CN=Account Operators,CN=Builtin,$dom" 'group' @{ Sam = 'Account Operators'; Scope = 'DomainLocal'; Sid = 'S-1-5-32-548' } | Out-Null
    $a = Add-FakeObject "CN=$AdminName,CN=Users,$dom" 'user' @{ Sam = $AdminName; Sid = "$domainSid-500" }
    $a.Attrs['adminCount'] = 1
    Add-ADGroupMember -Identity 'Domain Admins' -Members $AdminName
    $dcOU = Add-FakeObject "OU=Domain Controllers,$dom" 'organizationalUnit' @{ Protected = $true }
    Add-FakeDefaultOUAces $dcOU
    foreach ($dc in 'LOOM', 'SPINDLE') {
        Add-FakeObject "CN=$dc,OU=Domain Controllers,$dom" 'computer' @{ Sam = "$dc`$" } | Out-Null
    }
    # AdminSDHolder with a part of its default ACL.
    Add-FakeObject "CN=System,$dom" 'container' | Out-Null
    $h = Add-FakeObject "CN=AdminSDHolder,CN=System,$dom" 'container'
    foreach ($ace in @(@('S-1-5-18', 983551), @("$domainSid-512", 983551), @('S-1-5-11', 131220), @('S-1-5-32-544', 983551))) {
        $h.Acl.Add((New-FakeAce $ace[0] $ace[1]))
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
# SDProp state: the admin accounts are protected. mayonej was a Domain Admin,
# so it still has adminCount=1. svc-ansible has none yet. A person gave
# stranger a right on AdminSDHolder.
$adm.Attrs['adminCount'] = 1
$mayonej.Attrs['adminCount'] = 1
Add-FakeAce "CN=AdminSDHolder,CN=System,$dom" (New-FakeAce $stranger.Sid 32)

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
Check 'Build -WhatIf shows the PSOs' ($r.Output -match 'WOULD\s+Create PSO[^\n]*PSO-Tier0' -and $r.Output -match 'Apply to service-accounts : PSO PSO-Service')

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
Check 'board members' (((MembersOf 'board') | Sort-Object) -join ',' -eq 'klukask,mayonej,petrarcad')
Check 'board is Global in Roles' ((G 'board').GroupScope -eq 'Global' -and (G 'board').DistinguishedName -like "*,OU=Roles,OU=Groups,$new")
Check 'service-accounts members' (((MembersOf 'service-accounts') | Sort-Object) -join ',' -eq 'svc-ansible,svc-dhcp-dns,svc-lnx-join,svc-pve-ldap,svc-service,svc-weave-ldap')
Check 'svc-service gets UPN service@patchworklabs.org' ((Get-ADUser -Filter "SamAccountName -eq 'svc-service'" -Properties UserPrincipalName).UserPrincipalName -eq 'service@patchworklabs.org')
Check 'cj gets the HackBoston domain from the OU' ((Get-ADUser -Filter "SamAccountName -eq 'cj'" -Properties UserPrincipalName).UserPrincipalName -eq 'cj@hackboston.dev')
Check 'wei gets the hackathon.help domain from the OU' ((Get-ADUser -Filter "SamAccountName -eq 'wei'" -Properties UserPrincipalName).UserPrincipalName -eq 'wei@hackathon.help')
Check 'staff keep patchworklabs.org' ((Get-ADUser -Filter "SamAccountName -eq 'mayonej'" -Properties UserPrincipalName).UserPrincipalName -eq 'jasper@patchworklabs.org')
Check 'project UPN suffixes added to the forest' ((Get-ADForest).UPNSuffixes -contains 'hackboston.dev' -and (Get-ADForest).UPNSuffixes -contains 'hackathon.help')
Check 'lnx-warp-users created DomainLocal' ((G 'lnx-warp-users').GroupScope -eq 'DomainLocal')
Check 'lnx-skein-users holds only infra' (((MembersOf 'lnx-skein-users') -join ',') -eq 'infra')
Check 'tier 0 group in Domain Admins' ((MembersOf 'Domain Admins') -contains 'tier0-admins')
Check 'adm_mayonej in tier 0 group' ((MembersOf 'tier0-admins') -contains 'adm_mayonej')
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
    $t0.LockoutDuration -eq [TimeSpan]::FromMinutes(30) -and $t0.MaxPasswordAge.Ticks -le 0 -and (PsoSubjects 'PSO-Tier0') -eq 'tier0-admins,tier0-eligible')
$sv = Get-ADFineGrainedPasswordPolicy -Identity 'PSO-Service'
Check 'PSO-Service' ($sv.MinPasswordLength -eq 32 -and $sv.LockoutThreshold -eq 0 -and (PsoSubjects 'PSO-Service') -eq 'service-accounts')
$st = Get-ADFineGrainedPasswordPolicy -Identity 'PSO-Staff'
Check 'PSO-Staff' ($st.MinPasswordLength -eq 14 -and $st.LockoutThreshold -eq 10 -and (PsoSubjects 'PSO-Staff') -eq 'all-staff')

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
Check 'tier0-eligible holds adm_mayonej' (((MembersOf 'tier0-eligible') -join ',') -eq 'adm_mayonej')
Check 'Administrator leaves Enterprise Admins and Schema Admins, stays in Domain Admins' (-not ((MembersOf 'Enterprise Admins') -contains 'Administrator') -and
    -not ((MembersOf 'Schema Admins') -contains 'Administrator') -and (MembersOf 'Domain Admins') -contains 'Administrator' -and
    $r.Output -notmatch 'Administrator is a direct member of (Enterprise|Schema) Admins')
Check 'JIT off: standing admin reported, not removed' ((MembersOf 'DnsAdmins') -contains 'adm_mayonej' -and
    $r.Output -match 'adm_mayonej is a standing member of DnsAdmins' -and $r.Output -match 'adm_mayonej is a direct member of Enterprise Admins')

# Delegation
$userGuid = 'bf967aba-0de6-11d0-a285-00aa003049e2'
$computerGuid = 'bf967a86-0de6-11d0-a285-00aa003049e2'
$resetGuid = '00299570-246d-11d0-a768-00aa006e0529'
function SidOf([string]$Sam) { (Get-ADObject -Filter "SamAccountName -eq '$Sam'").SID }
function AcesFor([string]$DN, [string]$Sam) { @(Get-FakeAces $DN | Where-Object { $_.IdentityReference.Value -eq (SidOf $Sam) }) }
Check 'role groups tier1-admins and tier2-helpdesk exist, Global, empty' (
    @('tier1-admins', 'tier2-helpdesk' | Where-Object { (G $_).GroupScope -eq 'Global' -and (G $_).DistinguishedName -like "*,OU=Roles,OU=Groups,$new" -and -not @(MembersOf $_).Count }).Count -eq 2)
Check 'access groups are DomainLocal in Resources and hold the role groups (AGDLP)' ((G 'password-reset').GroupScope -eq 'DomainLocal' -and
    (G 'server-computer-admin').DistinguishedName -eq "CN=server-computer-admin,OU=Resources,OU=Groups,$new" -and
    ((MembersOf 'password-reset' | Sort-Object) -join ',') -eq 'tier1-admins,tier2-helpdesk' -and ((MembersOf 'server-computer-admin') -join ',') -eq 'tier1-admins')
$helpdeskOUs = "OU=Staff,OU=Users,$new", "OU=Board-Only,OU=Users,$new", "OU=Sponsored-Projects,OU=Users,$new"
Check 'helpdesk: reset, unlock, pwdLastSet, read on user objects in the three people OUs' (@($helpdeskOUs | Where-Object {
            $a = @(AcesFor $_ 'password-reset')
            $a.Count -eq 4 -and @($a | Where-Object { $_.AccessControlType -eq 'Allow' -and "$($_.InheritedObjectType)" -eq $userGuid -and $_.PropagationFlags -eq 'InheritOnly' }).Count -eq 4 -and
            @($a | Where-Object { "$($_.ObjectType)" -eq $resetGuid -and $_.ActiveDirectoryRights -eq 256 }).Count -eq 1
        }).Count -eq 3)
Check 'computer admin: create/delete and full control on Servers and Computers' (@("OU=Servers,$new", "OU=Computers,$new" | Where-Object {
            $a = @(AcesFor $_ 'server-computer-admin')
            $a.Count -eq 2 -and @($a | Where-Object { $_.ActiveDirectoryRights -eq 983551 -and "$($_.InheritedObjectType)" -eq $computerGuid }).Count -eq 1 -and
            @($a | Where-Object { $_.ActiveDirectoryRights -eq 3 -and "$($_.ObjectType)" -eq $computerGuid }).Count -eq 1
        }).Count -eq 2)
Check 'deny on Admin-Accounts and Service-Accounts for both access groups, no allow' (@("OU=Admin-Accounts,$new", "OU=Service-Accounts,$new" | ForEach-Object {
            $dn = $_; 'password-reset', 'server-computer-admin' | Where-Object {
                $a = @(AcesFor $dn $_); $a.Count -eq 2 -and -not ($a | Where-Object { $_.AccessControlType -ne 'Deny' }) -and
                @($a | Where-Object { $_.ActiveDirectoryRights -eq 256 -and $_.InheritanceFlags -eq 'ContainerInherit' -and $_.PropagationFlags -eq 'None' }).Count -eq 1
            } }).Count -eq 4)
Check 'deny on Servers/Tier0 for both access groups and svc-lnx-join' (@('password-reset', 'server-computer-admin', 'svc-lnx-join' | Where-Object {
            @(AcesFor "OU=Tier0,OU=Servers,$new" $_ | Where-Object { $_.AccessControlType -eq 'Deny' }).Count -eq 2 }).Count -eq 3)
Check 'no delegation on Members, Disabled, Domain Controllers, Admin-Accounts/Tier1' (@("OU=Members,OU=Users,$new", "OU=Disabled,$new", "OU=Domain Controllers,$dom", "OU=Tier1,OU=Admin-Accounts,$new" | Where-Object {
            @(AcesFor $_ 'password-reset').Count -or @(AcesFor $_ 'server-computer-admin').Count }).Count -eq 0)
Check 'AdminSDHolder: extra ACE and adminCount drift reported' ($r.Output -match 'AdminSDHolder has a non-default ACE: Allow 32 for stranger' -and
    $r.Output -match 'REPORT\s+mayonej has adminCount=1, but delegation.expectAdminCount' -and $r.Output -match 'REPORT\s+svc-ansible has no adminCount=1' -and
    $r.Output -notmatch 'adm_mayonej has (no )?adminCount' -and $r.Output -notmatch 'Administrator has adminCount')
Check 'admin account in the old tree: reported for Migrate, not moved by Build' ((U 'adm_mayonej').DistinguishedName -like "*,$old" -and
    $r.Output -match 'adm_mayonej is in OU=Admin-Accounts,OU=Administrative,OU=Patchwork-Objects[^\n]*Migrate moves it')

# Weave: svc-weave-ldap, its rights on the people OUs and Users/Members, and
# the denies that keep it off admin, service, Tier 0 and disabled accounts.
$changePwGuid = 'ab721a53-1e2f-11d0-9819-00aa0040529b'
$employeeIdGuid = 'bf967962-0de6-11d0-a285-00aa003049e2'
$weave = U 'svc-weave-ldap'
Check 'svc-weave-ldap created disabled in Service-Accounts, must change password' ($weave -and -not $weave.Enabled -and
    $weave.DistinguishedName -eq "CN=svc-weave-ldap,OU=Service-Accounts,$new" -and
    (Get-FakeADState) -match "CN=svc-weave-ldap,[^|]*\|user\|False\|[^|]*\|[^|]*\|[^|]*pwdLastSet=0")
Check 'svc-weave-ldap is reported until an admin enables it' ((Converge Build -WhatIf).Output -match 'REPORT\s+svc-weave-ldap is disabled')
Check 'Weave on the three people OUs: reset, change, unlock, read; nothing else' (@($helpdeskOUs | Where-Object {
            $a = @(AcesFor $_ 'svc-weave-ldap')
            $a.Count -eq 4 -and @($a | Where-Object { $_.AccessControlType -eq 'Allow' -and "$($_.InheritedObjectType)" -eq $userGuid -and $_.PropagationFlags -eq 'InheritOnly' }).Count -eq 4 -and
            @($a | Where-Object { "$($_.ObjectType)" -eq $resetGuid -and $_.ActiveDirectoryRights -eq 256 }).Count -eq 1 -and
            @($a | Where-Object { "$($_.ObjectType)" -eq $changePwGuid -and $_.ActiveDirectoryRights -eq 256 }).Count -eq 1 -and
            -not ($a | Where-Object { "$($_.ObjectType)" -eq $employeeIdGuid })
        }).Count -eq 3)
$membersOU = "OU=Members,OU=Users,$new"
$m = @(AcesFor $membersOU 'svc-weave-ldap')
Check 'Weave on Users/Members: create users, passwords, employeeID and its attributes, no delete' ($m.Count -eq 13 -and
    -not ($m | Where-Object { $_.AccessControlType -ne 'Allow' }) -and
    @($m | Where-Object { $_.ActiveDirectoryRights -eq 1 -and "$($_.ObjectType)" -eq $userGuid -and $_.PropagationFlags -eq 'None' }).Count -eq 1 -and
    @($m | Where-Object { $_.ActiveDirectoryRights -eq 48 -and "$($_.ObjectType)" -eq $employeeIdGuid -and "$($_.InheritedObjectType)" -eq $userGuid }).Count -eq 1 -and
    -not ($m | Where-Object { ($_.ActiveDirectoryRights -band (2 + 64 + 65536 + 262144 + 524288)) -ne 0 }))
Check 'Weave denied on Admin-Accounts, Service-Accounts, Servers/Tier0, Disabled; no allow there' (@("OU=Admin-Accounts,$new", "OU=Service-Accounts,$new", "OU=Tier0,OU=Servers,$new", "OU=Disabled,$new" | Where-Object {
            $a = @(AcesFor $_ 'svc-weave-ldap'); $a.Count -eq 2 -and -not ($a | Where-Object { $_.AccessControlType -ne 'Deny' })
        }).Count -eq 4)
Check 'Weave has nothing on the Domain Controllers OU, Admin-Accounts/Tier0, Groups, Servers' (@("OU=Domain Controllers,$dom", "OU=Tier0,OU=Admin-Accounts,$new", "OU=Groups,$new", "OU=Servers,$new", "OU=Users,$new" | Where-Object {
            @(AcesFor $_ 'svc-weave-ldap').Count }).Count -eq 0)
Check 'Weave ACEs are not reported as extra' ($r.Output -notmatch 'extra ACE[^\n]*svc-weave-ldap')
Check 'a person with no weaveId is reported' ($r.Output -match 'REPORT\s+daniel has no weaveId' -and $r.Output -notmatch 'svc-weave-ldap has no weaveId')

$r = Converge Build
Check 'Build twice: zero changes' ($r.Changes -eq 0 -and $r.Errors -eq 0)
if ($r.Changes) { Write-Host $r.Output }

# Delegation drift: a hand-made extra right on Admin-Accounts, one managed
# ACE removed, and the join account's known ACE on Servers.
Add-FakeAce "OU=Admin-Accounts,$new" (New-FakeAce (SidOf 'board') 983551)
Add-FakeAce "OU=Servers,$new" (New-FakeAce (SidOf 'svc-lnx-join') 3 'Allow' ([guid]$computerGuid))
Remove-FakeAces "OU=Staff,OU=Users,$new" { $_.IdentityReference.Value -eq (SidOf 'password-reset') -and "$($_.ObjectType)" -eq $resetGuid }
$before = Get-FakeADState
$r = Converge Build -WhatIf
Check 'delegation drift -WhatIf changes nothing' ((Get-FakeADState) -eq $before -and $r.Output -match 'WOULD\s+Allow for password-reset: reset password : OU=Staff')
$r = Converge Build
Check 'delegation drift: missing ACE added back, nothing else changed' ($r.Errors -eq 0 -and $r.Changes -eq 1 -and
    @(AcesFor "OU=Staff,OU=Users,$new" 'password-reset' | Where-Object { "$($_.ObjectType)" -eq $resetGuid }).Count -eq 1)
Check 'delegation drift: extra ACE reported and kept, known ACE not reported' ($r.Output -match "OU=Admin-Accounts,$new has an extra ACE: allow 983551 for board" -and
    @(AcesFor "OU=Admin-Accounts,$new" 'board').Count -eq 1 -and $r.Output -notmatch 'extra ACE[^\n]*svc-lnx-join')
Remove-FakeAces "OU=Admin-Accounts,$new" { $_.IdentityReference.Value -eq (SidOf 'board') }

# weaveId -> employeeID. daniel gets one. cj asks for an id that a
# Weave member already holds: reported, not set. Without the key, Build
# leaves employeeID alone.
Set-ADUser -Identity 'member1' -Replace @{ employeeID = 'PWL2000000001' }
$withIds = New-OrgJson { param($o)
    ($o.users | Where-Object { $_.sam -eq 'daniel' }) | Add-Member -Force -NotePropertyName weaveId -NotePropertyValue 'PWL1A2B3C4D5E'
    ($o.users | Where-Object { $_.sam -eq 'cj' }) | Add-Member -Force -NotePropertyName weaveId -NotePropertyValue 'PWL2000000001'
}
$before = Get-FakeADState
$r = Converge Build -DataFile $withIds -WhatIf
Check 'weaveId -WhatIf changes nothing and shows the employeeID' ((Get-FakeADState) -eq $before -and
    $r.Output -match "WOULD\s+Set employeeID='PWL1A2B3C4D5E' : CN=daniel")
$r = Converge Build -DataFile $withIds
Check 'weaveId set as employeeID' ($r.Errors -eq 0 -and (U 'daniel').employeeID -eq 'PWL1A2B3C4D5E' -and
    $r.Output -notmatch 'daniel has no weaveId')
Check 'weaveId held by another account: reported, not set' ($r.Output -match 'REPORT\s+cj: weaveId PWL2000000001 is the employeeID of member1' -and
    $null -eq (U 'cj').employeeID -and (U 'member1').employeeID -eq 'PWL2000000001')
$r = Converge Build -DataFile $withIds
Check 'weaveId: rerun has zero changes' ($r.Changes -eq 0 -and $r.Errors -eq 0)
$r = Converge Build
Check 'weaveId absent: employeeID not cleared' ($r.Changes -eq 0 -and (U 'daniel').employeeID -eq 'PWL1A2B3C4D5E')

# A Weave member holds the sam of a new org.json entry. Build must not take
# it over: no attributes, no groups (infra gives sudo on Tier 1).
Add-FakeObject "CN=newstaff,OU=Members,OU=Users,$new" 'user' @{ Sam = 'newstaff' } | Out-Null
$takeover = New-OrgJson { param($o)
    $o.users += [pscustomobject]@{ sam = 'newstaff'; kind = 'person'; ou = 'Users/Staff'; givenName = 'New'; surname = 'Staff'
        division = 'Programs'; department = 'Programs'; title = 'Volunteer'; manager = $null }
    ($o.roleGroups | Where-Object { $_.name -eq 'infra' }).members += 'newstaff'
}
$r = Converge Build -DataFile $takeover
Check 'a member with a new sam: reported, not changed, not added to groups' ($r.Errors -eq 0 -and
    $r.Output -match 'REPORT\s+newstaff is CN=newstaff,OU=Members,OU=Users,[^\n]*another system owns' -and
    $r.Output -match 'REPORT\s+newstaff is [^\n]*so it was not added to infra' -and
    -not ((MembersOf 'infra') -contains 'newstaff') -and $null -eq (U 'newstaff').title -and
    (U 'newstaff').DistinguishedName -eq "CN=newstaff,OU=Members,OU=Users,$new")
# newstaff stays in Users/Members. Build ignores it from now on.

# A member that became staff still has Weave as its owner: reported.
(Find-Fake 'adam.sidwa').Owner = 'PATCHWORK\svc-weave-ldap'
$r = Converge Build
Check 'a managed account owned by svc-weave-ldap is reported' ($r.Errors -eq 0 -and $r.Changes -eq 0 -and
    $r.Output -match 'REPORT\s+adam.sidwa is owned by PATCHWORK\\svc-weave-ldap')
(Find-Fake 'adam.sidwa').Owner = $null

# Drift: a changed PSO, an extra subject and an unknown PSO.
Set-ADFineGrainedPasswordPolicy -Identity 'PSO-Staff' -MinPasswordLength 8
Add-ADFineGrainedPasswordPolicySubject -Identity 'PSO-Staff' -Subjects 'board'
New-ADFineGrainedPasswordPolicy -Name 'PSO-Old' -Precedence 99
$r = Converge Build
Check 'PSO drift fixed' ((Get-ADFineGrainedPasswordPolicy -Identity 'PSO-Staff').MinPasswordLength -eq 14 -and (PsoSubjects 'PSO-Staff') -eq 'all-staff' -and $r.Errors -eq 0)
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
Check 'adm_mayonej moved to Admin-Accounts/Tier0' ((U 'adm_mayonej').DistinguishedName -eq "CN=Jasper Mayone (Admin),OU=Tier0,OU=Admin-Accounts,$new")
Check 'klukask moved to Board-Only' ((U 'klukask').DistinguishedName -eq "CN=Kieran Klukas,OU=Board-Only,OU=Users,$new")
Check 'svc-ansible moved to Admin-Accounts/Tier0' ((U 'svc-ansible').DistinguishedName -eq "CN=svc-ansible,OU=Tier0,OU=Admin-Accounts,$new")
foreach ($svc in 'svc-lnx-join', 'svc-dhcp-dns', 'svc-pve-ldap') {
    Check "$svc moved to Service-Accounts" ((U $svc).DistinguishedName -eq "CN=$svc,OU=Service-Accounts,$new")
}
Check 'vi moved to Disabled' ((U 'vi').DistinguishedName -eq "CN=vi,OU=Disabled,$new")
Check 'member1 moved to Users/Members' ((U 'member1').DistinguishedName -eq "CN=member1,OU=Members,OU=Users,$new")
Check 'lnx-skein-users DomainLocal in Resources' ((G 'lnx-skein-users').GroupScope -eq 'DomainLocal' -and (G 'lnx-skein-users').DistinguishedName -eq "CN=lnx-skein-users,OU=Resources,OU=Groups,$new")
Check 'SKEIN moved to Servers' ([bool](Get-ADObject -Filter "distinguishedName -eq 'CN=SKEIN,OU=Servers,$new'"))
Check 'BOBBIN and SHUTTLE (Tier 0) moved to Servers/Tier0' ([bool](Get-ADObject -Filter "distinguishedName -eq 'CN=BOBBIN,OU=Tier0,OU=Servers,$new'") -and
    [bool](Get-ADObject -Filter "distinguishedName -eq 'CN=SHUTTLE,OU=Tier0,OU=Servers,$new'"))
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

# Build moves an object down into a child OU of its OU: the live state
# before the tier OUs (adm_mayonej in Admin-Accounts, BOBBIN in Servers).
Move-ADObject -Identity 'adm_mayonej' -TargetPath "OU=Admin-Accounts,$new"
Move-ADObject -Identity 'BOBBIN$' -TargetPath "OU=Servers,$new"
Set-ADObject -Identity 'BOBBIN$' -ProtectedFromAccidentalDeletion $true
Set-ADObject -Identity 'mayonej' -ProtectedFromAccidentalDeletion $false
Move-ADObject -Identity 'mayonej' -TargetPath "OU=Disabled,$new"
$before = Get-FakeADState
$r = Converge Build -WhatIf
Check 'move down -WhatIf changes nothing' ((Get-FakeADState) -eq $before -and
    $r.Output -match "WOULD\s+Move to OU=Tier0,OU=Admin-Accounts,$new \(a child OU of its OU\) : CN=Jasper Mayone \(Admin\)" -and
    $r.Output -match "WOULD\s+Move to OU=Tier0,OU=Servers,$new [^\n]*: CN=BOBBIN")
$r = Converge Build
Check 'move down: adm_mayonej to Tier0, BOBBIN to Servers/Tier0, still protected, still in the silo' ($r.Errors -eq 0 -and
    (U 'adm_mayonej').DistinguishedName -eq "CN=Jasper Mayone (Admin),OU=Tier0,OU=Admin-Accounts,$new" -and
    (Get-ADObject -Filter "SamAccountName -eq 'BOBBIN$'").DistinguishedName -eq "CN=BOBBIN,OU=Tier0,OU=Servers,$new" -and
    (Get-ADObject -Filter "SamAccountName -eq 'BOBBIN$'").ProtectedFromAccidentalDeletion -and (SiloSams) -match 'adm_mayonej' -and (SiloSams) -match 'BOBBIN')
Check 'move up or sideways is only reported' ((U 'mayonej').DistinguishedName -eq "CN=Jasper Mayone,OU=Disabled,$new" -and
    $r.Output -match "mayonej is in OU=Disabled,$new, not OU=Staff,OU=Users,$new")
Move-ADObject -Identity 'mayonej' -TargetPath "OU=Staff,OU=Users,$new"
Set-ADObject -Identity 'mayonej' -ProtectedFromAccidentalDeletion $true

# --- Just-in-time admin ---------------------------------------------------------
$jitOn = New-OrgJson { param($o) $o.tiering.jit.enabled = $true }
$jitRemove = New-OrgJson { param($o) $o.tiering.jit.enabled = $true; $o.tiering.jit.removeStanding = $true }
$removeOnly = New-OrgJson { param($o) $o.tiering.jit.removeStanding = $true }

# PAM feature off: JIT stays off, and the group is managed as before.
Add-ADGroupMember -Identity 'tier0-admins' -Members 'mayonej'
$r = Converge Build -DataFile $jitOn
Check 'JIT without PAM: reported, group still managed' ($r.Errors -eq 0 -and $r.Output -match 'Privileged Access Management optional feature is off' -and
    -not ((MembersOf 'tier0-admins') -contains 'mayonej'))
$r = Converge Build -DataFile $removeOnly
Check 'removeStanding without JIT: refused' ($r.Output -match 'removeStanding is true, but JIT is not active' -and (MembersOf 'Domain Admins') -contains 'adm_mayonej')

# PAM on: a grant with a time to live survives, standing members are reported.
Enable-FakePam
Add-FakeObject "CN=adm_test,OU=Admin-Accounts,$new" 'user' @{ Sam = 'adm_test' } | Out-Null
Add-ADGroupMember -Identity 'tier0-admins' -Members 'adm_test' -MemberTimeToLive (New-TimeSpan -Hours 1)
$r = Converge Build -DataFile $jitOn
Check 'JIT on: TTL grant kept and logged' ($r.Errors -eq 0 -and (MembersOf 'tier0-admins') -contains 'adm_test' -and
    $r.Output -match 'INFO\s+JIT grant in tier0-admins: CN=adm_test,[^\n]*60 min left')
Check 'JIT on: standing member reported, not removed' ((MembersOf 'tier0-admins') -contains 'adm_mayonej' -and
    $r.Output -match 'REPORT\s+CN=Jasper Mayone \(Admin\),[^\n]*is a standing member of tier0-admins')
$r = Converge Build -DataFile $jitOn
Check 'JIT on: rerun has zero changes' ($r.Changes -eq 0 -and $r.Errors -eq 0)

# removeStanding needs a direct Domain Admins path that does not use JIT.
Remove-ADGroupMember -Identity 'Domain Admins' -Members 'svc-ansible'
$r = Converge Build -DataFile $jitRemove
Check 'removeStanding refused without a direct Domain Admins fallback' ($r.Output -match 'no enabled admin account is a direct member of Domain Admins' -and
    (MembersOf 'tier0-admins') -contains 'adm_mayonej')
Add-ADGroupMember -Identity 'Domain Admins' -Members 'svc-ansible'

$before = Get-FakeADState
$r = Converge Build -DataFile $jitRemove -WhatIf
Check 'removeStanding -WhatIf changes nothing' ((Get-FakeADState) -eq $before -and $r.Output -match 'WOULD\s+Remove standing admin adm_mayonej')
$r = Converge Build -DataFile $jitRemove
Check 'removeStanding: adm_mayonej loses standing admin' ($r.Errors -eq 0 -and -not ((MembersOf 'tier0-admins') -contains 'adm_mayonej') -and
    -not ((MembersOf 'Domain Admins') -contains 'adm_mayonej') -and -not ((MembersOf 'Enterprise Admins') -contains 'adm_mayonej') -and
    -not ((MembersOf 'DnsAdmins') -contains 'adm_mayonej'))
Check 'removeStanding: grant, svc-ansible, eligibility and PSO stay' ((MembersOf 'tier0-admins') -contains 'adm_test' -and
    (MembersOf 'Domain Admins') -contains 'svc-ansible' -and (MembersOf 'tier0-eligible') -contains 'adm_mayonej' -and
    (PsoSubjects 'PSO-Tier0') -eq 'tier0-admins,tier0-eligible')

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
    (MembersOf 'Domain Admins') -contains 'tier0-admins' -and (MembersOf 'tier0-admins') -contains 'adm_mayonej')
Disable-ADAccount -Identity 'adm_mayonej'
$r = Converge Build
Check 'tier 0: daily account kept while the admin account is disabled' ((MembersOf 'Domain Admins') -contains 'mayonej')
Enable-FakeUser 'adm_mayonej'
$r = Converge Build
Check 'tier 0: daily account removed in the next run' ($r.Errors -eq 0 -and -not ((MembersOf 'Domain Admins') -contains 'mayonej'))

# --- Group renames (formerNames) -------------------------------------------------
# The live directory after the first Build on 2026-10-14 has the GG-/DL-
# names. A copy of org.json with those names makes that state. Build with
# the real org.json must rename each group in place: same object and SID,
# so members, nesting, PSO subjects, ACEs and Domain Admins stay.
$orgNow = Get-Content -Raw (Join-Path $PSScriptRoot '../../ad/org.json') | ConvertFrom-Json
$renames = [ordered]@{}
foreach ($g in @($orgNow.roleGroups) + @($orgNow.resourceGroups)) {
    if ($g.PSObject.Properties['formerNames']) { $renames[$g.name] = @($g.formerNames)[0] }
}
function New-LegacyOrgJson {
    $text = Get-Content -Raw (Join-Path $PSScriptRoot '../../ad/org.json')
    $text = $text -replace '"formerNames":\s*\[[^\]]*\],\s*', ''
    foreach ($k in $renames.Keys) { $text = $text.Replace("`"$k`"", "`"$($renames[$k])`"") }
    $f = Join-Path $logDir ("org-legacy-" + [guid]::NewGuid() + '.json')
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    Set-Content -Path $f -Value $text
    $f
}
New-BaseDirectory
Add-FakeObject "CN=Jasper Mayone (Admin),CN=Users,$dom" 'user' @{ Sam = 'adm_mayonej' } | Out-Null
foreach ($svc in 'svc-ansible', 'svc-lnx-join', 'svc-dhcp-dns', 'svc-pve-ldap') {
    Add-FakeObject "CN=$svc,CN=Users,$dom" 'user' @{ Sam = $svc } | Out-Null
}
$legacy = New-LegacyOrgJson
Converge Build -DataFile $legacy | Out-Null
Converge Build -DataFile $legacy | Out-Null
$r = Converge Build -DataFile $legacy
Check 'rename setup: the GG-/DL- names converge, zero changes' ($r.Changes -eq 0 -and $r.Errors -eq 0 -and
    [bool](G 'GG-Infra') -and -not (G 'infra') -and @($renames.Keys).Count -eq 17)
if ($r.Changes) { Write-Host $r.Output }
Set-ADGroup -Identity 'GG-Board' -DisplayName 'GG-Board'
Set-ADGroup -Identity 'GG-President' -DisplayName 'The President'
$sidBefore = @{}
foreach ($k in $renames.Keys) { $sidBefore[$k] = (G $renames[$k]).SID }
$staffOU = "OU=Staff,OU=Users,$new"
$acesBefore = @(AcesFor $staffOU 'DL-Users-PasswordReset').Count
$expected = 2 * $renames.Count + 1

$before = Get-FakeADState
$r = Converge Build -WhatIf
Check 'rename -WhatIf changes nothing' ((Get-FakeADState) -eq $before -and $r.Errors -eq 0)
Check 'rename -WhatIf shows each rename (sAMAccountName and CN) and the displayName' (
    @($renames.Keys | Where-Object {
            $r.Output -match "WOULD\s+Rename group $([regex]::Escape($renames[$_])) to $([regex]::Escape($_)) \(sAMAccountName\)" -and
            $r.Output -match "WOULD\s+Rename group CN $([regex]::Escape($renames[$_])) to $([regex]::Escape($_)) :"
        }).Count -eq $renames.Count -and $r.Output -match "WOULD\s+Set displayName 'board' \(was GG-Board\)")
Check 'rename -WhatIf: no create, no member, PSO or ACE change, only the renames' ($r.Changes -eq $expected -and
    $r.Output -notmatch 'Create (Global|DomainLocal) group' -and $r.Output -notmatch 'WOULD\s+(Add|Remove) member' -and
    $r.Output -notmatch 'Apply to|Stop applying' -and $r.Output -notmatch '\(after it is created\)' -and $r.Output -notmatch 'not allowed in org.json')
if ($r.Changes -ne $expected) { Write-Host $r.Output }

$r = Converge Build
Check 'rename: no errors, only the renames' ($r.Errors -eq 0 -and $r.Changes -eq $expected -and $r.Output -notmatch 'Create (Global|DomainLocal) group')
if ($r.Errors -or $r.Changes -ne $expected) { Write-Host $r.Output }
Check 'rename: same object (SID) under each new name and CN, old names gone' (
    @($renames.Keys | Where-Object { (G $_) -and (G $_).SID -eq $sidBefore[$_] -and (G $_).Name -ceq $_ -and -not (G $renames[$_]) }).Count -eq $renames.Count)
Check 'rename: members, nesting, PSO subjects, Domain Admins and ACEs stay' (
    (((MembersOf 'board') | Sort-Object) -join ',') -eq 'klukask,mayonej,petrarcad' -and
    ((MembersOf 'lnx-skein-users') -join ',') -eq 'infra' -and (MembersOf 'Domain Admins') -contains 'tier0-admins' -and
    ((MembersOf 'password-reset' | Sort-Object) -join ',') -eq 'tier1-admins,tier2-helpdesk' -and
    (PsoSubjects 'PSO-Tier0') -eq 'tier0-admins,tier0-eligible' -and (PsoSubjects 'PSO-Service') -eq 'service-accounts' -and
    $acesBefore -eq 4 -and @(AcesFor $staffOU 'password-reset').Count -eq 4)
Check 'rename: a displayName with the old name follows, another displayName stays' (
    (Get-ADGroup -Identity 'board').displayName -eq 'board' -and (Get-ADGroup -Identity 'president').displayName -eq 'The President')
$r = Converge Build
Check 'rename: rerun has zero changes' ($r.Changes -eq 0 -and $r.Errors -eq 0)
if ($r.Changes) { Write-Host $r.Output }

# A rename that stopped after the sAMAccountName: the next run renames the CN.
Rename-ADObject -Identity 'infra' -NewName 'GG-Infra'
$r = Converge Build
Check 'rename: a half-done rename is finished by the next run' ($r.Errors -eq 0 -and $r.Changes -eq 1 -and (G 'infra').Name -ceq 'infra' -and
    $r.Output -match 'CHANGE\s+Rename group CN GG-Infra to infra')

# Both names exist: somebody made a new GG-Infra. Build reports it and does
# not touch either group, or the groups that hold infra.
Add-FakeObject "CN=GG-Infra,OU=Roles,OU=Groups,$new" 'group' @{ Sam = 'GG-Infra'; Scope = 'Global' } | Out-Null
Add-ADGroupMember -Identity 'GG-Infra' -Members 'klukask'
$before = Get-FakeADState
$r = Converge Build -WhatIf
Check 'both names exist, -WhatIf: reported, nothing would change' ((Get-FakeADState) -eq $before -and $r.Changes -eq 0 -and
    $r.Output -match 'REPORT\s+Group infra exists more than once')
$r = Converge Build
Check 'both names exist: reported, neither group nor anything that names it is touched' ((Get-FakeADState) -eq $before -and
    $r.Changes -eq 0 -and $r.Errors -eq 0 -and $r.Output -match 'REPORT\s+Group infra exists more than once: ' -and
    $r.Output -match 'Members of lnx-skein-users were not changed' -and $r.Output -match 'Members of infra were not changed' -and
    ((MembersOf 'lnx-skein-users') -join ',') -eq 'infra' -and ((MembersOf 'GG-Infra') -join ',') -eq 'klukask' -and
    ((MembersOf 'infra') -join ',') -eq 'mayonej')
Remove-ADGroup -Identity 'GG-Infra'
$r = Converge Build
Check 'both names exist: after the extra group is deleted, zero changes' ($r.Changes -eq 0 -and $r.Errors -eq 0 -and $r.Output -notmatch 'more than once')

# The live order: the new name is taken BEFORE the rename. A user holds
# password-reset, and somebody made an empty group infra. Neither may get the
# rights, members or memberships of the real groups.
New-BaseDirectory
Add-FakeObject "CN=Jasper Mayone (Admin),CN=Users,$dom" 'user' @{ Sam = 'adm_mayonej' } | Out-Null
foreach ($svc in 'svc-ansible', 'svc-lnx-join', 'svc-dhcp-dns', 'svc-pve-ldap') {
    Add-FakeObject "CN=$svc,CN=Users,$dom" 'user' @{ Sam = $svc } | Out-Null
}
Converge Build -DataFile $legacy | Out-Null
Converge Build -DataFile $legacy | Out-Null
Add-FakeObject "CN=password-reset,CN=Users,$dom" 'user' @{ Sam = 'password-reset' } | Out-Null
Add-FakeObject "CN=infra,OU=Roles,OU=Groups,$new" 'group' @{ Sam = 'infra'; Scope = 'Global' } | Out-Null
$before = Get-FakeADState
$r = Converge Build -WhatIf
Check 'new name taken before the rename, -WhatIf: reported, no ACE or member line for them' ((Get-FakeADState) -eq $before -and
    $r.Output -match 'REPORT\s+Group password-reset: a user has this sAMAccountName' -and $r.Output -match 'REPORT\s+Group infra exists more than once' -and
    $r.Output -notmatch '(Allow|Deny) for password-reset' -and $r.Output -notmatch 'Rename group (DL-Users-PasswordReset|GG-Infra)' -and
    $r.Output -notmatch 'WOULD\s+(Add|Remove) member[^\n]*: lnx-')
$r = Converge Build
Check 'new name taken before the rename: the user and the empty group get nothing, the real groups keep their names' ($r.Errors -eq 0 -and
    @(Get-FakeAces $staffOU | Where-Object { $_.IdentityReference.Value -eq (SidOf 'password-reset') }).Count -eq 0 -and
    -not @(MembersOf 'infra').Count -and ((MembersOf 'lnx-skein-users') -join ',') -eq 'GG-Infra' -and
    [bool](G 'DL-Users-PasswordReset') -and [bool](G 'GG-Infra') -and (G 'board').Name -ceq 'board' -and
    -not (Get-ADPrincipalGroupMembership -Identity 'password-reset' | Where-Object { $_.Name -ne 'Domain Users' }))

Remove-Item -Recurse -Force $logDir
if ($script:failed) { Write-Host "$script:failed checks failed"; exit 1 }
Write-Host 'all checks passed'
