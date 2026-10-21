<#
.SYNOPSIS
    Adds the Patchwork IKEv2 VPN (thimble, vpn.patchworklabs.org) to Windows.

.DESCRIPTION
    Makes a native Windows IKEv2 connection with EAP-MSCHAPv2 and a split
    tunnel. ansible/README.md, "VPN", tells how to use and test it.

    - No secrets. Windows asks for the user name and the password when you
      connect. Use the daily account (jasper@patchworklabs.org), not an admin
      account: accounts in Protected Users cannot use MS-CHAPv2.
    - The IPsec values match proposal 1 of PW-IKE and PW-ESP on thimble:
      AES-256, SHA-256, DH group 14, PFS group 14. Change both sides together.
    - Only 10.100.90.0/24, 10.100.91.0/24 and 10.100.92.0/24 go through the
      VPN. Other traffic uses the local network.
    - If a connection with the same name exists, the script removes it first.

.PARAMETER Name
    The connection name. Default: Patchwork VPN.

.PARAMETER AllUserConnection
    Adds the connection for all users of the computer (needs an elevated
    session). Without it, the connection is only for the current user.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Add-PatchworkVpn.ps1
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Name = 'Patchwork VPN',
    [switch]$AllUserConnection
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$server = 'vpn.patchworklabs.org'
$dnsSuffix = 'patchwork.internal'
$routes = @('10.100.90.0/24', '10.100.91.0/24', '10.100.92.0/24')
$scope = @{}
if ($AllUserConnection) { $scope.AllUserConnection = $true }

if (-not $PSCmdlet.ShouldProcess($Name, "Add IKEv2 VPN to $server")) { return }

if (Get-VpnConnection -Name $Name @scope -ErrorAction SilentlyContinue) {
    Remove-VpnConnection -Name $Name -Force @scope
}

# New-EapConfiguration with no parameters gives EAP-MSCHAPv2 ("secured
# password"). thimble sends EAP to NPS on shuttle, which allows only this
# method.
$eap = New-EapConfiguration

Add-VpnConnection -Name $Name -ServerAddress $server -TunnelType Ikev2 `
    -EncryptionLevel Required -AuthenticationMethod Eap `
    -EapConfigXmlStream $eap.EapConfigXmlStream `
    -SplitTunneling -DnsSuffix $dnsSuffix -Force @scope

Set-VpnConnectionIPsecConfiguration -ConnectionName $Name `
    -AuthenticationTransformConstants SHA256128 -CipherTransformConstants AES256 `
    -EncryptionMethod AES256 -IntegrityCheckMethod SHA256 `
    -DHGroup Group14 -PfsGroup PFS2048 -Force @scope

foreach ($r in $routes) {
    Add-VpnConnectionRoute -ConnectionName $Name -DestinationPrefix $r @scope
}

# Windows also adds a class-based route for the client address (10.0.0.0/8
# for 10.100.93.x). That route sends other 10.x networks to the VPN, where
# thimble drops them. DisableClassBasedDefaultRoute=1 in the phone book
# stops it. Not tested on every Windows build: check `route print` after
# you connect.
$pbk = if ($AllUserConnection) {
    Join-Path $env:ProgramData 'Microsoft\Network\Connections\Pbk\rasphone.pbk'
} else {
    Join-Path $env:APPDATA 'Microsoft\Network\Connections\Pbk\rasphone.pbk'
}
if (Test-Path $pbk) {
    $lines = [System.Collections.Generic.List[string]](Get-Content -Path $pbk)
    $start = $lines.IndexOf("[$Name]")
    if ($start -ge 0) {
        $end = $lines.Count
        for ($i = $start + 1; $i -lt $lines.Count; $i++) {
            if ($lines[$i].StartsWith('[')) { $end = $i; break }
        }
        $found = $false
        for ($i = $start + 1; $i -lt $end; $i++) {
            if ($lines[$i] -like 'DisableClassBasedDefaultRoute=*') {
                $lines[$i] = 'DisableClassBasedDefaultRoute=1'; $found = $true
            }
        }
        if (-not $found) { $lines.Insert($start + 1, 'DisableClassBasedDefaultRoute=1') }
        Set-Content -Path $pbk -Value $lines
    } else {
        Write-Warning "No [$Name] section in $pbk. Check the routes after you connect."
    }
}

Get-VpnConnection -Name $Name @scope |
    Select-Object Name, ServerAddress, TunnelType, AuthenticationMethod, SplitTunneling, DnsSuffix
Write-Host "Connect in Settings > Network & internet > VPN, or run: rasphone -d `"$Name`". Windows asks for the user name and the password."
