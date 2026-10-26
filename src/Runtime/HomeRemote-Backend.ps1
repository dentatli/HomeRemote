#requires -Version 5.1
Set-StrictMode -Version Latest

function Invoke-HRNative {
    param([string]$File, [string]$Arguments, [string]$WorkingDirectory,
        [Security.SecureString]$Password)
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName=$File; $info.Arguments=$Arguments; $info.WorkingDirectory=$WorkingDirectory
    $info.UseShellExecute=$false; $info.CreateNoWindow=$true
    $info.RedirectStandardInput=$true; $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
    $process=New-Object Diagnostics.Process
    $process.StartInfo=$info
    try {
        [void]$process.Start()
        $stdout=$process.StandardOutput.ReadToEndAsync()
        $stderr=$process.StandardError.ReadToEndAsync()
        if($Password) {
            $pointer=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
            try {
                $plain=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
                $process.StandardInput.WriteLine($plain)
            } finally {
                $plain=$null
                [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
            }
        }
        $process.StandardInput.Close()
        $process.WaitForExit()
        [pscustomobject]@{ ExitCode=$process.ExitCode; Text=($stdout.Result+"`n"+$stderr.Result).Trim() }
    } finally { $process.Dispose() }
}

function Convert-HRDate([string]$Value) {
    $format=if($Value.Length -eq 13){'yyMMddHHmmss\Z'}else{'yyyyMMddHHmmss\Z'}
    [DateTime]::ParseExact($Value,$format,[Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal)
}

function Get-HRState {
    $connection=Get-ProfileConnection
    $targets=@(Get-Targets)
    $vpn=@($targets|Where-Object Role -eq 'VPN').Count -gt 0
    $rd=@($targets|Where-Object Role -eq 'RD').Count -gt 0
    $rdPids=@($targets|Where-Object Role -eq 'RD'|ForEach-Object {$_.Process.ProcessId})
    $listener=$false
    if($rd) {
        $listener=@(Get-NetTCPConnection -LocalPort $connection.RustDeskPort -State Listen -ErrorAction SilentlyContinue |
            Where-Object {$rdPids -contains $_.OwningProcess}).Count -gt 0
    }
    $devices=@(foreach($device in @(Get-Devices)) {
        $expires=Convert-HRDate $device.ExpiryUTC
        $status=if($device.Status -eq 'R'){'Отозван'}elseif($expires -le [DateTime]::UtcNow -or $device.Status -eq 'E'){'Истёк'}else{'Действует'}
        [pscustomobject]@{ Name=$device.Name; Expiry=$expires.ToLocalTime().ToString('dd.MM.yyyy');
            Status=$status; CanRevoke=($device.Status -eq 'V'); Serial=$device.Serial }
    })
    $crlText='Не найден';$crlWarning=$true
    $crl=Join-Path $script:Pki 'crl.pem'
    if(Test-Path -LiteralPath $crl) {
        $result=Invoke-HRNative $script:OpenSSL ('crl -in "'+$crl+'" -noout -nextupdate') $script:Root
        if($result.ExitCode -ne 0){throw 'Не удалось прочитать срок CRL.'}
        if($result.Text -match 'nextUpdate=([^\r\n]+)') {
            $date=[DateTime]::ParseExact(($Matches[1] -replace '\s+',' ').Trim(),'MMM d HH:mm:ss yyyy "GMT"',
                [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal)
            $crlText=$date.ToLocalTime().ToString('dd.MM.yyyy')
            $crlWarning=$date -lt [DateTime]::UtcNow.AddDays(30)
        }
    }
    [pscustomobject]@{ RdEndpoint=$connection.RustDeskEndpoint;RdPort=$connection.RustDeskPort; Vpn=$vpn; Rd=$rd; Listener=$listener; IsOff=(-not $vpn -and -not $rd);
        IsOn=($vpn -and $rd); Devices=$devices; CrlExpiry=$crlText; CrlWarning=$crlWarning;
        Pending=(Test-Path -LiteralPath (Get-PendingCreationPath)) }
}

function Invoke-HROperation {
    param([string]$Folder,[ValidateSet('State','Start','Stop','Create','Revoke','UpdateCRL')][string]$Operation,
        [string]$DeviceName,[Security.SecureString]$Password,[string]$DataRoot=$Folder)
    $ErrorActionPreference='Stop'
    . (Join-Path $Folder 'Remote-Toggle.ps1') -Library -DataRoot $DataRoot
    . (Join-Path $Folder 'HomeRemote-Certificates.ps1') -Library -DataRoot $DataRoot
    $script:GuiPassword=$Password
    $script:GuiDeviceName=$DeviceName
    $script:GuiOperation=$Operation
    # Reuse certificate workflow and rollback while replacing console-only prompts.
    function Read-Host {
        param([string]$Prompt)
        if($Prompt -like 'Type REVOKE*'){return 'REVOKE '+$script:GuiDeviceName}
        return $script:GuiDeviceName
    }
    function Invoke-EasyRSA([string[]]$Arguments) {
        $argv=@('--batch','--passin=stdin')+@($Arguments|Where-Object {$_ -ne '--batch'})
        $quoted=@('"'+$script:Bridge.Replace('\','/')+'"')+@($argv|ForEach-Object {'"'+$_+'"'})
        $result=Invoke-HRNative (Join-Path $script:Root 'bin\sh.exe') ($quoted -join ' ') $script:Root $script:GuiPassword
        Write-Information $result.Text -InformationAction Continue
        if($result.ExitCode -ne 0){throw ('EasyRSA: '+$result.Text)}
    }
    $lock=$null;$held=$false;$message='Состояние обновлено';$success=$true;$errorText=''
    try {
        if($Operation -ne 'State') {
            $lockName=if($Operation -in @('Start','Stop')){'Global\RemoteToggle-RemoteServer-v1'}else{'Global\HomeRemote-CertificateManager-v1'}
            $lock=New-Object Threading.Mutex($false,$lockName)
            try {$held=$lock.WaitOne(0)}catch [Threading.AbandonedMutexException]{$held=$true}
            if(-not $held){throw 'Уже выполняется другая операция. Закройте консольное меню или дождитесь завершения.'}
        }
        if($Operation -in @('Create','Revoke','UpdateCRL')) {
            if(-not $Password -or $Password.Length -eq 0){throw 'Введите пароль центра сертификации.'}
            $check=Invoke-HRNative $script:OpenSSL ('pkey -in "'+(Join-Path $script:Pki 'private\ca.key')+'" -noout -passin stdin') $script:Root $Password
            if($check.ExitCode -ne 0){throw 'Пароль CA не принят или ключ CA недоступен. Изменения не выполнялись.'}
        }
        switch($Operation) {
            'Start' {Invoke-Toggle -Action Start;$message='Домашний удалённый доступ включён.'}
            'Stop' {Invoke-Toggle -Action Stop;$message='Домашний удалённый доступ выключен.'}
            'Create' {New-Device;$message="Профиль $DeviceName создан. Откройте папку профилей для передачи на устройство."}
            'Revoke' {Revoke-Device;$message="Сертификат $DeviceName отозван. Активный сеанс может сохраняться до переподключения."}
            'UpdateCRL' {
                if(Test-Path -LiteralPath (Get-PendingCreationPath)){Undo-FailedCreation;$message='Незавершённое создание отменено.'}
                else{Update-Crl;$message='Список отзыва обновлён на 365 дней.'}
            }
        }
    } catch {$success=$false;$errorText=$_.Exception.Message;$message='Операция не завершена.'}
    finally {
        $script:GuiPassword=$null
        if($held){$lock.ReleaseMutex()};if($lock){$lock.Dispose()}
    }
    $state=$null
    try {$state=Get-HRState}catch {if($success){$success=$false;$errorText=$_.Exception.Message};$message='Не удалось подтвердить состояние.'}
    [pscustomobject]@{Success=$success;Message=$message;Error=$errorText;State=$state;Operation=$Operation}
}
