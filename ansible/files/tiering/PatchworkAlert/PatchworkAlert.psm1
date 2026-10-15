# Writes one alert to the Application log of the DC. It sends a mail to
# security@ through the Google Workspace SMTP relay only when "enabled" is
# true in mail.json. The mail is off by default (ad_alert_mail_enabled).
#
# ansible/ad.yml (-t breakglass-alert, -t jit-endpoint) installs this module
# and writes the settings to C:\ProgramData\Patchwork\alerts\mail.json.
# The relay accepts the lab WAN address without a login (IP authentication),
# so this file holds no secret.

Set-StrictMode -Version Latest

$script:ConfigPath = Join-Path $env:ProgramData 'Patchwork\alerts\mail.json'

function Get-PatchworkHostName {
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem
    ("{0}.{1}" -f $env:COMPUTERNAME, $cs.Domain).ToLowerInvariant()
}

function Send-PatchworkAlert {
    [CmdletBinding()]
    [OutputType([bool])]  # True only when a mail was sent
    param(
        [Parameter(Mandatory)][string]$Subject,
        [Parameter(Mandatory)][string]$Body,
        # Application log source. Ansible creates Patchwork-Alert and Patchwork-JIT.
        [string]$Source = 'Patchwork-Alert',
        [int]$EventId = 1000
    )
    $cfg = $null
    try { $cfg = Get-Content -Raw -Path $script:ConfigPath | ConvertFrom-Json } catch { Write-Verbose "No mail settings: $($_.Exception.Message)" }
    $mailEnabled = $null -ne $cfg -and $cfg.PSObject.Properties['enabled'] -and [bool]$cfg.enabled
    $fqdn = Get-PatchworkHostName
    $text = "{0}`r`n`r`nHost: {1}`r`nTime (UTC): {2:u}" -f $Body, $fqdn, (Get-Date).ToUniversalTime()

    # The event is the alert. It is always written, with or without mail.
    try {
        Write-EventLog -LogName Application -Source $Source -EventId $EventId -EntryType Warning -Message "$Subject`r`n`r`n$text"
    } catch {
        Write-Warning "Cannot write to the Application log: $($_.Exception.Message)"
    }

    if (-not $mailEnabled) { return $false }

    $msg = New-Object System.Net.Mail.MailMessage($cfg.from, $cfg.to, "[$($cfg.subjectPrefix)] $Subject", $text)
    $smtp = New-Object System.Net.Mail.SmtpClient($cfg.host, [int]$cfg.port)
    try {
        # Port 587 with EnableSsl is STARTTLS. No credentials: the relay
        # checks the source address.
        $smtp.EnableSsl = $true
        $smtp.UseDefaultCredentials = $false
        $smtp.Timeout = 30000
        # Google asks for a unique EHLO name. SmtpClient sends the bare
        # NetBIOS name; send the FQDN instead. Best effort only.
        try {
            $field = [System.Net.Mail.SmtpClient].GetField('localHostName', [Reflection.BindingFlags]'NonPublic,Instance')
            if ($field) { $field.SetValue($smtp, $fqdn) }
        } catch { Write-Verbose "EHLO name not changed: $($_.Exception.Message)" }
        $smtp.Send($msg)
        return $true
    } catch {
        try {
            Write-EventLog -LogName Application -Source $Source -EventId 1900 -EntryType Error `
                -Message "Alert mail to $($cfg.to) through $($cfg.host):$($cfg.port) failed: $($_.Exception.Message)`r`n`r`nSubject: $Subject"
        } catch { Write-Verbose 'Cannot log the mail failure.' }
        return $false
    } finally {
        $msg.Dispose()
        $smtp.Dispose()
    }
}

Export-ModuleMember -Function Send-PatchworkAlert
