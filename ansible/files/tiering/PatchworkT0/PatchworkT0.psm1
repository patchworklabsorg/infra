# Just-in-time Tier 0 admin. Runs inside the PatchworkT0 JEA endpoint on
# each DC. The endpoint runs as a virtual account, which is in Domain Admins
# on a DC, so it can change GG-Domain-Admins-Tier0 after AdminSDHolder
# removes every delegated right on that group. Only GG-T0-Eligible can
# connect (RoleDefinitions in PatchworkT0.pssc).
#
# A grant is a membership with a time to live (the AD Privileged Access
# Management feature). The DC removes it when the time ends, and the KDC
# caps every Kerberos ticket at the time that is left.
#
# ansible/ad.yml -t jit-endpoint installs this module and writes the limits
# from ad/org.json (tiering.jit) to C:\ProgramData\Patchwork\jea\jit.json.

Set-StrictMode -Version Latest
Import-Module ActiveDirectory

$script:ConfigPath = Join-Path $env:ProgramData 'Patchwork\jea\jit.json'
$script:PamFeature = 'Privileged Access Management Feature'

function Get-T0Config {
    Get-Content -Raw -Path $script:ConfigPath | ConvertFrom-Json
}

# The person who connected, not the virtual account the endpoint runs as.
function Get-T0Caller {
    $name = $null
    if ($PSSenderInfo) {
        if ($PSSenderInfo.PSObject.Properties['ConnectedUser']) { $name = $PSSenderInfo.ConnectedUser }
        if (-not $name) { $name = $PSSenderInfo.UserInfo.Identity.Name }
    }
    if (-not $name) { throw 'Request-T0Admin runs only inside the PatchworkT0 endpoint.' }
    ($name -split '\\', 2)[-1]
}

# Members of the JIT group: DN and the seconds left (null = standing).
function Get-T0Member($Cfg) {
    $g = Get-ADGroup -Identity $Cfg.group -Properties member -ShowMemberTimeToLive
    foreach ($m in @($g.member)) {
        if ("$m" -match '^<TTL=(\d+)>,(.+)$') {
            [pscustomobject]@{ DN = $Matches[2]; Seconds = [int]$Matches[1] }
        } else {
            [pscustomobject]@{ DN = "$m"; Seconds = $null }
        }
    }
}

function Assert-T0Pam {
    $f = Get-ADOptionalFeature -Identity $script:PamFeature
    if (-not @($f.EnabledScopes).Count) {
        throw "The AD '$($script:PamFeature)' is off. Without it a grant would never expire, so no grant is made."
    }
}

<#
.SYNOPSIS
    Makes the caller a Domain Admin for 1 to 4 hours.
.DESCRIPTION
    Adds the caller to GG-Domain-Admins-Tier0 with a time to live. Writes
    event 1000 (source Patchwork-JIT) to the Application log of this DC. It
    sends a mail to security@ only when mail is enabled (Mailed is then True). An open grant is reused, not extended.
    After the grant, run "klist purge" or log on again: only a new TGT
    carries Domain Admins.
.EXAMPLE
    Request-T0Admin -Hours 1 -Reason 'Change the Client-Baseline firewall rule'
#>
function Request-T0Admin {
    [CmdletBinding()]
    param(
        [ValidateRange(1, 4)]
        [int]$Hours = 0,
        [Parameter(Mandatory)]
        [ValidateLength(8, 300)]
        [string]$Reason
    )
    $cfg = Get-T0Config
    if (-not $Hours) { $Hours = [int]$cfg.defaultHours }
    if ($Hours -gt [int]$cfg.maxHours) { throw "The maximum grant is $($cfg.maxHours) hours." }
    Assert-T0Pam

    $sam = Get-T0Caller
    $user = Get-ADUser -Identity $sam
    $eligible = @(Get-ADGroupMember -Identity $cfg.eligible -Recursive | ForEach-Object { "$($_.SID)" })
    if ($eligible -notcontains "$($user.SID)") { throw "$sam is not in $($cfg.eligible)." }

    $now = (Get-Date).ToUniversalTime()
    $mine = @(Get-T0Member $cfg | Where-Object { $_.DN -eq $user.DistinguishedName })
    if ($mine.Count -and $null -eq $mine[0].Seconds) {
        return [pscustomobject]@{
            Account = $sam; Group = $cfg.group; Status = 'standing'; ExpiresUtc = $null
            Next = "$sam is a standing member of $($cfg.group). No grant is needed or made."
        }
    }
    if ($mine.Count) {
        return [pscustomobject]@{
            Account = $sam; Group = $cfg.group; Status = 'open'; ExpiresUtc = $now.AddSeconds($mine[0].Seconds).ToString('u')
            Next = 'A grant is already open. It is not extended. Request again after it ends.'
        }
    }

    Add-ADGroupMember -Identity $cfg.group -Members $user -MemberTimeToLive (New-TimeSpan -Hours $Hours)
    $expires = $now.AddHours($Hours)

    $body = @"
$sam is a member of $($cfg.group) (Domain Admins) until $($expires.ToString('u')).

Hours:   $Hours
Reason:  $Reason
DC:      $env:COMPUTERNAME

The DC removes the membership when the time ends. If you did not expect
this grant, remove it now: Remove-ADGroupMember $($cfg.group) $sam
"@
    Import-Module PatchworkAlert
    $mailed = Send-PatchworkAlert -Subject "JIT grant: $sam is Domain Admin for $Hours h" -Body $body -Source 'Patchwork-JIT' -EventId 1000

    [pscustomobject]@{
        Account    = $sam
        Group      = $cfg.group
        Status     = 'granted'
        Hours      = $Hours
        ExpiresUtc = $expires.ToString('u')
        Mailed     = $mailed
        Next       = 'Run "klist purge" or log on again. The new TGT carries Domain Admins until the grant ends.'
    }
}

<#
.SYNOPSIS
    Lists the members of GG-Domain-Admins-Tier0 and the time left for each grant.
#>
function Get-T0AdminGrant {
    [CmdletBinding()]
    param()
    $cfg = Get-T0Config
    $now = (Get-Date).ToUniversalTime()
    foreach ($m in Get-T0Member $cfg) {
        $u = Get-ADObject -Identity $m.DN -Properties sAMAccountName
        [pscustomobject]@{
            Account     = $u.sAMAccountName
            Kind        = if ($null -eq $m.Seconds) { 'standing' } else { 'grant' }
            MinutesLeft = if ($null -eq $m.Seconds) { $null } else { [math]::Ceiling($m.Seconds / 60) }
            ExpiresUtc  = if ($null -eq $m.Seconds) { $null } else { $now.AddSeconds($m.Seconds).ToString('u') }
        }
    }
}

Export-ModuleMember -Function Request-T0Admin, Get-T0AdminGrant
