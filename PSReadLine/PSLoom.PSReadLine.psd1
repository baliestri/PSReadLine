@{
RootModule = 'PSReadLine.psm1'
NestedModules = @("PSLoom.PSReadLine.dll")
ModuleVersion = '3.0.0'
GUID = 'd39d564f-c4f0-4b4c-b1c2-bd7a84deacab'
Author = 'Microsoft Corporation'
CompanyName = 'Microsoft Corporation'
Copyright = '(c) Microsoft Corporation. All rights reserved.'
Description = 'Great command line editing in the PowerShell console host'
PowerShellVersion = '7.4'
FormatsToProcess = 'PSReadLine.format.ps1xml'
AliasesToExport = @()
FunctionsToExport = 'PSConsoleHostReadLine'
CmdletsToExport = 'Get-PSReadLineKeyHandler','Set-PSReadLineKeyHandler','Remove-PSReadLineKeyHandler',
                  'Get-PSReadLineOption','Set-PSReadLineOption'
HelpInfoURI = 'https://aka.ms/powershell75-help'
}
