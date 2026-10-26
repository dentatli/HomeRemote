#requires -Version 5.1
#requires -RunAsAdministrator
[CmdletBinding()]
param([switch]$Library,[string]$DataRoot=$PSScriptRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Root = Join-Path $DataRoot 'EasyRSA'
$script:Pki = Join-Path $script:Root 'pki'
$script:OpenSSL = Join-Path $script:Root 'openssl.exe'
$script:Bridge = Join-Path $PSScriptRoot 'HomeRemote-EasyRSA.sh'
$script:Profiles = Join-Path (Split-Path $script:Root) 'HomeRemote-Profiles'

function Assert-DeviceName([string]$Name) {
    if ($Name -cnotmatch '^HomeRemote-[A-Za-z0-9][A-Za-z0-9_-]{0,48}$' -or
        $Name -ieq 'HomeRemote-Server') {
        throw 'Use HomeRemote-Name (Latin letters, digits, hyphen/underscore). Server is protected.'
    }
}

function Invoke-EasyRSA([string[]]$Arguments) {
    Push-Location $script:Root
    try {
        # No shell interpolation of device names or passwords.
        & (Join-Path $script:Root 'bin\sh.exe') ($script:Bridge.Replace('\','/')) @Arguments | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "EasyRSA failed (exit $LASTEXITCODE). Read the output above." }
    } finally { Pop-Location }
}

function Get-Devices {
    foreach ($line in [IO.File]::ReadAllLines((Join-Path $script:Pki 'index.txt'))) {
        $fields = $line.Split([char]9)
        if ($fields.Count -lt 6) { continue }
        if ($fields[5] -match '(?:^|/)CN=(HomeRemote-[A-Za-z0-9_-]+)(?:/|$)') {
            $name = $Matches[1]
            if ($name -ine 'HomeRemote-Server') {
                [pscustomobject]@{ Name=$name; Status=$fields[0]; ExpiryUTC=$fields[1]; Serial=$fields[3] }
            }
        }
    }
}

function Save-Backup {
    $folder = Join-Path $script:Pki ('management-backups\' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $folder -Force)
    foreach ($name in @('index.txt','index.txt.attr','serial','crlnumber','crl.pem')) {
        $source = Join-Path $script:Pki $name
        if (Test-Path -LiteralPath $source) { Copy-Item -LiteralPath $source -Destination $folder }
    }
    # These snapshots aid diagnosis; never restore index.txt to undo a revocation.
}

function Get-CrlStatus {
    $crl = Join-Path $script:Pki 'crl.pem'
    if (-not (Test-Path -LiteralPath $crl)) { throw 'CRL is missing. Select Update CRL before issuing profiles.' }
    $result = @(& $script:OpenSSL crl -in $crl -noout -lastupdate -nextupdate)
    if ($LASTEXITCODE -ne 0) { throw 'Cannot read CRL.' }
    $next = @($result | Where-Object { $_ -like 'nextUpdate=*' })
    if ($next.Count -ne 1) { throw 'Cannot read CRL expiration.' }
    $date = [DateTime]::ParseExact(
        (($next[0] -replace '^nextUpdate=','') -replace '\s+',' ').Trim(),
        'MMM d HH:mm:ss yyyy "GMT"', [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal)
    $result | Out-Host
    if ($date -le [DateTime]::UtcNow) { throw 'CRL has expired. Update it before connecting.' }
    if ($date -lt [DateTime]::UtcNow.AddDays(30)) { Write-Warning 'CRL expires in less than 30 days. Update it.' }
}

function Update-Crl {
    Save-Backup
    Invoke-EasyRSA @('--days=365','gen-crl')
    Get-CrlStatus
    Write-Host 'CRL updated. OpenVPN reads the configured CRL on new TLS connections.' -ForegroundColor Green
}

function Initialize-ProfileDirectory {
    [void](New-Item -ItemType Directory -Path $script:Profiles -Force)
    $acl = Get-Acl -LiteralPath $script:Profiles
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) { [void]$acl.RemoveAccessRuleSpecific($rule) }
    foreach ($sid in @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value, 'S-1-5-18', 'S-1-5-32-544')) {
        $identity = New-Object Security.Principal.SecurityIdentifier($sid)
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($identity, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $script:Profiles -AclObject $acl
}

function Get-PendingCreationPath {
    Join-Path $script:Pki 'management-pending-creation.json'
}

function Set-PendingCreation($Pending) {
    $path = Get-PendingCreationPath
    $temporary = Join-Path $script:Pki ('.creation-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($temporary, ($Pending | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $path) { [IO.File]::Replace($temporary, $path, [System.Management.Automation.Language.NullString]::Value) }
        else { [IO.File]::Move($temporary, $path) }
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary }
    }
}

function Undo-FailedCreation {
    $pendingPath = Get-PendingCreationPath
    if (-not (Test-Path -LiteralPath $pendingPath)) { return }
    $pending = [IO.File]::ReadAllText($pendingPath) | ConvertFrom-Json
    Assert-DeviceName $pending.Name
    $rows = @(Get-Devices | Where-Object { $_.Name -ceq $pending.Name })
    if ($rows.Count -eq 0 -and [string]::IsNullOrEmpty($pending.Serial)) {
        if (Test-Path -LiteralPath (Join-Path $script:Pki ('issued\' + $pending.Name + '.crt'))) {
            throw 'Rollback stopped: a certificate file exists without a matching CA entry.'
        }
        foreach ($part in @(("private\{0}.key" -f $pending.Name), ("reqs\{0}.req" -f $pending.Name))) {
            $path = Join-Path $script:Pki $part
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
        }
        Remove-Item -LiteralPath $pendingPath
        Write-Host 'Создание отменено до выпуска сертификата.' -ForegroundColor Yellow
        return
    }
    if ($rows.Count -ne 1 -or (-not [string]::IsNullOrEmpty($pending.Serial) -and $rows[0].Serial -cne $pending.Serial)) {
        throw 'Rollback stopped: certificate identity does not match the saved operation.'
    }
    $serial = $rows[0].Serial
    if ($serial -notmatch '^[A-Fa-f0-9]+$') { throw 'Invalid certificate serial; rollback stopped.' }
    if ($rows[0].Status -eq 'V') {
        # Only the newly issued certificate from the failed operation is revoked.
        Invoke-EasyRSA @('--batch', 'revoke', [string]$pending.Name)
    } elseif ($rows[0].Status -ne 'R') {
        throw 'Rollback stopped: unexpected certificate status.'
    }
    $revoked = @(Get-Devices | Where-Object { $_.Name -ceq $pending.Name -and $_.Serial -ceq $serial -and $_.Status -eq 'R' })
    if ($revoked.Count -ne 1) { throw 'Rollback failed: certificate is not marked revoked.' }
    Update-Crl
    # Do not remove the pending marker unless OpenSSL confirms rejection by CRL.
    $certPath = Join-Path $script:Pki ("revoked\certs_by_serial\{0}.crt" -f $serial)
    if (-not (Test-Path -LiteralPath $certPath)) {
        $certPath = Join-Path $script:Pki ('issued\' + $pending.Name + '.crt')
    }
    $oldPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $check = @(& $script:OpenSSL verify -purpose sslclient -crl_check -CAfile (Join-Path $script:Pki 'ca.crt') -CRLfile (Join-Path $script:Pki 'crl.pem') $certPath 2>&1)
        $checkExit = $LASTEXITCODE
    } finally { $ErrorActionPreference = $oldPreference }
    if ($checkExit -eq 0 -or ($check -join ' ') -notmatch 'error 23 at 0 depth lookup') {
        throw 'Rollback incomplete: CRL rejection of the new certificate was not confirmed.'
    }
    # Keep public certificate/database audit records; never rewind index/serial/CRL.
    foreach ($part in @(("private\{0}.key" -f $pending.Name), ("reqs\{0}.req" -f $pending.Name),
        ("revoked\private_by_serial\{0}.key" -f $serial), ("revoked\reqs_by_serial\{0}.req" -f $serial))) {
        $path = Join-Path $script:Pki $part
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
    }
    Remove-Item -LiteralPath $pendingPath
    Write-Host 'Создание отменено: новый сертификат отозван, CRL обновлён. Используйте другое имя при повторе.' -ForegroundColor Yellow
}

function Get-Pem([string]$Path, [string]$Label) {
    $raw = [IO.File]::ReadAllText($Path)
    $pattern = '(?s)-----BEGIN ' + [regex]::Escape($Label) + '-----.*?-----END ' + [regex]::Escape($Label) + '-----'
    $match = [regex]::Match($raw, $pattern)
    if (-not $match.Success) { throw "Missing $Label in $Path" }
    return $match.Value
}

function Get-ProfileConnection {
    $path=Join-Path (Split-Path $script:Root) 'HomeRemote.settings.json'
    if(-not (Test-Path -LiteralPath $path)){throw 'HomeRemote.settings.json is missing. Copy the example and configure your server before creating devices.'}
    $config=[IO.File]::ReadAllText($path)|ConvertFrom-Json
    if($config.ServerHost -cnotmatch '^[A-Za-z0-9][A-Za-z0-9.:-]{0,252}$'){throw 'Invalid ServerHost.'}
    $port=0
    if(-not [int]::TryParse([string]$config.ServerPort,[ref]$port) -or $port -lt 1 -or $port -gt 65535){throw 'Invalid ServerPort.'}
    if($config.ServerCertificateName -cnotmatch '^[A-Za-z0-9._-]{1,64}$'){throw 'Invalid ServerCertificateName.'}
    $rdAddress=$null
    if(-not [Net.IPAddress]::TryParse([string]$config.RustDeskAddress,[ref]$rdAddress)){throw 'Invalid RustDeskAddress.'}
    $rdPort=0
    if(-not [int]::TryParse([string]$config.RustDeskPort,[ref]$rdPort) -or $rdPort -lt 1 -or $rdPort -gt 65535){throw 'Invalid RustDeskPort.'}
    [pscustomobject]@{HostName=[string]$config.ServerHost;Port=$port;CertificateName=[string]$config.ServerCertificateName;RustDeskAddress=$rdAddress.ToString();RustDeskPort=$rdPort;RustDeskEndpoint=($rdAddress.ToString()+':'+$rdPort)}
}
function Export-Profile([string]$Name) {
    Assert-DeviceName $Name
    $rows = @(Get-Devices | Where-Object { $_.Name -ceq $Name -and $_.Status -eq 'V' })
    if ($rows.Count -ne 1) { throw 'Exactly one valid device certificate is required.' }
    Get-CrlStatus
    $certPath = Join-Path $script:Pki "issued\$Name.crt"
    $keyPath = Join-Path $script:Pki "private\$Name.key"
    $verification = @(& $script:OpenSSL verify -purpose sslclient -crl_check -CAfile (Join-Path $script:Pki 'ca.crt') -CRLfile (Join-Path $script:Pki 'crl.pem') $certPath 2>&1)
    if ($LASTEXITCODE -ne 0) { throw ('Certificate verification failed: ' + ($verification -join ' ')) }
    Initialize-ProfileDirectory
    $out = Join-Path $script:Profiles "$Name.ovpn"
    if (Test-Path -LiteralPath $out) { throw "Profile already exists: $out (not overwritten)." }
    $ca = Get-Pem (Join-Path $script:Pki 'ca.crt') 'CERTIFICATE'
    $cert = Get-Pem $certPath 'CERTIFICATE'
    $key = [IO.File]::ReadAllText($keyPath).Trim()
    if ($key -notmatch '-----BEGIN (RSA |EC |ENCRYPTED )?PRIVATE KEY-----') { throw 'Unrecognized private key format.' }
    $tls = Get-Pem (Join-Path $script:Pki 'tls-crypt.key') 'OpenVPN Static key V1'
    $connection=Get-ProfileConnection
    $remoteHost=$connection.HostName
    $remotePort=$connection.Port
    $serverCertificateName=$connection.CertificateName
    $profile = @"
client
dev tun
proto tcp-client
remote $remoteHost $remotePort
nobind
remote-cert-tls server
verify-x509-name $serverCertificateName name
tls-version-min 1.2
data-ciphers AES-256-GCM:AES-128-GCM
auth-nocache
verb 3
<ca>
$ca
</ca>
<cert>
$cert
</cert>
<key>
$key
</key>
<tls-crypt>
$tls
</tls-crypt>
"@
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($profile)
    # Write completely to a unique temporary file, then publish without overwriting.
    $temporary = Join-Path $script:Profiles ('.profile-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        [IO.File]::Move($temporary, $out)
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary }
    }
    Write-Host "Профиль создан: $out" -ForegroundColor Green
    Write-Host 'Передавайте безопасно: файл содержит закрытый ключ. Адрес RustDesk указан в локальных настройках HomeRemote.'
}

function New-Device {
    if (Test-Path -LiteralPath (Get-PendingCreationPath)) {
        throw 'Есть незавершённая отмена создания. Выберите пункт 5 для завершения отката.'
    }
    $name = (Read-Host 'Уникальное имя латиницей, например HomeRemote-Laptop').Trim()
    Assert-DeviceName $name
    if (@(Get-Devices | Where-Object { $_.Name -ieq $name }).Count) { throw 'This name has already been used. Choose a new name.' }
    foreach ($part in @("issued\$name.crt","private\$name.key","reqs\$name.req")) {
        if (Test-Path -LiteralPath (Join-Path $script:Pki $part)) { throw 'Files already exist for this name. Choose a new name.' }
    }
    Initialize-ProfileDirectory
    $profilePath = Join-Path $script:Profiles "$name.ovpn"
    if (Test-Path -LiteralPath $profilePath) { throw 'Профиль с этим именем уже существует. Сертификат не создавался.' }
    # Detect ordinary disk/access errors before signing a new certificate.
    $probe = Join-Path $script:Profiles ('.probe-' + [guid]::NewGuid().ToString('N'))
    try { [IO.File]::WriteAllText($probe, 'write-test') }
    finally { if (Test-Path -LiteralPath $probe) { Remove-Item -LiteralPath $probe } }
    [void](Get-ProfileConnection)
    Get-CrlStatus
    Save-Backup
    # Persist intent before issuance so recovery is possible after an interrupted run.
    $pending = [pscustomobject]@{ Name=$name; Serial='' }
    Set-PendingCreation $pending
    try {
        Invoke-EasyRSA @('build-client-full',$name,'nopass')
        $issued = @(Get-Devices | Where-Object { $_.Name -ceq $name -and $_.Status -eq 'V' })
        if ($issued.Count -ne 1) { throw 'Cannot identify the newly issued certificate.' }
        $pending.Serial = $issued[0].Serial
        Set-PendingCreation $pending
        Export-Profile $name
        Remove-Item -LiteralPath (Get-PendingCreationPath)
    } catch {
        $exportFailure = $_.Exception.Message
        Write-Warning 'Ошибка сохранения профиля. Отменяю создание; для CRL потребуется пароль CA.'
        try { Undo-FailedCreation } catch {
            throw "Откат НЕ завершён: $($_.Exception.Message) Пункт 5 повторит отмену. Не считайте доступ заблокированным. Ошибка профиля: $exportFailure"
        }
        throw "Создание отменено. Ошибка сохранения профиля: $exportFailure"
    }
}

function Revoke-Device {
    Get-Devices | Format-Table -AutoSize | Out-Host
    $name = (Read-Host 'Полное имя устройства для отзыва').Trim()
    Assert-DeviceName $name
    if (@(Get-Devices | Where-Object { $_.Name -ceq $name -and $_.Status -eq 'V' }).Count -ne 1) {
        throw 'Exactly one valid certificate with this name must exist.'
    }
    Write-Warning 'Revocation is permanent. If this is your current phone, future VPN connections will fail.'
    Write-Warning 'Existing VPN sessions are NOT disconnected immediately. To end them, restart only the remote server locally.'
    if ((Read-Host "Type REVOKE $name to confirm") -cne "REVOKE $name") { Write-Host 'Cancelled.'; return }
    Save-Backup
    Invoke-EasyRSA @('revoke',$name)
    try { Update-Crl } catch {
        Write-Warning 'Certificate revoked in the CA database, BUT CRL update failed. Run Update CRL now; do not assume access is blocked.'
        throw
    }
    Write-Host 'Revoked and CRL updated. Old exported profiles are not erased, but cannot establish new verified TLS sessions.' -ForegroundColor Green
}

if ($Library) { return }

$mutex = New-Object Threading.Mutex($false, 'Global\HomeRemote-CertificateManager-v1')
$locked = $false
try {
    try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (-not $locked) { throw 'Another certificate manager is running.' }
    foreach ($path in @($script:Bridge, $script:OpenSSL, (Join-Path $script:Root 'bin\sh.exe'),
        (Join-Path $script:Root 'easyrsa'), (Join-Path $script:Pki 'index.txt'), (Join-Path $script:Pki 'ca.crt'))) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing file: $path" }
    }
    while ($true) {
        if (Test-Path -LiteralPath (Get-PendingCreationPath)) {
            Write-Warning 'Отмена создания не завершена. Выберите 5; до завершения новые сертификаты не выпускаются.'
        }
        Write-Host "`nHomeRemote — управление сертификатами" -ForegroundColor Cyan
        Write-Host '1 Создать устройство и профиль .ovpn'
        Write-Host '2 Список устройств (V=выдан, R=отозван, E=просрочен)'
        Write-Host '4 Отозвать сертификат и обновить CRL'
        Write-Host '5 Обновить CRL / завершить незаконченный откат'
        Write-Host '6 Проверить срок CRL'
        Write-Host '0 Выход'
        $choice = Read-Host 'Выберите пункт'
        if ($choice -eq '0') { break }
        try {
            switch ($choice) {
                '1' { New-Device }
                '2' { Get-Devices | Format-Table -AutoSize | Out-Host }
                '4' { Revoke-Device }
                '5' {
                    if (Test-Path -LiteralPath (Get-PendingCreationPath)) { Undo-FailedCreation }
                    else { Update-Crl }
                }
                '6' { Get-CrlStatus }
                default { Write-Host 'Unknown selection.' }
            }
        } catch { Write-Host $_.Exception.Message -ForegroundColor Red }
    }
} catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
} finally {
    if ($locked) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
