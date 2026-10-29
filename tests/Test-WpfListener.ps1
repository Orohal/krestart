#requires -Version 5.1
<#
.SYNOPSIS
    Funktionstest fuer die WPF-Variante (KodiWolListener.Wpf).

.DESCRIPTION
    Startet die WPF-Anwendung und prueft per UI Automation den automatischen
    Listenerstart, die Magic-Packet-Erkennung, den Kodi-Neustart (mit
    Fake-Kodi), den Cooldown, das Stoppen und das Beenden - sowohl mit
    laufendem als auch mit gestopptem Listener (Regressionstest).

    Die echte Kodi-Installation wird nicht gestartet oder beendet. Die
    Einstellungen unter %LOCALAPPDATA%\KodiWolListener und der Autostart-
    Registrywert werden gesichert und anschliessend wiederhergestellt.

.PARAMETER ExePath
    Pfad zur gebauten KodiWolListener.exe. Ohne Angabe wird der Release-Build
    unter KodiWolListener.Wpf\bin\Release\net8.0-windows\ verwendet.

.PARAMETER KeepArtifacts
    Das temporaere Arbeitsverzeichnis mit Fake-Kodi und Markerdatei behalten.
#>
[CmdletBinding()]
param(
    [string]$ExePath = '',
    [switch]$KeepArtifacts
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$runValueName = 'KodiWolListener'
$windowTitle = 'Kodi WoL Listener'

function Resolve-WpfExe {
    param([string]$Path)

    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        return (Resolve-Path -Path $Path).Path
    }

    $candidates = @(
        (Join-Path $PSScriptRoot '..\KodiWolListener.Wpf\bin\Release\net8.0-windows\KodiWolListener.exe'),
        (Join-Path $PSScriptRoot '..\KodiWolListener.Wpf\bin\Debug\net8.0-windows\KodiWolListener.exe')
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -Path $candidate) {
            return (Resolve-Path -Path $candidate).Path
        }
    }

    return ''
}

function Find-AutomationElement {
    param(
        [Parameter(Mandatory = $true)]$Root,
        [Parameter(Mandatory = $true)][string]$AutomationId
    )

    $condition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty, $AutomationId)
    return $Root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
}

function Read-ElementText {
    param($Element)

    if ($null -eq $Element) { return '' }
    $pattern = $Element.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
    return $pattern.Current.Value
}

function Wait-LogText {
    param(
        [Parameter(Mandatory = $true)]$Element,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [int]$TimeoutMs = 10000
    )

    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    do {
        $text = Read-ElementText $Element
        if ($text -match $Pattern) { return $text }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)

    return (Read-ElementText $Element)
}

function Start-TestApp {
    param([Parameter(Mandatory = $true)][string]$Exe)

    $process = Start-Process -FilePath $Exe -PassThru
    $condition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $process.Id)

    $window = $null
    for ($i = 0; $i -lt 100 -and $null -eq $window; $i++) {
        Start-Sleep -Milliseconds 100
        $window = [System.Windows.Automation.AutomationElement]::RootElement.FindFirst(
            [System.Windows.Automation.TreeScope]::Children, $condition)
    }
    if ($null -eq $window) {
        if (-not $process.HasExited) { $process.Kill() }
        throw "WPF-Fenster von '$Exe' wurde nicht gefunden."
    }

    $logBox = Find-AutomationElement -Root $window -AutomationId 'LogTextBox'
    $listenerButton = Find-AutomationElement -Root $window -AutomationId 'ListenerButton'
    if ($null -eq $logBox) { throw 'LogTextBox wurde nicht gefunden.' }
    if ($null -eq $listenerButton) { throw 'ListenerButton wurde nicht gefunden.' }

    return [pscustomobject]@{
        Process        = $process
        Window         = $window
        Log            = $logBox
        ListenerButton = $listenerButton
    }
}

function Close-TestApp {
    param([Parameter(Mandatory = $true)]$App)

    $null = $App.Process.CloseMainWindow()
    if (-not $App.Process.WaitForExit(15000)) {
        $App.Process.Kill()
        $null = $App.Process.WaitForExit(5000)
        return [pscustomobject]@{ Exited = $false; ExitCode = $null }
    }

    return [pscustomobject]@{ Exited = $true; ExitCode = $App.Process.ExitCode }
}

$exe = Resolve-WpfExe -Path $ExePath
if ([string]::IsNullOrWhiteSpace($exe)) {
    throw 'KodiWolListener.exe nicht gefunden. Zuerst bauen (dotnet build) oder -ExePath angeben.'
}

if (Get-Process kodi, KodiWolListener -ErrorAction SilentlyContinue) {
    throw 'kodi.exe oder KodiWolListener laeuft bereits. Test abgebrochen.'
}

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$workDir = New-TestWorkspace
$marker = Join-Path $workDir 'fake-kodi-started.txt'
$settingsDirectory = Join-Path $env:LOCALAPPDATA 'KodiWolListener'
$settingsPath = Join-Path $settingsDirectory 'settings.json'
$app = $null

$settingsBackup = $null
if (Test-Path $settingsPath) {
    $settingsBackup = [IO.File]::ReadAllBytes($settingsPath)
}

$registryBackup = $null
$registryExisted = $false
$runProperties = Get-ItemProperty -Path $runKey -ErrorAction SilentlyContinue
if ($null -ne $runProperties -and $null -ne $runProperties.$runValueName) {
    $registryExisted = $true
    $registryBackup = $runProperties.$runValueName
}

try {
    $fakeKodi = Build-FakeKodi -RepositoryRoot $repositoryRoot -OutputDirectory (Join-Path $workDir 'fake-kodi')
    $env:FAKE_KODI_MARKER = $marker

    New-Item -ItemType Directory -Force -Path $settingsDirectory | Out-Null
    @{
        KodiPath              = $fakeKodi
        Port                  = 9
        StartAtWindowsStartup = $false
    } | ConvertTo-Json | Set-Content -Path $settingsPath -Encoding utf8

    # --- Szenario A: Listener aktiv, Magic Packet, Cooldown, Schliessen ---
    Remove-Item -Path $marker -ErrorAction SilentlyContinue
    $app = Start-TestApp -Exe $exe

    $log = Wait-LogText -Element $app.Log -Pattern 'Listener aktiv auf UDP-Port 9' -TimeoutMs 10000
    Assert-True ($log -match 'Listener aktiv auf UDP-Port 9') 'Listener startet automatisch auf UDP-Port 9'

    Send-MagicPacket -Port 9
    $log = Wait-LogText -Element $app.Log -Pattern 'Kodi wurde gestartet' -TimeoutMs 15000
    Assert-True ($log -match 'Magic Packet empfangen') 'Magic Packet wird erkannt'
    Assert-True ($log -match 'Kodi wurde gestartet') 'Kodi (Fake) wird gestartet'
    Assert-True (Wait-Until -TimeoutMs 5000 -Condition { Test-Path $marker }) 'Fake-Kodi wurde ausgefuehrt'

    Send-MagicPacket -Port 9
    $log = Wait-LogText -Element $app.Log -Pattern 'Weiteres Magic Packet ignoriert' -TimeoutMs 5000
    Assert-True ($log -match 'Weiteres Magic Packet ignoriert') 'Cooldown ignoriert Folgepakete'

    $closeResult = Close-TestApp -App $app
    $app = $null
    Assert-True $closeResult.Exited 'Schliessen mit aktivem Listener beendet die Anwendung'
    Assert-True ($closeResult.Exited -and $closeResult.ExitCode -eq 0) 'Schliessen mit aktivem Listener: Exit-Code 0'

    # --- Szenario B: Listener vorher stoppen, dann schliessen ---
    Remove-Item -Path $marker -ErrorAction SilentlyContinue
    $app = Start-TestApp -Exe $exe

    $log = Wait-LogText -Element $app.Log -Pattern 'Listener aktiv auf UDP-Port 9' -TimeoutMs 10000
    Assert-True ($log -match 'Listener aktiv auf UDP-Port 9') 'Zweiter Start: Listener ist wieder aktiv'

    $invoke = $app.ListenerButton.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
    $invoke.Invoke()

    $log = Wait-LogText -Element $app.Log -Pattern 'Listener gestoppt' -TimeoutMs 10000
    Assert-True ($log -match 'Listener gestoppt') 'Listener laesst sich stoppen'
    Assert-True (-not (Test-Path $marker)) 'Ohne Magic Packet wird kein Kodi gestartet'

    $closeResult = Close-TestApp -App $app
    $app = $null
    Assert-True $closeResult.Exited 'Schliessen ohne Listener beendet die Anwendung (Regressionstest)'
    Assert-True ($closeResult.Exited -and $closeResult.ExitCode -eq 0) 'Schliessen ohne Listener: Exit-Code 0'
}
finally {
    if ($null -ne $app) {
        $null = Close-TestApp -App $app
    }

    Remove-Item Env:\FAKE_KODI_MARKER -ErrorAction SilentlyContinue
    Remove-Item -Path $marker -ErrorAction SilentlyContinue

    if ($null -ne $settingsBackup) {
        [IO.File]::WriteAllBytes($settingsPath, $settingsBackup)
    } else {
        Remove-Item -Path $settingsPath -ErrorAction SilentlyContinue
    }

    if ($registryExisted) {
        Set-ItemProperty -Path $runKey -Name $runValueName -Value $registryBackup
    } else {
        Remove-ItemProperty -Path $runKey -Name $runValueName -ErrorAction SilentlyContinue
    }

    Assert-True (-not (Get-Process kodi -ErrorAction SilentlyContinue)) 'Es laeuft keine echte kodi.exe'

    if (-not $KeepArtifacts) {
        Remove-Item -Path $workDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Assert-Complete
