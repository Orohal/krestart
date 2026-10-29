#requires -Version 5.1
<#
.SYNOPSIS
    Funktionstest fuer die Win32/C++-Variante (main.cpp).

.DESCRIPTION
    Startet KodiWolListener.exe und prueft Listenerstart, Magic-Packet-
    Erkennung, den Kodi-Neustart (mit Fake-Kodi), den Cooldown, die
    Behandlung eines ungueltigen Kodi-Pfads, das Stoppen und das Beenden.
    Die echte Kodi-Installation wird dabei nicht gestartet oder beendet.

.PARAMETER ExePath
    Pfad zur gebauten KodiWolListener.exe. Ohne Angabe werden die ueblichen
    CMake-Ausgabepfade unter build\mingw\ und build\ durchsucht.

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

Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;

namespace KodiWolListenerTests
{
    public static class Win32
    {
        [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "FindWindowW")]
        public static extern IntPtr FindWindow(string className, string windowName);

        [DllImport("user32.dll")]
        public static extern IntPtr GetDlgItem(IntPtr hWnd, int id);

        [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "SendMessageW")]
        public static extern IntPtr SendMessage(IntPtr hWnd, uint msg, IntPtr wParam, string lParam);

        [DllImport("user32.dll", EntryPoint = "SendMessageW")]
        public static extern IntPtr SendMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

        [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "SendMessageW")]
        public static extern IntPtr SendMessage(IntPtr hWnd, uint msg, IntPtr wParam, StringBuilder lParam);
    }
}
'@

$wmSetText = 0x000C
$wmGetText = 0x000D
$wmGetTextLength = 0x000E
$bmClick = 0x00F5

function Resolve-CppExe {
    param([string]$Path)

    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        return (Resolve-Path -Path $Path).Path
    }

    $candidates = @(
        (Join-Path $PSScriptRoot '..\build\mingw\KodiWolListener.exe'),
        (Join-Path $PSScriptRoot '..\build-mingw\KodiWolListener.exe'),
        (Join-Path $PSScriptRoot '..\build\Release\KodiWolListener.exe'),
        (Join-Path $PSScriptRoot '..\build\KodiWolListener.exe'),
        (Join-Path $PSScriptRoot '..\build\Debug\KodiWolListener.exe')
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -Path $candidate) {
            return (Resolve-Path -Path $candidate).Path
        }
    }

    return ''
}

function Get-ControlText {
    param([IntPtr]$Control)

    $length = [int][KodiWolListenerTests.Win32]::SendMessage(
        $Control, $wmGetTextLength, [IntPtr]::Zero, [IntPtr]::Zero)
    if ($length -le 0) { return '' }

    $buffer = New-Object System.Text.StringBuilder ($length + 1)
    $null = [KodiWolListenerTests.Win32]::SendMessage(
        $Control, $wmGetText, [IntPtr]($length + 1), $buffer)
    return $buffer.ToString()
}

function Set-ControlText {
    param([IntPtr]$Control, [string]$Text)
    $null = [KodiWolListenerTests.Win32]::SendMessage(
        $Control, $wmSetText, [IntPtr]::Zero, $Text)
}

function Invoke-Button {
    param([IntPtr]$Button)
    $null = [KodiWolListenerTests.Win32]::SendMessage(
        $Button, $bmClick, [IntPtr]::Zero, [IntPtr]::Zero)
}

function Wait-ControlTextAfter {
    param(
        [IntPtr]$Control,
        [int]$StartLength,
        [string]$Pattern,
        [int]$TimeoutMs = 8000
    )

    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    do {
        $text = Get-ControlText $Control
        if ($text.Length -gt $StartLength) {
            $newText = $text.Substring($StartLength)
            if ($newText -match $Pattern) { return $newText }
        }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)

    $text = Get-ControlText $Control
    if ($text.Length -gt $StartLength) { return $text.Substring($StartLength) }
    return ''
}

$exe = Resolve-CppExe -Path $ExePath
if ([string]::IsNullOrWhiteSpace($exe)) {
    throw 'KodiWolListener.exe nicht gefunden. Zuerst bauen (siehe CMakeLists.txt) oder -ExePath angeben.'
}

if (Get-Process kodi, KodiWolListener -ErrorAction SilentlyContinue) {
    throw 'kodi.exe oder KodiWolListener laeuft bereits. Test abgebrochen.'
}

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$workDir = New-TestWorkspace
$marker = Join-Path $workDir 'fake-kodi-started.txt'
$process = $null

try {
    $fakeKodi = Build-FakeKodi -RepositoryRoot $repositoryRoot -OutputDirectory (Join-Path $workDir 'fake-kodi')
    $env:FAKE_KODI_MARKER = $marker

    $process = Start-Process -FilePath $exe -PassThru

    $window = [IntPtr]::Zero
    for ($i = 0; $i -lt 100 -and $window -eq [IntPtr]::Zero; $i++) {
        $window = [KodiWolListenerTests.Win32]::FindWindow('KodiWolListenerClass', 'Kodi WoL Restart Listener')
        if ($window -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 100 }
    }
    if ($window -eq [IntPtr]::Zero) { throw 'Anwendungsfenster nicht gefunden.' }

    $editPath = [KodiWolListenerTests.Win32]::GetDlgItem($window, 102)
    $editLog = [KodiWolListenerTests.Win32]::GetDlgItem($window, 103)
    $button = [KodiWolListenerTests.Win32]::GetDlgItem($window, 101)
    if ($editPath -eq [IntPtr]::Zero -or $editLog -eq [IntPtr]::Zero -or $button -eq [IntPtr]::Zero) {
        throw 'Steuerelemente nicht gefunden.'
    }

    # --- Szenario A: gueltiger Pfad, Magic Packet, Cooldown, Stop ---
    Set-ControlText $editPath $fakeKodi

    # Baseline vor dem Klick erfassen: die Meldung kann sonst bereits
    # geschrieben sein, bevor Wait-ControlTextAfter zu lesen beginnt.
    $baseline = (Get-ControlText $editLog).Length
    Invoke-Button $button
    $log = Wait-ControlTextAfter $editLog $baseline 'Listener aktiv auf UDP-Port 9'
    Assert-True ($log -match 'Listener aktiv auf UDP-Port 9') 'Listener bindet UDP-Port 9'

    $baseline = (Get-ControlText $editLog).Length
    Send-MagicPacket -Port 9
    $log = Wait-ControlTextAfter $editLog $baseline 'Kodi erfolgreich gestartet' 12000
    Assert-True ($log -match 'Magic Packet empfangen') 'Magic Packet wird erkannt'
    Assert-True ($log -match 'Kodi erfolgreich gestartet') 'Kodi (Fake) wird gestartet'
    Assert-True (Wait-Until -TimeoutMs 5000 -Condition { Test-Path $marker }) 'Fake-Kodi wurde ausgefuehrt'

    $baseline = (Get-ControlText $editLog).Length
    Send-MagicPacket -Port 9
    $log = Wait-ControlTextAfter $editLog $baseline 'Weiteres Magic Packet ignoriert' 5000
    Assert-True ($log -match 'Weiteres Magic Packet ignoriert') 'Cooldown ignoriert Folgepakete'

    $baseline = (Get-ControlText $editLog).Length
    Invoke-Button $button
    $log = Wait-ControlTextAfter $editLog $baseline 'Listener gestoppt'
    Assert-True ($log -match 'Listener gestoppt') 'Listener stoppt sauber'

    # --- Szenario B: ungueltiger Pfad wird abgefangen ---
    Remove-Item -Path $marker -ErrorAction SilentlyContinue
    Set-ControlText $editPath (Join-Path $workDir 'missing\kodi.exe')

    $baseline = (Get-ControlText $editLog).Length
    Invoke-Button $button
    $null = Wait-ControlTextAfter $editLog $baseline 'Listener aktiv auf UDP-Port 9'

    $baseline = (Get-ControlText $editLog).Length
    Send-MagicPacket -Port 9
    $log = Wait-ControlTextAfter $editLog $baseline 'Kodi wurde nicht gefunden' 12000
    Assert-True ($log -match 'Kodi wurde nicht gefunden') 'Ungueltiger Kodi-Pfad wird abgefangen'
    Assert-True (-not (Test-Path $marker)) 'Bei ungueltigem Pfad wird kein Prozess gestartet'

    $baseline = (Get-ControlText $editLog).Length
    Invoke-Button $button
    $null = Wait-ControlTextAfter $editLog $baseline 'Listener gestoppt'

    # --- Beenden ---
    $null = $process.CloseMainWindow()
    $exited = $process.WaitForExit(15000)
    if (-not $exited) { $process.Kill(); $null = $process.WaitForExit(5000) }
    Assert-True $exited 'Anwendung beendet sich innerhalb von 15 s'
    Assert-True ($exited -and $process.ExitCode -eq 0) 'Anwendung beendet sich mit Exit-Code 0'
}
finally {
    if ($null -ne $process -and -not $process.HasExited) {
        $process.Kill()
        $null = $process.WaitForExit(5000)
    }

    Remove-Item Env:\FAKE_KODI_MARKER -ErrorAction SilentlyContinue
    if (-not $KeepArtifacts) {
        Remove-Item -Path $workDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Assert-Complete
