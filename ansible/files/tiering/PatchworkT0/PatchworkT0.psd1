@{
    RootModule        = 'PatchworkT0.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'ae921322-800c-4769-b659-974766daf170'
    Author            = 'Patchwork Labs'
    Description       = 'Just-in-time Tier 0 admin for the PatchworkT0 JEA endpoint. Installed by ansible/ad.yml -t jit-endpoint.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @('Request-T0Admin', 'Get-T0AdminGrant')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
