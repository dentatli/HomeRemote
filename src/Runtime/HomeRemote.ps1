#requires -Version 5.1
[CmdletBinding()]
param([switch]$Preview,[switch]$SmokeTest,[switch]$SmokeExitFailure,[string]$CapturePath,[string]$SmokeLog,[string]$DataRoot=$PSScriptRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Windows.Forms,System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class HRIconNative {
 [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr handle);
}
'@
if(-not $Preview) {
    $principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        [void][Windows.MessageBox]::Show('Запустите HomeRemote.vbs и подтвердите запрос администратора.','HomeRemote')
        exit 1
    }
}
$suffix=if($Preview){'Preview'}else{'Live'}
$script:instance=New-Object Threading.Mutex($false,('Global\HomeRemote-Desktop-'+$suffix))
$owned=$false
try {$owned=$script:instance.WaitOne(0)}catch [Threading.AbandonedMutexException]{$owned=$true}
if(-not $owned) {
    try {$event=[Threading.EventWaitHandle]::OpenExisting('Global\HomeRemote-Show-'+$suffix);[void]$event.Set();$event.Dispose()}catch{}
    $script:instance.Dispose();exit
}
$script:showEvent=New-Object Threading.EventWaitHandle($false,[Threading.EventResetMode]::AutoReset,('Global\HomeRemote-Show-'+$suffix))
$script:app=New-Object Windows.Application
$script:app.ShutdownMode=[Windows.ShutdownMode]::OnExplicitShutdown
$script:window=[Windows.Markup.XamlReader]::Parse([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'HomeRemote.xaml')))
$script:controls=@{}
foreach($name in @('TitleBar','MinimizeButton','CloseButton','AccessNav','DevicesNav','AccessPage','DevicesPage',
    'StatusDot','StatusLabel','StatusTitle','StatusDescription','MainButton','StopAllButton','VpnLabel','RdLabel',
    'AddDeviceButton','RevokeButton','ProfilesButton','DeviceGrid','CrlLabel','UpdateCrlButton','BusyProgress',
    'EndpointLabel','MessageLabel','DetailsText','DetailsExpander','FooterLabel','RefreshLabel')) {
    $script:controls[$name]=$script:window.FindName($name)
}
$script:worker=$null;$script:task=$null;$script:queued=$null;$script:state=$null
$script:allowClose=$false;$script:exitRequested=$false;$script:foregroundBusy=$false
$script:lastRefresh=[DateTime]::MinValue;$script:trayColor='';$script:icons=@{}
$script:events=New-Object Collections.Generic.List[string]
$script:smokePhase=0;$script:smokeError='';$script:smokeStart=[DateTime]::UtcNow
$script:failStopUsed=$false

function New-HRIndicator([string]$Color) {
    $bitmap=New-Object Drawing.Bitmap(32,32)
    $g=[Drawing.Graphics]::FromImage($bitmap)
    $g.SmoothingMode=[Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([Drawing.Color]::Transparent)
    $background=New-Object Drawing.SolidBrush([Drawing.ColorTranslator]::FromHtml('#21152F'))
    $dot=New-Object Drawing.SolidBrush([Drawing.ColorTranslator]::FromHtml($Color))
    $pen=New-Object Drawing.Pen([Drawing.ColorTranslator]::FromHtml('#B88ADD'),2)
    try {
        $g.FillEllipse($background,1,1,30,30);$g.DrawEllipse($pen,2,2,28,28);$g.FillEllipse($dot,9,9,14,14)
        $handle=$bitmap.GetHicon()
        try {return [Drawing.Icon]::FromHandle($handle).Clone()}finally{[void][HRIconNative]::DestroyIcon($handle)}
    }finally{$pen.Dispose();$dot.Dispose();$background.Dispose();$g.Dispose();$bitmap.Dispose()}
}
foreach($color in @('#8E809D','#68D6AF','#E7BC72','#EF819E','#B582F0')){$script:icons[$color]=New-HRIndicator $color}
$script:tray=New-Object Windows.Forms.NotifyIcon
$script:tray.Icon=$script:icons['#8E809D'];$script:tray.Text='HomeRemote — проверка';$script:tray.Visible=$true
$script:menu=New-Object Windows.Forms.ContextMenuStrip
$openItem=$script:menu.Items.Add('Открыть HomeRemote')
[void]$script:menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
$exitItem=$script:menu.Items.Add('Отключить всё и выйти')
if($SmokeTest -and -not $Preview){$exitItem.Enabled=$false}
$script:tray.ContextMenuStrip=$script:menu

function Restore-HRWindow {
    $script:window.Show();$script:window.WindowState=[Windows.WindowState]::Normal
    [void]$script:window.Activate()
}
function Set-HRPage([string]$Page) {
    $script:controls.AccessPage.Visibility=if($Page -eq 'Access'){'Visible'}else{'Collapsed'}
    $script:controls.DevicesPage.Visibility=if($Page -eq 'Devices'){'Visible'}else{'Collapsed'}
    $script:controls.AccessNav.Background=if($Page -eq 'Access'){'#3B2853'}else{'Transparent'}
    $script:controls.DevicesNav.Background=if($Page -eq 'Devices'){'#3B2853'}else{'Transparent'}
}
function Set-HRBusy([bool]$Busy,[string]$Operation='') {
    $script:foregroundBusy=$Busy
    $script:controls.BusyProgress.Visibility=if($Busy){'Visible'}else{'Collapsed'}
    foreach($name in @('MainButton','StopAllButton','AddDeviceButton','RevokeButton','UpdateCrlButton')) {
        $script:controls[$name].IsEnabled=(-not $Busy -and -not ($SmokeTest -and -not $Preview))
    }
    if($Busy) {
        $script:controls.MainButton.Content=switch($Operation){'Start'{'Включение…'}'Stop'{'Выключение…'}default{'Выполняется операция…'}}
        $script:tray.Icon=$script:icons['#B582F0'];$script:tray.Text='HomeRemote — выполняется операция'
    }
}
function Set-HRState($State) {
    $script:state=$State
    $color='#8E809D'
    if($State.IsOn) {
        $color=if($State.Listener){'#68D6AF'}else{'#E7BC72'}
        $script:controls.StatusLabel.Text=if($State.Listener){'КОМПОНЕНТЫ ЗАПУЩЕНЫ'}else{'ОЖИДАНИЕ ПОРТА RUSTDESK'}
        $script:controls.StatusTitle.Text='Удалённый доступ включён'
         $script:controls.StatusDescription.Text="Для подключения используйте VPN, затем RustDesk по адресу $($State.RdEndpoint)."
        $script:controls.MainButton.Content='Выключить доступ'
    }elseif($State.IsOff) {
        $script:controls.StatusLabel.Text='ВЫКЛЮЧЕНО'
        $script:controls.StatusTitle.Text='Ваш компьютер вне доступа'
        $script:controls.StatusDescription.Text='Включите OpenVPN и RustDesk, когда захотите подключиться с другого устройства.'
        $script:controls.MainButton.Content='Включить доступ'
    }else{
        $color='#E7BC72'
        $script:controls.StatusLabel.Text='ЧАСТИЧНО ВКЛЮЧЕНО'
        $script:controls.StatusTitle.Text='Запущен один компонент'
        $script:controls.StatusDescription.Text='Можно запустить недостающий компонент или выключить домашний доступ полностью.'
        $script:controls.MainButton.Content='Довключить доступ'
    }
    $script:controls.StopAllButton.Visibility=if(-not $State.IsOn -and -not $State.IsOff){'Visible'}else{'Collapsed'}
    $script:controls.StatusDot.Fill=$color
    $script:controls.VpnLabel.Text=if($State.Vpn){'Процесс запущен'}else{'Выключен'}
    $script:controls.RdLabel.Text=if($State.Listener){"TCP $($State.RdPort) прослушивается"}elseif($State.Rd){'Процесс запущен · порт не подтверждён'}else{'Выключен'}
    $selected=if($script:controls.DeviceGrid.SelectedItem){$script:controls.DeviceGrid.SelectedItem.Name}else{''}
    $script:controls.DeviceGrid.ItemsSource=[object[]]@($State.Devices)
    foreach($row in @($State.Devices)){if($row.Name -eq $selected){$script:controls.DeviceGrid.SelectedItem=$row;break}}
    $script:controls.CrlLabel.Text=if($State.Pending){'Есть незавершённая отмена создания — нажмите «Обновить».'}else{'Действует до '+$State.CrlExpiry}
    $script:controls.CrlLabel.Foreground=if($State.CrlWarning -or $State.Pending){'#E7BC72'}else{'#B5A3C6'}
    if(-not $script:foregroundBusy) {
        $script:tray.Icon=$script:icons[$color]
        $script:tray.Text=if($State.IsOn){'HomeRemote — доступ включён'}elseif($State.IsOff){'HomeRemote — доступ выключен'}else{'HomeRemote — частично включено'}
        $script:controls.MainButton.IsEnabled=-not ($SmokeTest -and -not $Preview)
        $script:controls.AddDeviceButton.IsEnabled=(-not $State.Pending -and -not ($SmokeTest -and -not $Preview))
    }
    $script:controls.EndpointLabel.Text=$State.RdEndpoint
    $script:controls.RefreshLabel.Text='Проверено '+(Get-Date -Format HH:mm:ss)
}
function Show-HRCredentialDialog([string]$Kind,[string]$Device='') {
    $dialog=[Windows.Markup.XamlReader]::Parse(@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="HomeRemote" Width="465" SizeToContent="Height" ResizeMode="NoResize" WindowStartupLocation="CenterOwner" Background="#191222" Foreground="#EDE6F6" FontFamily="Segoe UI" ShowInTaskbar="False">
 <StackPanel Margin="26"><TextBlock x:Name="Heading" FontSize="21" FontWeight="SemiBold"/><TextBlock x:Name="Description" TextWrapping="Wrap" Foreground="#BDAACF" Margin="0,12,0,18"/>
 <TextBlock x:Name="NameLabel" Text="Имя устройства · латиницей" Margin="0,0,0,7"/><TextBox x:Name="NameInput" Text="HomeRemote-" Background="#291D37" Foreground="#F1E8FC" Padding="10" BorderBrush="#614276" Margin="0,0,0,18"/>
 <TextBlock Text="Пароль центра сертификации (CA)" Margin="0,0,0,7"/><PasswordBox x:Name="PasswordInput" Background="#291D37" Foreground="#F1E8FC" Padding="10" BorderBrush="#614276"/>
 <TextBlock x:Name="Validation" Foreground="#EF819E" TextWrapping="Wrap" Margin="0,9,0,0"/>
 <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,18,0,0"><Button x:Name="Cancel" Content="Отмена" Padding="16,8" Margin="0,0,10,0" IsCancel="True"/><Button x:Name="Submit" Content="Продолжить" Padding="16,8" Background="#A46BE3" Foreground="#100A1B" IsDefault="True"/></StackPanel>
 </StackPanel></Window>
'@)
    $dialog.Owner=$script:window
    $heading=$dialog.FindName('Heading');$description=$dialog.FindName('Description')
    $nameInput=$dialog.FindName('NameInput');$passwordInput=$dialog.FindName('PasswordInput');$validation=$dialog.FindName('Validation')
    $heading.Text=switch($Kind){'Create'{'Новое устройство'}'Revoke'{'Отозвать доступ'}default{'Обновление списка отзыва'}}
    $description.Text=switch($Kind){
        'Create'{'Создадим отдельный сертификат и профиль .ovpn. Если сохранение не удастся, новый сертификат будет отозван.'}
        'Revoke'{"Отозвать $Device? Отзыв необратим. Текущий сеанс может сохраняться; после отключения устройство не сможет войти снова."}
        default{'Обновим CRL на 365 дней или завершим незаконченный откат создания. Пароль не сохраняется.'}
    }
    if($Kind -ne 'Create'){$nameInput.Visibility='Collapsed';$dialog.FindName('NameLabel').Visibility='Collapsed'}
    $dialog.Tag=$null
    $submitHandler={
        $n=if($Kind -eq 'Create'){$nameInput.Text.Trim()}else{$Device}
        if($Kind -eq 'Create' -and ($n -cnotmatch '^HomeRemote-[A-Za-z0-9][A-Za-z0-9_-]{0,48}$' -or $n -ieq 'HomeRemote-Server')){
            $validation.Text='Пример имени: HomeRemote-Laptop. Без пробелов и русских букв.';return
        }
        if($passwordInput.SecurePassword.Length -eq 0){$validation.Text='Введите пароль CA.';return}
        $dialog.Tag=[pscustomobject]@{Name=$n;Password=$passwordInput.SecurePassword.Copy()}
        $passwordInput.Clear();$dialog.DialogResult=$true
    }.GetNewClosure()
    $dialog.FindName('Submit').Add_Click($submitHandler)
    if($dialog.ShowDialog()){return $dialog.Tag}
    return $null
}

function Start-HRTask([string]$Operation,[string]$Name='',[Security.SecureString]$Password=$null) {
    if($script:worker) {
        if($script:task.Operation -eq 'State'){
            $script:queued=[pscustomobject]@{Operation=$Operation;Name=$Name;Password=$Password}
            Set-HRBusy $true $Operation
        }elseif($Password){$Password.Dispose()}
        return
    }
    if($Operation -ne 'State'){Set-HRBusy $true $Operation;$script:controls.MessageLabel.Text='Выполняется…'}
    $script:events.Add($Operation)
    $ps=[PowerShell]::Create()
    $code={param($folder,$operation,$name,$password,$demo,$demoState,$failStop,$dataFolder)
        $ErrorActionPreference='Stop'
        if($demo){
            Start-Sleep -Milliseconds 180
            if(-not $demoState){$demoState=[pscustomobject]@{RdEndpoint='192.0.2.1:21118';RdPort=21118;Vpn=$false;Rd=$false;Listener=$false;IsOff=$true;IsOn=$false;
                Devices=@([pscustomobject]@{Name='HomeRemote-Android';Expiry='20.01.2029';Status='Действует';CanRevoke=$true;Serial='01'});
                CrlExpiry='24.10.2027';CrlWarning=$false;Pending=$false}}
            if($operation -eq 'Start'){$demoState.Vpn=$true;$demoState.Rd=$true;$demoState.Listener=$true;$demoState.IsOff=$false;$demoState.IsOn=$true}
            if($operation -eq 'Stop' -and $failStop){return [pscustomobject]@{Success=$false;Message='Тест';Error='Тестовая ошибка остановки';State=$demoState;Operation=$operation}}
            if($operation -eq 'Stop'){$demoState.Vpn=$false;$demoState.Rd=$false;$demoState.Listener=$false;$demoState.IsOff=$true;$demoState.IsOn=$false}
            return [pscustomobject]@{Success=$true;Message='Предпросмотр: реальные программы и сертификаты не изменяются.';Error='';State=$demoState;Operation=$operation}
        }
        . (Join-Path $folder 'HomeRemote-Backend.ps1')
        Invoke-HROperation $folder $operation $name $password -DataRoot $dataFolder
    }
    $failStop=($Preview -and $SmokeExitFailure -and $Operation -eq 'Stop' -and -not $script:failStopUsed)
    if($failStop){$script:failStopUsed=$true}
    [void]$ps.AddScript($code.ToString()).AddArgument($PSScriptRoot).AddArgument($Operation).AddArgument($Name).AddArgument($Password).AddArgument([bool]$Preview).AddArgument($script:state).AddArgument($failStop).AddArgument($DataRoot)
    $script:worker=$ps;$script:task=[pscustomobject]@{Operation=$Operation;Password=$Password;Handle=$ps.BeginInvoke()}
}
function Request-HRExit {
    if($script:foregroundBusy){Restore-HRWindow;$script:controls.MessageLabel.Text='Дождитесь завершения текущей операции, затем выберите выход.';return}
    $script:exitRequested=$true
    Start-HRTask 'Stop'
}
function Save-HRView([string]$Path) {
    if(-not $Path){return}
    $script:window.UpdateLayout()
    $image=New-Object Windows.Media.Imaging.RenderTargetBitmap([int]$script:window.ActualWidth,[int]$script:window.ActualHeight,96,96,[Windows.Media.PixelFormats]::Pbgra32)
    $image.Render($script:window)
    $encoder=New-Object Windows.Media.Imaging.PngBitmapEncoder
    $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($image))
    $stream=[IO.File]::Create($Path)
    try{$encoder.Save($stream)}finally{$stream.Dispose()}
}

$script:controls.TitleBar.Add_MouseLeftButtonDown({param($sender,$eventArgs) if($eventArgs.ClickCount -eq 1){$script:window.DragMove()}})
$script:controls.CloseButton.Add_Click({$script:window.Close()})
$script:controls.MinimizeButton.Add_Click({$script:window.WindowState='Minimized'})
$script:window.Add_Closing({param($sender,$eventArgs)
    if(-not $script:allowClose){$eventArgs.Cancel=$true;$script:window.Hide()}
})
$script:controls.AccessNav.Add_Click({Set-HRPage 'Access'})
$script:controls.DevicesNav.Add_Click({Set-HRPage 'Devices'})
$script:controls.MainButton.Add_Click({
    if(-not $script:state){return}
    $operation=if($script:state.IsOn){'Stop'}else{'Start'}
    Start-HRTask $operation
})
$script:controls.StopAllButton.Add_Click({Start-HRTask 'Stop'})
$script:controls.AddDeviceButton.Add_Click({
    $credentials=Show-HRCredentialDialog 'Create'
    if($credentials){Start-HRTask 'Create' $credentials.Name $credentials.Password}
})
$script:controls.RevokeButton.Add_Click({
    $row=$script:controls.DeviceGrid.SelectedItem
    if(-not $row){$script:controls.MessageLabel.Text='Сначала выберите устройство в таблице.';return}
    if(-not $row.CanRevoke){$script:controls.MessageLabel.Text='Этот сертификат уже отозван или недействителен.';return}
    $credentials=Show-HRCredentialDialog 'Revoke' $row.Name
    if($credentials){Start-HRTask 'Revoke' $credentials.Name $credentials.Password}
})
$script:controls.UpdateCrlButton.Add_Click({
    $credentials=Show-HRCredentialDialog 'UpdateCRL'
    if($credentials){Start-HRTask 'UpdateCRL' '' $credentials.Password}
})
$script:controls.ProfilesButton.Add_Click({
    $folder=Join-Path $DataRoot 'HomeRemote-Profiles'
    if(Test-Path -LiteralPath $folder){Start-Process explorer.exe -ArgumentList ('"'+$folder+'"')}
    else{$script:controls.MessageLabel.Text='Папка появится после создания первого профиля.'}
})
$script:tray.Add_MouseDoubleClick({Restore-HRWindow})
$openItem.Add_Click({Restore-HRWindow})
$exitItem.Add_Click({Request-HRExit})

$script:timer=New-Object Windows.Threading.DispatcherTimer
$script:timer.Interval=[TimeSpan]::FromMilliseconds(200)
$script:timer.Add_Tick({
    try {
        if($script:showEvent.WaitOne(0)){Restore-HRWindow}
        if($script:worker -and $script:task.Handle.IsCompleted) {
            $operation=$script:task.Operation;$result=$null
            try {
                $items=@($script:worker.EndInvoke($script:task.Handle))
                $results=@($items|Where-Object {$_ -and $_.PSObject.Properties['Success']})
                if($results.Count){$result=$results[-1]}
                else{throw (($script:worker.Streams.Error|Out-String)+'Нет результата операции.')}
                if($operation -ne 'State'){
                    $details=(@($script:worker.Streams.Information|ForEach-Object {$_.MessageData.ToString()})+
                        @($script:worker.Streams.Warning|ForEach-Object {$_.Message})+@($result.Error)) -join "`r`n"
                    $script:controls.DetailsText.Text=$details.Trim()
                }
            }catch{
                $result=[pscustomobject]@{Success=$false;State=$null;Message='Операция завершилась с ошибкой.';Error=$_.Exception.Message}
            }finally{
                if($script:task.Password){$script:task.Password.Dispose()}
                $script:worker.Dispose();$script:worker=$null;$script:task=$null
            }
            Set-HRBusy $false
            if($result.State){Set-HRState $result.State}
            if(-not $result.Success) {
                $script:controls.MessageLabel.Text=$result.Error
                $script:controls.MessageLabel.Foreground='#EF819E'
                $script:controls.DetailsText.Text=$result.Error+"`r`n"+$script:controls.DetailsText.Text
                $script:tray.Icon=$script:icons['#EF819E'];$script:tray.Text='HomeRemote — требуется внимание'
                if(-not $result.State){$script:controls.MainButton.IsEnabled=$false}
                if($script:exitRequested){$script:exitRequested=$false;Restore-HRWindow}
            }elseif($operation -ne 'State'){
                $script:controls.MessageLabel.Text=$result.Message;$script:controls.MessageLabel.Foreground='#B8A8C8'
            }
            $script:lastRefresh=[DateTime]::UtcNow
            if($script:exitRequested -and $operation -eq 'Stop' -and $result.Success -and $result.State -and $result.State.IsOff){
                $script:allowClose=$true;$script:window.Close();$script:app.Shutdown();return
            }
            if($script:queued){$queued=$script:queued;$script:queued=$null;Start-HRTask $queued.Operation $queued.Name $queued.Password}
        }
        if($SmokeTest -and $Preview -and -not $script:worker -and $script:state){
            switch($script:smokePhase){
                0 {
                    if($script:events -contains 'Start'){throw 'Access auto-started unexpectedly.'}
                    $script:controls.MainButton.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent)))
                    $script:smokePhase=1
                }
                1 {
                    if(-not $script:state.IsOn -or $script:controls.MainButton.Content -ne 'Выключить доступ'){throw 'Main button did not follow state.'}
                    Save-HRView $CapturePath
                    Set-HRPage 'Devices';$script:window.UpdateLayout()
                    $script:smokePhase=2
                }
                2 {
                    if($CapturePath){Save-HRView ([IO.Path]::ChangeExtension($CapturePath,'.devices.png'))}
                    if($script:controls.DeviceGrid.Items.Count -lt 1){throw 'Device table is empty.'}
                    Set-HRPage 'Access'
                    $script:window.Close()
                    if($script:window.IsVisible){throw 'Close did not hide the window.'}
                    Restore-HRWindow
                    if(-not $script:window.IsVisible){throw 'Restore failed.'}
                    $script:smokePhase=3;Request-HRExit
                }
                3 {
                    if($SmokeExitFailure){
                        if(-not $script:window.IsVisible -or $script:allowClose -or $script:exitRequested -or -not $script:state.IsOn){throw 'Failed stop did not preserve the application and active state.'}
                        $script:smokePhase=4;Request-HRExit
                    }
                }
            }
        }
        if($SmokeTest -and -not $Preview -and -not $script:worker -and $script:state){
            if($script:smokePhase -eq 0){$script:smokePhase=1}
            else{Save-HRView $CapturePath;$script:allowClose=$true;$script:window.Close();$script:app.Shutdown();return}
        }
        if($SmokeTest -and ([DateTime]::UtcNow-$script:smokeStart).TotalSeconds -gt 35){throw 'Smoke test timeout.'}
        if(-not $script:worker -and -not $script:foregroundBusy -and ([DateTime]::UtcNow-$script:lastRefresh).TotalSeconds -gt 5){Start-HRTask 'State'}
    }catch{
        $script:controls.MessageLabel.Text=$_.Exception.Message
        if($SmokeTest){$script:smokeError=$_.Exception.Message;$script:app.Shutdown()}
    }
})
if($Preview){$script:controls.FooterLabel.Text='ПРЕДПРОСМОТР · реальные настройки не изменяются'}
try {
    $script:timer.Start();Start-HRTask 'State'
    [void]$script:app.Run($script:window)
}finally{
    $script:timer.Stop()
    if($script:worker){$script:worker.Stop();$script:worker.Dispose();if($script:task.Password){$script:task.Password.Dispose()}}
    if($script:queued -and $script:queued.Password){$script:queued.Password.Dispose()}
    $script:tray.Visible=$false;$script:tray.Dispose();$script:menu.Dispose()
    foreach($icon in $script:icons.Values){$icon.Dispose()}
    $script:showEvent.Dispose();$script:instance.ReleaseMutex();$script:instance.Dispose()
    if($SmokeLog){[IO.File]::WriteAllText($SmokeLog,([pscustomobject]@{Phase=$script:smokePhase;Error=$script:smokeError;Events=@($script:events.ToArray());IsOff=($script:state -and $script:state.IsOff)}|ConvertTo-Json),(New-Object Text.UTF8Encoding($false)))}
}
if($script:smokeError){exit 1}
