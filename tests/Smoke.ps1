[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot
$exe=Join-Path $root 'dist\HomeRemote.exe'
if(-not (Test-Path -LiteralPath $exe)){throw 'Run build.ps1 first.'}
$test=Join-Path $root ('.test-work\smoke-'+[guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $test -Force)
Copy-Item -LiteralPath $exe -Destination (Join-Path $test 'HomeRemote.exe')
$log=Join-Path $test 'result.json'
$preview=Join-Path $test 'preview.png'
$arguments=@('--preview','--smoke-test','--smoke-exit-failure','--capture-path',('"'+$preview+'"'),'--smoke-log',('"'+$log+'"'))
$process=Start-Process -FilePath (Join-Path $test 'HomeRemote.exe') -ArgumentList $arguments -WindowStyle Hidden -PassThru
if(-not $process.WaitForExit(45000)){throw 'Smoke test timeout: inspect the test window.'}
if($process.ExitCode -ne 0){throw 'EXE returned an error.'}
$result=Get-Content -LiteralPath $log -Raw | ConvertFrom-Json
if($result.Error -or -not $result.IsOff -or ($result.Events -join ',') -ne 'State,Start,Stop,Stop'){throw ('Smoke test failed: '+($result|ConvertTo-Json))}
'PASS: WPF, primary button, hide/restore, failed exit and successful retry. Real remote access untouched.'
