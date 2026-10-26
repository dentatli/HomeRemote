[CmdletBinding()]
param([string]$OutputDirectory)
$ErrorActionPreference='Stop'
if(-not $OutputDirectory){$OutputDirectory=Join-Path $PSScriptRoot 'dist'}
Set-StrictMode -Version Latest
$compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if(-not (Test-Path -LiteralPath $compiler)){throw 'Windows x64 .NET Framework 4 compiler is required.'}
$runtime=Join-Path $PSScriptRoot 'src\Runtime'
$temporary=Join-Path $PSScriptRoot '.build'
[void](New-Item -ItemType Directory -Path $temporary,$OutputDirectory -Force)
$files=@(Get-ChildItem -LiteralPath $runtime -File | Sort-Object Name)
foreach($file in $files|Where-Object Extension -eq '.ps1'){
 $tokens=$null;$errors=$null
 [void][Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
 if($errors.Count){throw ($errors|Out-String)}
}
$hashText=(@($files|ForEach-Object {(Get-FileHash -LiteralPath $_.FullName).Hash}) -join '')
$sha=[Security.Cryptography.SHA256]::Create()
try{$id=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($hashText)))).Replace('-','').Substring(0,16)}finally{$sha.Dispose()}
$source=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'src\Launcher.cs')).Replace('RUNTIME_BUILD_ID',$id)
$generated=Join-Path $temporary 'Launcher.Build.cs'
[IO.File]::WriteAllText($generated,$source,[Text.UTF8Encoding]::new($true))
$exe=Join-Path $OutputDirectory 'HomeRemote.exe'
$compilerArguments=@('/nologo','/target:winexe','/platform:x64','/optimize+',
 '/reference:System.Windows.Forms.dll','/reference:System.Drawing.dll','/reference:System.Security.dll',
 ('/win32manifest:'+(Join-Path $PSScriptRoot 'src\HomeRemote.manifest')),
 ('/win32icon:'+(Join-Path $PSScriptRoot 'assets\HomeRemote.ico')),('/out:'+$exe))
foreach($file in $files){$compilerArguments+=('/resource:'+$file.FullName+',HomeRemote.Runtime.'+$file.Name)}
$compilerArguments+=$generated
& $compiler @compilerArguments
if($LASTEXITCODE -ne 0){throw 'Compilation failed.'}
[pscustomobject]@{Exe=$exe;RuntimeId=$id;Sha256=(Get-FileHash -LiteralPath $exe).Hash}
