# Runs from the scheduled task \Patchwork\BreakGlassAlert on each DC, once
# for each matching Security event. The task passes the channel and the
# record ID of the event. ansible/ad.yml -t breakglass-alert installs both.
#
# Events:
#   4624  logon by the built-in Administrator (RID 500)
#   4768  Kerberos TGT request for it
#   4776  NTLM credential validation for it
#   4722  it was enabled
#   4724  its password was reset
#   4728  member added to a privileged global group (Domain Admins,
#         GG-Domain-Admins-Tier0). A JIT grant also makes this event.
#   4732  member added to Administrators
#   4756  member added to Enterprise Admins or Schema Admins
param(
    [Parameter(Mandatory)][string]$Channel,
    [Parameter(Mandatory)][long]$RecordId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module PatchworkAlert

$evt = Get-WinEvent -LogName $Channel -FilterXPath "*[System[EventRecordID=$RecordId]]" -MaxEvents 1
$xml = [xml]$evt.ToXml()
$data = [ordered]@{}
foreach ($d in @($xml.Event.EventData.Data)) {
    if ($d -and $d.Name) { $data[$d.Name] = $d.InnerText }
}

$what = switch ($evt.Id) {
    4624 { 'Logon by the built-in Administrator' }
    4768 { 'Kerberos TGT request for the built-in Administrator' }
    4776 { 'NTLM validation for the built-in Administrator' }
    4722 { 'The built-in Administrator was ENABLED' }
    4724 { 'Password reset on the built-in Administrator' }
    4728 { "Member added to $($data['TargetUserName'])" }
    4732 { "Member added to $($data['TargetUserName'])" }
    4756 { "Member added to $($data['TargetUserName'])" }
    default { "Security event $($evt.Id)" }
}

$fields = 'SubjectUserName', 'SubjectDomainName', 'TargetUserName', 'TargetDomainName', 'TargetSid', 'TargetUserSid',
'MemberName', 'MemberSid', 'IpAddress', 'IpPort', 'WorkstationName', 'Workstation', 'LogonType', 'Status', 'ServiceName'
$lines = foreach ($f in $fields) {
    if ($data.Contains($f) -and $data[$f] -and $data[$f] -ne '-') { '{0,-18} {1}' -f $f, $data[$f] }
}

$body = @"
$what.

Event $($evt.Id) in $Channel, record $RecordId, at $($evt.TimeCreated.ToUniversalTime().ToString('u')).

$($lines -join "`r`n")

If you did not expect this, follow the break-glass section of ad/TIERING.md:
check who did it, reset the password to a new discarded random value
(ad.yml -t administrator-random -e ad_admin_random_force=true) and keep the
account disabled.
"@

Send-PatchworkAlert -Subject "$what on $env:COMPUTERNAME" -Body $body -Source 'Patchwork-Alert' -EventId 1000 | Out-Null
