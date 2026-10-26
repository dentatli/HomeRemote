#requires -Version 5.1
#requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess=$true)]
param([switch]$Notify, [switch]$Library,
    [ValidateSet('Toggle','Start','Stop')][string]$Action = 'Toggle', [string]$DataRoot=$PSScriptRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:VpnExe = 'C:\Program Files\OpenVPN\bin\openvpn.exe'
$script:VpnConfig = Join-Path $DataRoot 'OpenVPN\remote-server.ovpn'
$script:RdLauncher = Join-Path $DataRoot 'rustdesk-1.5.0-x86_64.exe'
$script:RdExe = Join-Path $env:LOCALAPPDATA 'rustdesk\rustdesk.exe'

function Show-Result([string]$Text, [switch]$Failure) {
    if (-not $Notify) { return }
    Add-Type -AssemblyName System.Windows.Forms
    if ($Failure) {
        [void][Windows.Forms.MessageBox]::Show($Text, 'Remote Toggle - Error', 'OK', 'Error')
        return
    }
    $icon = New-Object Windows.Forms.NotifyIcon
    try {
        Add-Type -AssemblyName System.Drawing
        $icon.Icon = [Drawing.SystemIcons]::Information
        $icon.Text = 'Remote Toggle'
        $icon.Visible = $true
        $icon.ShowBalloonTip(3000, 'Remote Toggle', $Text, [Windows.Forms.ToolTipIcon]::Info)
        $until = [DateTime]::UtcNow.AddSeconds(4)
        while ([DateTime]::UtcNow -lt $until) {
            [Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 100
        }
    } finally { $icon.Visible = $false; $icon.Dispose() }
}

function Hide-RustDeskWindow {
    # Keep the normal portable startup (and its server/helper) intact.
    # --tray alone is not a substitute for starting the portable server.
    for ($attempt = 0; $attempt -lt 25; $attempt++) {
        foreach ($t in @(Get-Targets | Where-Object Role -eq 'RD')) {
            $p = Get-Process -Id $t.Process.ProcessId -ErrorAction SilentlyContinue
            if (-not $p) { continue }
            try {
                $null = $p.Handle
                $live = Get-CimInstance Win32_Process -Filter "ProcessId=$($t.Process.ProcessId)"
                if ($live -and $live.CreationDate -eq $t.Process.CreationDate -and (Get-Role $live) -eq 'RD') {
                    $p.Refresh()
                    if ($p.MainWindowHandle -ne [IntPtr]::Zero) {
                        [void][RemoteToggle.Native]::ShowWindowAsync($p.MainWindowHandle, 0)
                    }
                }
            } finally { $p.Dispose() }
        }
        Start-Sleep -Milliseconds 200
    }
}

function Split-Arguments([string]$Line) {
    if ([string]::IsNullOrWhiteSpace($Line)) { throw 'Missing command line; refusing to guess.' }
    $count = 0
    $ptr = [RemoteToggle.Native]::CommandLineToArgvW($Line, [ref]$count)
    if ($ptr -eq [IntPtr]::Zero) { throw 'Cannot parse command line.' }
    try {
        for ($i = 0; $i -lt $count; $i++) {
            [Runtime.InteropServices.Marshal]::PtrToStringUni(
                [Runtime.InteropServices.Marshal]::ReadIntPtr($ptr, $i * [IntPtr]::Size))
        }
    } finally { [void][RemoteToggle.Native]::LocalFree($ptr) }
}

function Get-Role($Process) {
    if ([string]::IsNullOrWhiteSpace($Process.ExecutablePath)) {
        throw "Cannot identify executable for PID $($Process.ProcessId). No changes made by this scan."
    }
    # Windows may report the same executable with embedded . or .. segments.
    # Normalize before comparison; still require the exact target directory/file.
    $exePath = [IO.Path]::GetFullPath($Process.ExecutablePath)
    if ($Process.Name -ieq 'openvpn.exe') {
        if ($exePath -ine $script:VpnExe) { return 'Other' }
        $argv = @(Split-Arguments $Process.CommandLine)
        $configs = @()
        for ($i = 1; $i -lt $argv.Count; $i++) {
            if ($argv[$i] -ieq '--config') {
                if (++$i -ge $argv.Count) { throw 'OpenVPN --config has no value.' }
                $configs += $argv[$i]
            }
        }
        # OpenVPN also accepts a bare configuration filename.
        if ($argv.Count -eq 2 -and $argv[1] -notlike '--*') { $configs += $argv[1] }
        if ($configs.Count -ne 1 -or -not [IO.Path]::IsPathRooted($configs[0])) {
            throw "Ambiguous OpenVPN config in PID $($Process.ProcessId). Use one absolute --config path."
        }
        if ([IO.Path]::GetFullPath($configs[0]) -ieq $script:VpnConfig) { return 'VPN' }
        return 'Other'
    }
    if ($exePath -ieq $script:RdExe -or
        $exePath -ieq $script:RdLauncher) { return 'RD' }
    return 'Other'
}

function Get-Targets {
    $all = @(Get-CimInstance Win32_Process -Filter "Name='openvpn.exe' OR Name='rustdesk.exe' OR Name='rustdesk-1.5.0-x86_64.exe'")
    foreach ($p in $all) {
        $role = Get-Role $p
        if ($role -ne 'Other') {
            [pscustomobject]@{ Role=$role; Process=$p }
        }
    }
}

function Stop-Target($Target) {
    $original = $Target.Process
    $live = Get-CimInstance Win32_Process -Filter "ProcessId=$($original.ProcessId)"
    if (-not $live) { return }
    if ($live.CreationDate -ne $original.CreationDate -or (Get-Role $live) -ne $Target.Role) {
        throw 'Process identity changed; refusing to stop it.'
    }
    $handle = Get-Process -Id $live.ProcessId -ErrorAction SilentlyContinue
    if (-not $handle) { return }
    try {
        # Hold a process handle before the final identity check to prevent PID reuse.
        $null = $handle.Handle
        $again = Get-CimInstance Win32_Process -Filter "ProcessId=$($live.ProcessId)"
        if (-not $again) { return }
        if ($again.CreationDate -ne $original.CreationDate -or (Get-Role $again) -ne $Target.Role) {
            throw 'Process identity changed after opening handle.'
        }
        if ($Target.Role -eq 'VPN') {
            $argv = @(Split-Arguments $again.CommandLine)
            $index = [Array]::IndexOf($argv, '--service')
            if ($index -ge 0 -and $index + 1 -lt $argv.Count -and $argv[$index+1] -cmatch '^Global\\RemoteToggle-[a-f0-9]{32}$') {
                $eventName = $argv[$index+1]
                $event = [Threading.EventWaitHandle]::OpenExisting($eventName)
                try { [void]$event.Set() } finally { $event.Dispose() }
                if ($handle.WaitForExit(15000)) { return }
                throw 'OpenVPN did not exit after its shutdown event. Inspect it manually.'
            }
        }
        if ($handle.CloseMainWindow() -and $handle.WaitForExit(5000)) { return }
        if (-not $handle.HasExited) {
            Write-Warning "Terminating verified $($Target.Role) PID $($live.ProcessId); no graceful interface is available."
            $handle.Kill()
            if (-not $handle.WaitForExit(10000)) { throw 'Process did not stop.' }
        }
    } finally { $handle.Dispose() }
}

function Invoke-Toggle {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param([ValidateSet('Toggle','Start','Stop')][string]$Action = 'Toggle')
    $targets = @(Get-Targets)
    # Never stop shared OpenVPN wrappers or guess ownership of a service.
    $services = @(Get-CimInstance Win32_Service | Where-Object { $_.State -ne 'Stopped' })
    foreach ($t in $targets) {
        if (@($services | Where-Object { $_.ProcessId -eq $t.Process.ProcessId }).Count) {
            throw 'A target is managed by a Windows service. Stop that dedicated service manually; this script will not alter services.'
        }
    }
    if ($Action -eq 'Stop' -or ($Action -eq 'Toggle' -and $targets.Count)) {
        if (-not $targets.Count) { Write-Host 'OFF: already stopped.'; return }
        if (-not $PSCmdlet.ShouldProcess('Verified remote OpenVPN and RustDesk processes', 'Stop active components')) { return }
        $errors = @()
        # Repeat to catch portable helper processes created during shutdown.
        for ($pass = 0; $pass -lt 4; $pass++) {
            foreach ($t in $targets) {
                try { Stop-Target $t } catch { $errors += $_.Exception.Message }
            }
            Start-Sleep -Milliseconds 500
            $targets = @(Get-Targets)
            if (-not $targets.Count) {
                Write-Host 'OFF: both components are stopped.'
                Show-Result 'OFF: OpenVPN server and RustDesk are stopped.'
                return
            }
        }
        throw ('Some components are still running. ' + ($errors -join ' | '))
    }
    $needVpn = -not @($targets | Where-Object Role -eq 'VPN').Count
    $needRd = -not @($targets | Where-Object Role -eq 'RD').Count
    if (-not $needVpn -and -not $needRd) { Write-Host 'ON: already running.'; return }
    foreach ($path in @($script:VpnExe, $script:VpnConfig, $script:RdLauncher)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "File not found: $path" }
    }
    if (-not $PSCmdlet.ShouldProcess('Remote OpenVPN server and RustDesk Portable', 'Start both components')) { return }
    $startedVpn = $null
    $event = $null
    try {
        # Unique event; never signal an event supplied by another program.
        $logFolder = Join-Path $DataRoot 'Logs'
        [void](New-Item -ItemType Directory -Path $logFolder -Force)
        $log = Join-Path $logFolder ('RemoteToggle-OpenVPN-' + [guid]::NewGuid().ToString('N') + '.log')
        if ($needVpn) {
            $eventName = 'Global\RemoteToggle-' + [guid]::NewGuid().ToString('N')
            $event = New-Object Threading.EventWaitHandle($false, [Threading.EventResetMode]::ManualReset, $eventName)
            $startedVpn = Start-Process -FilePath $script:VpnExe -WindowStyle Hidden -WorkingDirectory (Split-Path $script:VpnConfig) -ArgumentList @('--config', ('"' + $script:VpnConfig + '"'), '--service', $eventName, '0', '--log-append', ('"' + $log + '"')) -PassThru
            Start-Sleep -Seconds 3
            if ($startedVpn.HasExited) { throw "OpenVPN exited. See $log" }
        }
        if ($needRd) {
            Start-Process -FilePath $script:RdLauncher -WindowStyle Hidden -WorkingDirectory (Split-Path $script:RdLauncher) | Out-Null
            Hide-RustDeskWindow
        }
        $after = @(Get-Targets)
        if (-not @($after | Where-Object Role -eq 'VPN').Count -or -not @($after | Where-Object Role -eq 'RD').Count) {
            throw "Startup incomplete. See $log"
        }
        Write-Host "ON: both processes detected. VPN log: $log"
        Write-Host 'Process presence does not prove VPN connectivity or remote access readiness.'
        Show-Result 'ON: OpenVPN server and RustDesk processes are running.'
    } catch {
        $failure = $_
        # Roll back only our OpenVPN launch, using its own event.
        if ($event) { [void]$event.Set() }
        if ($startedVpn) { [void]$startedVpn.WaitForExit(15000) }
        Write-Warning 'Startup failed. RustDesk may remain running; rerun the toggle to stop verified components.'
        throw $failure
    } finally {
        if ($event) { $event.Dispose() }
        if ($startedVpn) { $startedVpn.Dispose() }
    }
}

if (-not ('RemoteToggle.Native' -as [type])) {
    Add-Type @'
using System;
using System.Runtime.InteropServices;
namespace RemoteToggle {
 public static class Native {
  [DllImport("shell32.dll", SetLastError=true)] public static extern IntPtr CommandLineToArgvW([MarshalAs(UnmanagedType.LPWStr)] string s, out int n);
  [DllImport("kernel32.dll")] public static extern IntPtr LocalFree(IntPtr p);
  [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr window, int command);
 }
}
'@
}

if ($Library) { return }

$mutex = New-Object Threading.Mutex($false, 'Global\RemoteToggle-RemoteServer-v1')
$locked = $false
try {
    try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (-not $locked) { throw 'Another toggle is already running.' }
    Invoke-Toggle -Action $Action
} catch {
    $failureText = $_.Exception.Message
    if ($Notify) {
        try { Show-Result $failureText -Failure } catch { Write-Warning $_ }
    }
    Write-Error $failureText -ErrorAction Continue
    exit 1
} finally {
    if ($locked) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
