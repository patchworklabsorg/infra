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
function Converge([string]$Phase, [switch]$WhatIf) {
    $out = & $Converge -Phase $Phase -LogDir $logDir -WhatIf:$WhatIf 6>&1 2>&1 | Out-String
    if ($out -notmatch 'END\s+(\d+) changes, (\d+) reports, (\d+) errors') { throw "No END line:`n$out" }
    @{ Changes = [int]$Matches[1]; Reports = [int]$Matches[2]; Errors = [int]$Matches[3]; Output = $out }
}

function U([string]$Sam) { Get-ADUser -Filter "SamAccountName -eq '$Sam'" }
function G([string]$Sam) { Get-ADGroup -Filter "SamAccountName -eq '$Sam'" }
function MembersOf([string]$Group) { @(Get-ADGroupMember -Identity $Group | ForEach-Object { $_.SamAccountName }) }

# --- The directory as recorded on 2026-08-23, plus test objects ----------------
Reset-FakeAD
Add-FakeObject "CN=Users,$dom" 'container' | Out-Null
Add-FakeObject "CN=Builtin,$dom" 'container' | Out-Null
foreach ($g in 'Domain Admins', 'Enterprise Admins', 'Schema Admins') {
    Add-FakeObject "CN=$g,CN=Users,$dom" 'group' @{ Sam = $g; Scope = 'Global' } | Out-Null
}
Add-FakeObject "CN=Administrators,CN=Builtin,$dom" 'group' @{ Sam = 'Administrators'; Scope = 'DomainLocal' } | Out-Null
Add-FakeObject "CN=Administrator,CN=Users,$dom" 'user' @{ Sam = 'Administrator' } | Out-Null

foreach ($ou in 'Patchwork-Objects', 'Staff-Production,OU=Patchwork-Objects', 'Staff-Computers,OU=Staff-Production,OU=Patchwork-Objects',
    'Infrastructure,OU=Patchwork-Objects', 'Member-Servers,OU=Infrastructure,OU=Patchwork-Objects',
    'Security-Groups,OU=Patchwork-Objects', 'Linux-Access-Control,OU=Security-Groups,OU=Patchwork-Objects',
    'Box-Users,OU=Linux-Access-Control,OU=Security-Groups,OU=Patchwork-Objects',
    'Box-Admins,OU=Linux-Access-Control,OU=Security-Groups,OU=Patchwork-Objects',
    'Service-Accounts,OU=Patchwork-Objects', 'Governance,OU=Patchwork-Objects', 'Members,OU=Patchwork-Objects') {
    Add-FakeObject "OU=$ou,$dom" 'organizationalUnit' @{ Protected = $true } | Out-Null
}
$jasper = Add-FakeObject "CN=jasper,OU=Staff-Production,$old" 'user' @{ Sam = 'jasper'; Protected = $true }
$jasper.Attrs['title'] = 'Founder'
$svcAnsible = Add-FakeObject "CN=svc-ansible,OU=Service-Accounts,$old" 'user' @{ Sam = 'svc-ansible' }
Add-FakeObject "CN=svc-lnx-join,OU=Service-Accounts,$old" 'user' @{ Sam = 'svc-lnx-join' } | Out-Null
Add-FakeObject "CN=vi,OU=Governance,$old" 'user' @{ Sam = 'vi' } | Out-Null
Add-FakeObject "CN=member1,OU=Members,$old" 'user' @{ Sam = 'member1' } | Out-Null
$stranger = Add-FakeObject "CN=stranger,OU=Governance,$old" 'user' @{ Sam = 'stranger' }
$lnxUsers = Add-FakeObject "CN=lnx-skein-users,OU=Box-Users,OU=Linux-Access-Control,OU=Security-Groups,$old" 'group' @{ Sam = 'lnx-skein-users'; Scope = 'Global'; Description = 'Linux logon on skein' }
Add-FakeObject "CN=lnx-skein-admins,OU=Box-Admins,OU=Linux-Access-Control,OU=Security-Groups,$old" 'group' @{ Sam = 'lnx-skein-admins'; Scope = 'Global'; Description = 'Linux sudo on skein' } | Out-Null
Add-FakeObject "CN=SKEIN,OU=Member-Servers,OU=Infrastructure,$old" 'computer' | Out-Null
Add-FakeObject "CN=LAPTOP1,OU=Staff-Computers,OU=Staff-Production,$old" 'computer' | Out-Null
Add-ADGroupMember -Identity 'Domain Admins' -Members 'jasper'
Add-ADGroupMember -Identity 'Domain Admins' -Members 'svc-ansible'
Add-ADGroupMember -Identity 'Domain Admins' -Members 'Administrator'
Add-ADGroupMember -Identity 'lnx-skein-users' -Members 'jasper'
Add-ADGroupMember -Identity 'lnx-skein-users' -Members 'vi'

# --- Build ---------------------------------------------------------------------
$before = Get-FakeADState
$r = Converge Build -WhatIf
Check 'Build -WhatIf changes nothing' ((Get-FakeADState) -eq $before)
Check 'Build -WhatIf lists changes' ($r.Changes -gt 0 -and $r.Errors -eq 0)

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
Check 'adam.sidwa manager is jasper' ($adam.manager -eq (U 'jasper').DistinguishedName)
Check 'kieran has no manager' ($null -eq (U 'kieran').manager)
$j = U 'jasper'
Check 'jasper attributes updated in place' ($j.title -eq 'Founder & Director of Programs' -and $j.DistinguishedName -like "*,$old")
Check 'wei in hackathon.help OU' ((U 'wei').DistinguishedName -eq "CN=wei,OU=hackathon.help,OU=Sponsored-Projects,OU=Users,$new")
Check 'jasper.adm UPN uses the domain' ((U 'jasper.adm').userPrincipalName -eq 'jasper.adm@patchwork.internal')
Check 'svc-ansible not created or changed' ((U 'svc-ansible').DistinguishedName -like "*,$old")
Check 'GG-Board members' (((MembersOf 'GG-Board') | Sort-Object) -join ',' -eq 'dominic,jasper,kieran')
Check 'GG-Board is Global in Roles' ((G 'GG-Board').GroupScope -eq 'Global' -and (G 'GG-Board').DistinguishedName -like "*,OU=Roles,OU=Groups,$new")
Check 'lnx-warp-users created DomainLocal' ((G 'lnx-warp-users').GroupScope -eq 'DomainLocal')
Check 'lnx-skein-users holds only GG-Infra' (((MembersOf 'lnx-skein-users') -join ',') -eq 'GG-Infra')
Check 'tier 0 group in Domain Admins' ((MembersOf 'Domain Admins') -contains 'GG-Domain-Admins-Tier0')
Check 'jasper keeps Domain Admins while jasper.adm is disabled' ((MembersOf 'Domain Admins') -contains 'jasper')
Check 'vi disabled' (-not (U 'vi').Enabled)
Check 'new users must change password' ((Get-FakeADState) -match 'CN=Adam Sidwa,[^|]*\|user\|False\|[^|]*\|[^|]*\|[^|]*pwdLastSet=0')

$r = Converge Build
Check 'Build twice: zero changes' ($r.Changes -eq 0 -and $r.Errors -eq 0)
if ($r.Changes) { Write-Host $r.Output }

Enable-FakeUser 'jasper.adm'
$r = Converge Build
Check 'jasper leaves Domain Admins once jasper.adm is enabled' (-not ((MembersOf 'Domain Admins') -contains 'jasper') -and $r.Errors -eq 0)
Check 'svc-ansible stays in Domain Admins' ((MembersOf 'Domain Admins') -contains 'svc-ansible')

# --- Migrate -------------------------------------------------------------------
$before = Get-FakeADState
$r = Converge Migrate -WhatIf
Check 'Migrate -WhatIf changes nothing' ((Get-FakeADState) -eq $before)

$r = Converge Migrate
Check 'Migrate has no errors' ($r.Errors -eq 0)
if ($r.Errors) { Write-Host $r.Output }
Check 'jasper moved to Staff and still protected' ((U 'jasper').DistinguishedName -eq "CN=jasper,OU=Staff,OU=Users,$new" -and (U 'jasper').ProtectedFromAccidentalDeletion)
Check 'svc-ansible moved to Admin-Accounts' ((U 'svc-ansible').DistinguishedName -eq "CN=svc-ansible,OU=Admin-Accounts,$new")
Check 'svc-lnx-join moved to Service-Accounts' ((U 'svc-lnx-join').DistinguishedName -eq "CN=svc-lnx-join,OU=Service-Accounts,$new")
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

Remove-Item -Recurse -Force $logDir
if ($script:failed) { Write-Host "$script:failed checks failed"; exit 1 }
Write-Host 'all checks passed'
