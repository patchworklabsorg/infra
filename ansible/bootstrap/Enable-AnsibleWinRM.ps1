<#
.SYNOPSIS
  One-time WinRM enablement for an Ansible-managed Windows host.

.DESCRIPTION
  Run once, elevated, on each Windows host before the first Ansible run. This
  is the per-host equivalent of a GPO on the Servers OU and is the only part
  of the Windows path Ansible cannot do for itself (it cannot connect yet).

  It does four things and nothing else:
    1. Enables the WinRM HTTP listener on 5985 and sets the service to
       Automatic.
    2. Adds a firewall rule for 5985 that ignores the network profile. The
       built-in rule only matches Domain/Private; a host that comes up with
       its interface on Public silently drops Ansible.
    3. Confirms Negotiate (NTLM) authentication is enabled on the service.
       Ansible connects with ansible_winrm_transport: ntlm.
    4. Leaves AllowUnencrypted off. NTLM message-encrypts the payload, so the
       HTTP listener is acceptable and no certificate is needed.

  Nothing here creates accounts. Ansible connects as PATCHWORK\svc-ansible,
  which already exists in the forest.

.PARAMETER RemoteAddress
  CIDR(s) allowed to reach 5985: the subnet of the Ansible control node.
  Required. There is no default, because the control node is not on a
  Patchwork VLAN.

.EXAMPLE
  PS> .\Enable-AnsibleWinRM.ps1 -RemoteAddress <control-node-cidr>
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string[]]$RemoteAddress
)

$ErrorActionPreference = 'Stop'

Write-Host '[1/4] Enabling PSRemoting and the WinRM service'
Enable-PSRemoting -Force -SkipNetworkProfileCheck | Out-Null
Set-Service -Name WinRM -StartupType Automatic
Start-Service -Name WinRM

Write-Host '[2/4] Firewall rule for TCP 5985, all profiles, scoped to the control subnet(s)'
$ruleName = 'WinRM-HTTP-Ansible'
$existing = Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue
if ($existing) {
    Set-NetFirewallRule -Name $ruleName -RemoteAddress $RemoteAddress -Enabled True
} else {
    New-NetFirewallRule -Name $ruleName -DisplayName 'WinRM HTTP (Ansible control node)' `
        -Direction Inbound -Protocol TCP -LocalPort 5985 -Action Allow `
        -Profile Any -RemoteAddress $RemoteAddress | Out-Null
}

Write-Host '[3/4] Negotiate (NTLM) auth on, Basic off'
Set-Item -Path WSMan:\localhost\Service\Auth\Negotiate -Value $true
Set-Item -Path WSMan:\localhost\Service\Auth\Basic     -Value $false

Write-Host '[4/4] Keep the payload encrypted'
Set-Item -Path WSMan:\localhost\Service\AllowUnencrypted -Value $false

Write-Host ''
Write-Host 'Listener state:'
Get-ChildItem -Path WSMan:\localhost\Listener | Where-Object { $_.Keys -contains 'Transport=HTTP' } | Format-Table -AutoSize
Write-Host 'Done. From the control node:'
Write-Host '  ansible windows -m ansible.windows.win_ping -l <host>'
