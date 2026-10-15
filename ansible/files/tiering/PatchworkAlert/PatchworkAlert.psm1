# Sends one alert mail to security@ through the Google Workspace SMTP relay,
# and writes the same text to the Application log first, so the event stays
# on the DC when the mail fails.
#
# ansible/ad.yml (-t breakglass-alert, -t jit-endpoint) installs this module
# and writes the relay settings to C:\ProgramData\Patchwork\alerts\mail.json.
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
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Subject,
        [Parameter(Mandatory)][string]$Body,
        # Application log source. Ansible creates Patchwork-Alert and Patchwork-JIT.
        [string]$Source = 'Patchwork-Alert',
        [int]$EventId = 1000
    )
    $cfg = Get-Content -Raw -Path $script:ConfigPath | ConvertFrom-Json
    $fqdn = Get-PatchworkHostName
    $text = "{0}`r`n`r`nHost: {1}`r`nTime (UTC): {2:u}" -f $Body, $fqdn, (Get-Date).ToUniversalTime()

    try {
        Write-EventLog -LogName Application -Source $Source -EventId $EventId -EntryType Warning -Message "$Subject`r`n`r`n$text"
    } catch {
        Write-Warning "Cannot write to the Application log: $($_.Exception.Message)"
    }

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
