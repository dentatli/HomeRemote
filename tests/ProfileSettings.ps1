$ErrorActionPreference='Stop'
$project=Split-Path $PSScriptRoot
$t=$null;$e=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $project 'src\Runtime\HomeRemote-Certificates.ps1'),[ref]$t,[ref]$e)
if($e.Count){throw ($e|Out-String)}
$function=$ast.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -eq 'Get-ProfileConnection'}
Invoke-Expression $function.Extent.Text
$work=Join-Path $project ('.test-work\settings-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $work 'EasyRSA') -Force|Out-Null
$script:Root=Join-Path $work 'EasyRSA'
$checks=0
function ExpectFailure([scriptblock]$Action){$failed=$false;try{& $Action}catch{$failed=$true};if(-not $failed){throw 'Expected settings rejection'};$script:checks++}
ExpectFailure {Get-ProfileConnection}
foreach($settings in @(
 @{ServerHost="vpn.example.invalid`nscript-security 2";ServerPort=443;ServerCertificateName='HomeRemote-Server'},
 @{ServerHost='vpn.example.invalid';ServerPort=0;ServerCertificateName='HomeRemote-Server'},
 @{ServerHost='vpn.example.invalid';ServerPort=443;ServerCertificateName='Server invalid'}
)){
 $settings|ConvertTo-Json|Set-Content (Join-Path $work 'HomeRemote.settings.json') -Encoding UTF8
 ExpectFailure {Get-ProfileConnection}
}
Copy-Item -LiteralPath (Join-Path $project 'HomeRemote.settings.example.json') -Destination (Join-Path $work 'HomeRemote.settings.json') -Force
$value=Get-ProfileConnection
if($value.HostName -ne 'vpn.example.invalid' -or $value.Port -ne 443){throw 'Example parsing failed'};$checks++
$newDevice=$ast.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -eq 'New-Device'}
if($newDevice.Extent.Text.IndexOf('[void](Get-ProfileConnection)') -gt $newDevice.Extent.Text.IndexOf('Invoke-EasyRSA')){throw 'Settings must be checked before issuing a certificate'};$checks++
"PASS: $checks local settings checks; no certificate or process operations."
