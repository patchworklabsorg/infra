@{
    RootModule        = 'PatchworkAlert.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '3cda87c4-0b2c-48db-bbf1-545b10edbb72'
    Author            = 'Patchwork Labs'
    Description       = 'Alert mail to security@ through the Google Workspace SMTP relay. Installed by ansible/ad.yml.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @('Send-PatchworkAlert')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
