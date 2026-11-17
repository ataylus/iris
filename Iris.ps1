param([switch]$Stop, [switch]$Install, [string]$Snapshot)
$root = $PSScriptRoot
Set-Location $root

if ($Install) {
    $shell = New-Object -ComObject WScript.Shell
    foreach ($folder in [Environment]::GetFolderPath('Programs'), [Environment]::GetFolderPath('Desktop')) {
        $link = $shell.CreateShortcut((Join-Path $folder 'Iris.lnk'))
        $link.TargetPath = "$PSHOME\powershell.exe"
        $link.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`""
        $link.IconLocation = Join-Path $root 'assets\iris.ico'
        $link.WorkingDirectory = $root
        $link.Save()
    }
    return
}

$stopParty = {
    param($root, $state)
    Set-Location $root
    tailscale serve --https=443 off *> $null
    tailscale serve --tcp=59000 off *> $null
    docker compose down *> $null
    if ((Get-Content settings.json -Raw | ConvertFrom-Json).quitApps) {
        docker desktop stop *> $null
        # Without "Run unattended", Tailscale disconnects when its tray app exits; Iris reopens it next time.
        Get-Process tailscale-ipn -ErrorAction SilentlyContinue | Stop-Process -Force
    }
    $state.Stopped = $true
}

$startParty = {
    param($root, $state)
    Set-Location $root
    function Wait-For([scriptblock]$Test, $Seconds, $Failure) {
        $deadline = (Get-Date).AddSeconds($Seconds)
        while (-not (& $Test)) {
            if ((Get-Date) -gt $deadline) { throw $Failure }
            Start-Sleep -Seconds 1
        }
    }
    function Get-Tailnet { try { tailscale status --json | ConvertFrom-Json } catch { $null } }
    function Test-Healthy { (docker inspect -f '{{.State.Health.Status}}' iris-neko-1 2>$null) -eq 'healthy' }
    try {
        foreach ($app in @{ docker = 'Docker Desktop'; tailscale = 'Tailscale' }.GetEnumerator()) {
            if (-not (Get-Command $app.Key -ErrorAction SilentlyContinue)) { throw "$($app.Value) is not installed. Install it, then open Iris again." }
        }
        $state.Docker = 'busy'
        if ((Get-Tailnet).BackendState -ne 'Running') { Start-Process "$env:ProgramFiles\Tailscale\tailscale-ipn.exe" }
        docker info *> $null
        if ($LASTEXITCODE) { Start-Process "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe" }
        Wait-For { docker info *> $null; -not $LASTEXITCODE } 240 'Docker Desktop did not start. Open it, then open Iris again.'
        $state.Docker = 'done'

        $state.Tailscale = 'busy'
        Wait-For { (Get-Tailnet).BackendState -eq 'Running' } 90 'Tailscale is not connected. Sign in from its tray icon, then open Iris again.'
        $tailnet = Get-Tailnet
        $address = 'TS_IP=' + ($tailnet.TailscaleIPs | Where-Object { $_ -notmatch ':' } | Select-Object -First 1)
        $state.Url = 'https://' + $tailnet.Self.DNSName.TrimEnd('.')
        $state.Tailscale = 'done'

        $gpu = [bool](& "$env:SystemRoot\System32\nvidia-smi.exe" -L 2>$null | Select-String 'GPU')
        while ($true) {
            $state.Live = $false; $state.Lockdown = 'busy'; $state.Browser = 'wait'
            $mode = (Get-Content settings.json -Raw | ConvertFrom-Json).mode
            if ($state.Wipe) {
                docker compose down *> $null
                docker volume rm iris_profile *> $null
                $state.Wipe = $false
            }
            $files = @('-f', 'docker-compose.yaml')
            if ($mode -eq 'saved') { $files += '-f', 'stack/saved.yaml' }
            $signature = "$address`nIRIS_MODE=$mode`nIRIS_ENCODER=$(if ($gpu) { 'gpu' } else { 'cpu' })"
            $same = (Test-Path .env) -and ((Get-Content .env -Raw).Trim() -eq $signature)
            if (-not ((Test-Healthy) -and $same)) {
                foreach ($useGpu in @($gpu, $false) | Select-Object -Unique) {
                    $stack = if ($useGpu) { $files + @('-f', 'stack/gpu.yaml') } else { $files }
                    Set-Content .env "$address`nIRIS_MODE=$mode`nIRIS_ENCODER=$(if ($useGpu) { 'gpu' } else { 'cpu' })" -Encoding ascii
                    docker compose @stack pull --quiet neko *> $null
                    docker compose @stack up -d --force-recreate --quiet-pull *> $null
                    if (-not $LASTEXITCODE) { $gpu = $useGpu; break }
                }
                if ($LASTEXITCODE) { throw 'Docker could not start the shared browser. Open Iris again to retry.' }
                $state.Fresh = $true
            }
            $state.Gpu = $gpu
            if ((docker wait iris-firewall-1 2>$null) -ne '0') {
                docker compose down *> $null
                throw 'The network lockdown failed, so the party was stopped to stay safe. Open Iris again to retry.'
            }
            $state.Warning = if ((docker logs iris-firewall-1 2>&1 | Out-String) -match 'tick:\s+(\d+)' -and [math]::Abs([int]$Matches[1] - 10000) -gt 50) {
                "Video will stutter: this laptop's Linux clock is running at the wrong speed. See Troubleshooting."
            } elseif ((Get-NetConnectionProfile -InterfaceAlias Tailscale -ErrorAction SilentlyContinue).NetworkCategory -eq 'Public') {
                'Guests may lag: Windows treats the Tailscale network as Public. See Troubleshooting.'
            }
            $state.Lockdown = 'done'

            $state.Browser = 'busy'
            Wait-For { Test-Healthy } 120 'The shared browser did not start. Open Iris again to retry.'
            tailscale serve --bg --https=443 http://127.0.0.1:8080 *> $null
            tailscale serve --bg --tcp=59000 tcp://127.0.0.1:59000 *> $null
            $state.Browser = 'done'
            $state.Live = $true

            $misses = 0; $tick = 0
            while ($misses -lt 2 -and -not $state.Stopped -and -not $state.Restart) {
                Start-Sleep -Seconds 1
                if (++$tick % 15) { continue }
                $misses = if (Test-Healthy) { 0 } else { $misses + 1 }
            }
            if ($state.Stopped) { return }
            if ($state.Restart) { $state.Restart = $false; continue }
            throw 'The shared browser stopped unexpectedly. Close this window and open Iris again.'
        }
    } catch { $state.Live = $false; $state.Error = "$_" }
}

if ($Stop) { & $stopParty $root @{}; return }

$mutex = New-Object Threading.Mutex($false, 'IrisWatchParty')
if (-not $Snapshot -and -not $mutex.WaitOne(0)) { return }
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
# Keeps Windows from sleeping while a party is live, the way a video player does.
Add-Type -Namespace Iris -Name Power -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint flags);'

$peopleFile = Join-Path $root 'people.json'
$settingsFile = Join-Path $root 'settings.json'
function Get-People { Get-Content $peopleFile -Raw | ConvertFrom-Json }
function Get-Mode { (Get-Content $settingsFile -Raw | ConvertFrom-Json).mode }
function Save-Setting($name, $value) {
    $settings = Get-Content $settingsFile -Raw | ConvertFrom-Json
    $settings | Add-Member $name $value -Force
    [IO.File]::WriteAllText($settingsFile, ($settings | ConvertTo-Json))
}

function Save-People($people) {
    [IO.File]::WriteAllText($peopleFile, ($people | ConvertTo-Json -Depth 4))
    [void](New-Item -ItemType Directory -Force (Join-Path $root 'data'))
    $sha = [Security.Cryptography.SHA256]::Create()
    $members = [ordered]@{}
    foreach ($person in @($people.host) + @($people.guests)) {
        $isHost = $person.name -eq $people.host.name
        $members[$person.name] = @{
            password = [Convert]::ToBase64String($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($person.password)))
            profile  = @{
                name = $person.name; is_admin = $isHost; can_login = $true; can_connect = $true; can_watch = $true
                can_host = $true; can_share_media = $true; can_access_clipboard = $true
                sends_inactive_cursor = $true; can_see_inactive_cursors = $isHost; plugins = @{}
            }
        }
    }
    $members[$keeper] = @{
        password = [Convert]::ToBase64String($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($keeperPassword)))
        profile  = @{ name = $keeper; is_admin = $true; can_login = $true; can_connect = $false; can_watch = $false; plugins = @{} }
    }
    [IO.File]::WriteAllText((Join-Path $root 'data\members.json'), ($members | ConvertTo-Json -Depth 5))
}

function New-Password {
    $bytes = New-Object byte[] 10
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    -join ($bytes | ForEach-Object { $_.ToString('x2') })
}

# API-only admin, so a removed guest's open session can be ended. The dot keeps it out of guest names.
$keeper = 'iris.admin'
$keeperPassword = New-Password
function Close-Session($name) {
    $api = 'http://127.0.0.1:8080/api'
    try {
        $login = Invoke-RestMethod "$api/login" -TimeoutSec 5 -Method Post -ContentType application/json -Body (@{ username = $keeper; password = $keeperPassword } | ConvertTo-Json)
        $auth = @{ Authorization = "Bearer $($login.token)" }
        try { Invoke-RestMethod "$api/sessions/$name" -TimeoutSec 5 -Method Delete -Headers $auth | Out-Null } catch {}
        Invoke-RestMethod "$api/logout" -TimeoutSec 5 -Method Post -Headers $auth | Out-Null
    } catch {}
}

function Get-Link($person) { "$($state.Url)/?usr=$([Uri]::EscapeDataString($person.name))&pwd=$([Uri]::EscapeDataString($person.password))" }

$state = [hashtable]::Synchronized(@{ Docker = 'wait'; Tailscale = 'wait'; Lockdown = 'wait'; Browser = 'wait' })
function Start-Worker([scriptblock]$Script) {
    $worker = [powershell]::Create()
    [void]$worker.AddScript($Script).AddArgument($root).AddArgument($state)
    [void]$worker.BeginInvoke()
}

$window = [Windows.Markup.XamlReader]::Parse((Get-Content (Join-Path $root 'ui\Iris.xaml') -Raw))
$window.Icon = [Windows.Media.Imaging.BitmapFrame]::Create([Uri](Join-Path $root 'assets\iris.ico'))
$ui = @{}
'Headline', 'Sub', 'Ring', 'Pupil', 'GuestList', 'NewGuest', 'Placeholder', 'AddGuest', 'GuestNote', 'OpenView', 'EndParty',
'Minimize', 'Close', 'Sheet', 'SheetNote', 'SheetEnd', 'SheetKeep', 'SheetCancel', 'ModeSaved', 'ModeFresh', 'ModeNote',
'ClearSaved', 'QuitApps' | ForEach-Object { $ui[$_] = $window.FindName($_) }
$ui.Ring.Source = New-Object Windows.Media.Imaging.BitmapImage ([Uri](Join-Path $root 'assets\ring.png'))

$brushes = New-Object Windows.Media.BrushConverter
$hues = '#FF6B8B', '#FFA36B', '#FFE08A', '#7BE7B5', '#6BC7FF', '#9D8CFF'
$stepText = [ordered]@{
    Docker = 'Starting Docker'; Tailscale = 'Connecting to Tailscale'
    Lockdown = 'Locking down the network'; Browser = 'Starting the shared browser'
}
$modeText = @{
    saved = @{ note = 'Keeps logins and open tabs between parties.'; ending = 'Ending it closes the shared browser. Your logins and tabs are kept for next time.' }
    fresh = @{ note = 'Starts empty every time.'; ending = 'Ending it closes the shared browser and wipes everything in it.' }
}
$still = [bool]$Snapshot -or -not [Windows.SystemParameters]::ClientAreaAnimation
$crossMark = '<Path xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Data="M0,0 L8,8 M8,0 L0,8" Stroke="#ADA5CF" StrokeThickness="1.4" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>'

$ring = @{ now = 0.0; goal = 0.0 }
function Set-Ring($amount) {
    if ($amount -ge 0.999) { $ui.Ring.Clip = $null; return }
    $angle = 2 * [math]::PI * [math]::Max($amount, 0.0001)
    $plain = [Globalization.CultureInfo]::InvariantCulture
    $x = (62 + 90 * [math]::Sin($angle)).ToString('0.###', $plain)
    $y = (62 - 90 * [math]::Cos($angle)).ToString('0.###', $plain)
    $ui.Ring.Clip = [Windows.Media.Geometry]::Parse("M62,62 L62,-28 A90,90 0 $([int]($amount -gt 0.5)) 1 $x,$y Z")
}
$tween = New-Object Windows.Threading.DispatcherTimer -Property @{ Interval = [TimeSpan]::FromMilliseconds(16) }
$tween.Add_Tick({
    $ring.now += ($ring.goal - $ring.now) * 0.14
    if ([math]::Abs($ring.goal - $ring.now) -lt 0.004) { $ring.now = $ring.goal; $tween.Stop() }
    Set-Ring $ring.now
})
function Move-Ring($goal) {
    if ($goal -eq $ring.goal) { return }
    $ring.goal = $goal
    if ($still) { $ring.now = $goal; Set-Ring $goal } else { $tween.Start() }
}

function Show-Note($text) {
    $ui.GuestNote.Text = $text
    $ui.GuestNote.Visibility = if ($text) { 'Visible' } else { 'Collapsed' }
}

function Show-Mode {
    $mode = Get-Mode
    foreach ($pair in @(@($ui.ModeSaved, 'saved'), @($ui.ModeFresh, 'fresh'))) {
        $on = $pair[1] -eq $mode
        $pair[0].Background = if ($on) { $window.FindResource('Cloud') } else { [Windows.Media.Brushes]::Transparent }
        $pair[0].Foreground = if ($on) { $window.FindResource('Ink') } else { $window.FindResource('Haze') }
        $pair[0].IsEnabled = [bool]$state.Live
    }
    $ui.ModeNote.Text = $modeText[$mode].note
    $ui.SheetNote.Text = $modeText[$mode].ending
    $ui.ClearSaved.Visibility = if ($mode -eq 'saved') { 'Visible' } else { 'Collapsed' }
    $ui.ClearSaved.IsEnabled = [bool]$state.Live
    $ui.ClearSaved.Content = 'Clear saved data'
}

function Set-Mode($mode) {
    if ($mode -eq (Get-Mode) -or -not $state.Live) { return }
    Save-Setting mode $mode
    $script:switching = "Switching to $($mode.Substring(0,1).ToUpper() + $mode.Substring(1))"
    $state.Restart = $true
    $state.Live = $false
    Show-Mode
}

function Clear-Saved {
    if ($ui.ClearSaved.Content -ne 'Click again to clear') {
        $ui.ClearSaved.Content = 'Click again to clear'
        $undo = New-Object Windows.Threading.DispatcherTimer -Property @{ Interval = [TimeSpan]::FromSeconds(4) }
        $undo.Add_Tick({ if ($ui.ClearSaved.Content -eq 'Click again to clear') { $ui.ClearSaved.Content = 'Clear saved data' }; $this.Stop() })
        $undo.Start()
        return
    }
    $script:switching = 'Clearing saved data'
    $state.Wipe = $true
    $state.Restart = $true
    $state.Live = $false
    Show-Mode
}

function Show-Guests {
    $ui.GuestList.Children.Clear()
    $index = 0
    foreach ($guest in @((Get-People).guests)) {
        $row = New-Object Windows.Controls.DockPanel -Property @{ Margin = '0,0,0,10' }
        $badge = New-Object Windows.Controls.Border -Property @{
            Width = 34; Height = 34; CornerRadius = '17'; Margin = '0,0,12,0'
            Background = $brushes.ConvertFromString($hues[$index++ % $hues.Count])
            Child = New-Object Windows.Controls.TextBlock -Property @{
                Text = $guest.name.Substring(0, 1).ToUpper(); FontWeight = 'SemiBold'; Foreground = $window.FindResource('Ink')
                HorizontalAlignment = 'Center'; VerticalAlignment = 'Center'
            }
        }
        $remove = New-Object Windows.Controls.Button -Property @{
            Content = [Windows.Markup.XamlReader]::Parse($crossMark); Style = $window.FindResource('Glyph')
            Margin = '4,0,-8,0'; Uid = $guest.name; ToolTip = "Remove $($guest.name)"
        }
        [Windows.Automation.AutomationProperties]::SetName($remove, "Remove $($guest.name)")
        $copy = New-Object Windows.Controls.Button -Property @{
            Content = 'Copy link'; Style = $window.FindResource('Soft'); Uid = $guest.name; IsEnabled = [bool]$state.Live
        }
        [Windows.Automation.AutomationProperties]::SetName($copy, "Copy link for $($guest.name)")
        $name = New-Object Windows.Controls.TextBlock -Property @{ Text = $guest.name; FontSize = 15; VerticalAlignment = 'Center' }
        [Windows.Controls.DockPanel]::SetDock($remove, 'Right')
        [Windows.Controls.DockPanel]::SetDock($copy, 'Right')
        $remove.Add_Click({ Remove-Guest $this.Uid })
        $copy.Add_Click({ Copy-Invite $this })
        $remove, $copy, $badge, $name | ForEach-Object { [void]$row.Children.Add($_) }
        [void]$ui.GuestList.Children.Add($row)
    }
}

function Copy-Invite($button) {
    $name = $button.Uid
    $guest = (Get-People).guests | Where-Object { $_.name -eq $name }
    $rainbow = [char]::ConvertFromUtf32(0x1F308)
    [Windows.Clipboard]::SetText(@"
$rainbow Iris is calling, $name! Come watch with me:
$(Get-Link $guest)

First time only: install Tailscale (https://tailscale.com/download), sign in, and accept the share invite I sent you. After that it is just this link.
"@)
    $button.Content = 'Link copied'
    $revert = New-Object Windows.Threading.DispatcherTimer -Property @{ Interval = [TimeSpan]::FromSeconds(2); Tag = $button }
    $revert.Add_Tick({ $this.Tag.Content = 'Copy link'; $this.Stop() })
    $revert.Start()
}

function Add-Guest {
    $name = $ui.NewGuest.Text.Trim()
    $people = Get-People
    if ($name -notmatch '^[A-Za-z0-9_-]{1,24}$') {
        Show-Note 'Use letters, numbers, - or _ for the name, with no spaces.'
        return
    }
    if (@($people.host.name) + @($people.guests | ForEach-Object { $_.name }) -contains $name) {
        Show-Note "$name is already on the list."
        return
    }
    $people.guests = @($people.guests) + [pscustomobject]@{ name = $name; password = New-Password }
    Save-People $people
    $ui.NewGuest.Clear()
    Show-Guests
    Show-Note "$name added. They also need a Tailscale share to this laptop before their link works."
}

function Remove-Guest($name) {
    $people = Get-People
    $people.guests = @($people.guests | Where-Object { $_.name -ne $name })
    Save-People $people
    if ($state.Live) { Close-Session $name }
    Show-Guests
    Show-Note "$name removed. Their link no longer works."
}

function Update-View {
    if ($state.Stopped) { $script:leaving = $true; $window.Close(); return }
    if ($script:ending) { return }
    if ($state.Live) {
        if ($script:shownLive) { return }
        $script:shownLive = $true
        $ui.Headline.Text = "You're live"
        [void][Iris.Power]::SetThreadExecutionState(2147483649)
        $ui.Sub.Text = if ($state.Warning) { $state.Warning } elseif ($script:switching) { 'Back live. Everyone, you included, needs to refresh their page.' } elseif ($state.Gpu) { 'Copy a link for your guest, then press play.' } else { 'Running without the graphics card, so the picture is capped at 30 fps.' }
        $script:switching = $null
        $ui.OpenView.IsEnabled = $true
        $ui.Pupil.Opacity = 1
        Move-Ring 1
        Show-Guests
        Show-Mode
        if ($state.Fresh -and -not $script:opened -and -not $Snapshot) { Start-Process (Get-Link (Get-People).host); $script:opened = $true }
        return
    }
    if ($script:shownLive) {
        $script:shownLive = $false
        [void][Iris.Power]::SetThreadExecutionState(2147483648)
        $ui.OpenView.IsEnabled = $false
        $ui.Pupil.Opacity = 0.3
        Show-Guests
        Show-Mode
    }
    if ($state.Error) {
        $ui.Headline.Text = 'Iris stopped'
        $ui.Sub.Text = $state.Error
        $ui.Pupil.Opacity = 0.3
        return
    }
    $ui.Headline.Text = if ($script:switching) { $script:switching } else { 'Opening up' }
    $done = @($stepText.Keys | Where-Object { $state[$_] -eq 'done' }).Count
    $busy = $stepText.Keys | Where-Object { $state[$_] -eq 'busy' } | Select-Object -First 1
    Move-Ring (($done + 0.5 * [int][bool]$busy) / 4)
    if ($busy) { $ui.Sub.Text = $stepText[$busy] }
}

function Stop-FromWindow {
    $script:ending = $true
    $ui.Sheet.Visibility = 'Collapsed'
    $ui.Headline.Text = 'Closing up'
    $ui.Sub.Text = $(if ((Get-Mode) -eq 'saved') { 'Closing the shared browser' } else { 'Wiping the shared browser' }) +
        $(if ($ui.QuitApps.IsChecked) { ', then quitting Docker and Tailscale' } else { '' })
    $ui.EndParty.IsEnabled = $false
    $ui.OpenView.IsEnabled = $false
    $ui.ModeSaved.IsEnabled = $false
    $ui.ModeFresh.IsEnabled = $false
    $ui.ClearSaved.IsEnabled = $false
    $ui.Pupil.Opacity = 0.3
    Move-Ring 0
    Start-Worker $stopParty
}

$ui.AddGuest.Add_Click({ Add-Guest })
$ui.NewGuest.Add_KeyDown({ if ($_.Key -eq 'Return') { Add-Guest } })
$ui.NewGuest.Add_TextChanged({ $ui.Placeholder.Visibility = if ($ui.NewGuest.Text) { 'Collapsed' } else { 'Visible' } })
$ui.OpenView.Add_Click({ Start-Process (Get-Link (Get-People).host) })
$ui.EndParty.Add_Click({ if ($state.Live -or $state.Error) { Stop-FromWindow } })
$ui.ModeSaved.Add_Click({ Set-Mode 'saved' })
$ui.ModeFresh.Add_Click({ Set-Mode 'fresh' })
$ui.ClearSaved.Add_Click({ Clear-Saved })
$ui.QuitApps.Add_Checked({ Save-Setting quitApps $true })
$ui.QuitApps.Add_Unchecked({ Save-Setting quitApps $false })
$ui.SheetEnd.Add_Click({ Stop-FromWindow })
$ui.SheetKeep.Add_Click({ $script:leaving = $true; $window.Close() })
$ui.SheetCancel.Add_Click({ $ui.Sheet.Visibility = 'Collapsed' })
$ui.Close.Add_Click({ $window.Close() })
$ui.Minimize.Add_Click({ $window.WindowState = 'Minimized' })
$window.Add_KeyDown({ if ($_.Key -eq 'Escape') { $ui.Sheet.Visibility = 'Collapsed' } })
$window.Add_MouseLeftButtonDown({ try { $window.DragMove() } catch {} })
$window.Add_Closing({
    if ($state.Stopped -or $script:leaving) { return }
    $_.Cancel = $true
    if ($script:ending) { return }
    if ($state.Error) {
        Stop-FromWindow
    } elseif ($state.Live) {
        $ui.Sheet.Visibility = 'Visible'
        [void]$ui.SheetEnd.Focus()
    } else {
        $ui.Sub.Text = 'Still starting. You can close this in a moment.'
    }
})

if (-not (Test-Path $settingsFile)) { [IO.File]::WriteAllText($settingsFile, '{"mode": "fresh"}') }
if (-not (Test-Path $peopleFile)) { Save-People ([pscustomobject]@{ host = [pscustomobject]@{ name = 'Host'; password = New-Password }; guests = @() }) }
if (-not $Snapshot) { Save-People (Get-People) }
$ui.QuitApps.IsChecked = [bool](Get-Content $settingsFile -Raw | ConvertFrom-Json).quitApps
Show-Guests
Show-Mode
Set-Ring 0

if ($Snapshot) {
    foreach ($key in @($stepText.Keys)) { $state[$key] = 'done' }
    $state.Url = 'https://example.ts.net'; $state.Live = $true; $state.Gpu = $true
    $window.WindowStartupLocation = 'Manual'; $window.Left = -4000; $window.ShowInTaskbar = $false
    $window.Show(); Update-View
    if ($Snapshot -match 'sheet') { $ui.Sheet.Visibility = 'Visible' }
    $window.Dispatcher.Invoke([Action] {}, 'ApplicationIdle')
    $image = New-Object Windows.Media.Imaging.RenderTargetBitmap ([int]($window.ActualWidth * 2)), ([int]($window.ActualHeight * 2)), 192, 192, ([Windows.Media.PixelFormats]::Pbgra32)
    $image.Render($window.Content)
    $encoder = New-Object Windows.Media.Imaging.PngBitmapEncoder
    $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($image))
    $file = [IO.File]::Create($Snapshot); $encoder.Save($file); $file.Close()
    $script:leaving = $true; $window.Close()
    return
}

Start-Worker $startParty
$timer = New-Object Windows.Threading.DispatcherTimer -Property @{ Interval = [TimeSpan]::FromMilliseconds(400) }
$timer.Add_Tick({ Update-View })
$timer.Start()
Update-View
[void]$window.ShowDialog()
$timer.Stop()
$mutex.ReleaseMutex()
