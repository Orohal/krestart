#requires -Version 5.1
<#
.SYNOPSIS
    Fuehrt alle Funktionstests des Kodi-WoL-Listeners aus.

.DESCRIPTION
    Startet nacheinander die Tests fuer die WPF-Variante und die
    Win32/C++-Variante. Beide Tests verwenden einen Fake-Kodi, damit niemals
    eine echte Kodi-Installation gestartet oder beendet wird.

    Die Anwendungen muessen vorher gebaut werden:
        dotnet build KodiWolListener.Wpf\KodiWolListener.Wpf.csproj -c Release
        cmake -S . -B build -G "MinGW Makefiles"
        cmake --build build

    Fehlschlaege werden gesammelt und am Ende als Fehler gemeldet
    (Exit-Code ungleich 0).

.PARAMETER CppExePath
    Pfad zur gebauten KodiWolListener.exe der C++-Variante. Ohne Angabe
    werden build\mingw, build-mingw, build\Release, build und build\Debug
    durchsucht.

.PARAMETER WpfExePath
    Pfad zur gebauten WPF-KodiWolListener.exe. Ohne Angabe wird der
    Release-Build verwendet.

.PARAMETER SkipCpp
    Den C++-Test ueberspringen.

.PARAMETER SkipWpf
    Den WPF-Test ueberspringen.

.PARAMETER KeepArtifacts
    Temporaere Arbeitsverzeichnisse der Tests behalten.
#>
[CmdletBinding()]
param(
    [string]$CppExePath = '',
    [string]$WpfExePath = '',
    [switch]$SkipCpp,
    [switch]$SkipWpf,
    [switch]$KeepArtifacts
)

$ErrorActionPreference = 'Stop'

$scripts = @{
    Cpp = Join-Path $PSScriptRoot 'Test-CppListener.ps1'
    Wpf = Join-Path $PSScriptRoot 'Test-WpfListener.ps1'
}

function Find-CppExe {
    param([string]$Path)

    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        if (Test-Path -Path $Path) { return (Resolve-Path -Path $Path).Path }
        return ''
    }

    $candidates = @(
        (Join-Path $PSScriptRoot '..\build\mingw\KodiWolListener.exe'),
        (Join-Path $PSScriptRoot '..\build-mingw\KodiWolListener.exe'),
        (Join-Path $PSScriptRoot '..\build\Release\KodiWolListener.exe'),
        (Join-Path $PSScriptRoot '..\build\KodiWolListener.exe'),
        (Join-Path $PSScriptRoot '..\build\Debug\KodiWolListener.exe')
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -Path $candidate) { return (Resolve-Path -Path $candidate).Path }
    }

    return ''
}

$results = New-Object System.Collections.Generic.List[object]

function Add-Result {
    param(
        [string]$Name,
        [string]$Status,
        [string]$Detail = ''
    )

    $results.Add([pscustomobject]@{
        Test   = $Name
        Status = $Status
        Detail = $Detail
    }) | Out-Null
}

function Invoke-TestScript {
    param(
        [string]$Name,
        [string]$Path,
        [hashtable]$Arguments
    )

    if (-not (Test-Path -Path $Path)) {
        Add-Result $Name 'FEHLER' "Skript nicht gefunden: $Path"
        return
    }

    Write-Host ''
    Write-Host ("=" * 70) -ForegroundColor Cyan
    Write-Host "  $Name" -ForegroundColor Cyan
    Write-Host ("=" * 70) -ForegroundColor Cyan

    $started = Get-Date
    try {
        & $Path @Arguments
        $duration = [int]((Get-Date) - $started).TotalSeconds
        Add-Result $Name 'OK' "$duration s"
    } catch {
        $duration = [int]((Get-Date) - $started).TotalSeconds
        Write-Host $_.Exception.Message -ForegroundColor Red
        Add-Result $Name 'FEHLER' "$duration s - $($_.Exception.Message)"
    }
}

if (-not $SkipCpp) {
    $exe = Find-CppExe -Path $CppExePath
    if ([string]::IsNullOrWhiteSpace($exe)) {
        Write-Host 'C++-Test uebersprungen: KodiWolListener.exe nicht gefunden (bitte bauen oder -CppExePath angeben).' -ForegroundColor Yellow
        Add-Result 'C++-Listener' 'UEBERSPRUNGEN' 'EXE nicht gefunden'
    } else {
        $arguments = @{ ExePath = $exe }
        if ($KeepArtifacts) { $arguments['KeepArtifacts'] = $true }
        Invoke-TestScript -Name 'C++-Listener' -Path $scripts.Cpp -Arguments $arguments
    }
} else {
    Add-Result 'C++-Listener' 'UEBERSPRUNGEN' '-SkipCpp'
}

if (-not $SkipWpf) {
    $arguments = @{}
    if (-not [string]::IsNullOrWhiteSpace($WpfExePath)) { $arguments['ExePath'] = $WpfExePath }
    if ($KeepArtifacts) { $arguments['KeepArtifacts'] = $true }
    Invoke-TestScript -Name 'WPF-Listener' -Path $scripts.Wpf -Arguments $arguments
} else {
    Add-Result 'WPF-Listener' 'UEBERSPRUNGEN' '-SkipWpf'
}

Write-Host ''
Write-Host 'Zusammenfassung' -ForegroundColor Cyan
$results | Format-Table -AutoSize | Out-String | Write-Host

$failed = @($results | Where-Object { $_.Status -eq 'FEHLER' })
if ($failed.Count -gt 0) {
    throw "$($failed.Count) Testlauf/Testlaeufe fehlgeschlagen: $($failed.Test -join ', ')"
}

if (@($results | Where-Object { $_.Status -eq 'OK' }).Count -eq 0) {
    throw 'Es wurde kein Test ausgefuehrt.'
}

Write-Host 'Alle ausgefuehrten Tests erfolgreich.' -ForegroundColor Green
