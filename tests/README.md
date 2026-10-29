# Tests

Funktionstests für beide Varianten des Kodi-WoL-Listeners. Die Tests starten
**kein echtes Kodi**. Stattdessen wird `tests/FakeKodi` gebaut und als
Kodi-Ersatz verwendet; die Anwendung schreibt dabei lediglich eine
Markerdatei in ein temporäres Verzeichnis.

## Voraussetzungen

* Windows (x64)
* .NET 8 SDK
* PowerShell 5.1 oder neuer
* Für den C++-Test: gebaute `KodiWolListener.exe` (CMake/MinGW oder MSVC)

## Bauen

```powershell
# WPF-Variante
dotnet build KodiWolListener.Wpf\KodiWolListener.Wpf.csproj -c Release

# C++-Variante (MinGW)
cmake -S . -B build\mingw -G "MinGW Makefiles" -DCMAKE_BUILD_TYPE=Release
cmake --build build\mingw
```

## Ausführen

```powershell
# Alle Tests
pwsh -NoProfile -File tests\Run-All.ps1

# Nur WPF
pwsh -NoProfile -File tests\Run-All.ps1 -SkipCpp

# Nur C++ (Pfad zur EXE explizit)
pwsh -NoProfile -File tests\Run-All.ps1 -SkipWpf -CppExePath build\mingw\KodiWolListener.exe
```

Einzelne Tests lassen sich auch direkt starten:

```powershell
pwsh -NoProfile -File tests\Test-WpfListener.ps1
pwsh -NoProfile -File tests\Test-CppListener.ps1 -ExePath build\mingw\KodiWolListener.exe
```

Fehlt die C++-EXE, überspringt `Run-All.ps1` diesen Test automatisch. Der
Runner sammelt alle Fehlschläge und beendet sich am Ende mit einem Fehler,
wenn mindestens ein Test fehlgeschlagen ist.

### Parameter

| Parameter | Bedeutung |
|---|---|
| `-CppExePath <Pfad>` | EXE der C++-Variante; sonst Suche unter `build\` |
| `-WpfExePath <Pfad>` | EXE der WPF-Variante; sonst Release-Build |
| `-SkipCpp` | C++-Test überspringen |
| `-SkipWpf` | WPF-Test überspringen |
| `-KeepArtifacts` | Temporäre Verzeichnisse (Fake-Kodi, Marker) behalten |

## Was geprüft wird

### WPF (`Test-WpfListener.ps1`)

* Fenster und Steuerelemente sind per UI Automation erreichbar
* Listener startet automatisch auf UDP-Port 9
* Magic Packet wird erkannt und Fake-Kodi gestartet
* Ein zweites Paket wird durch den 10-Sekunden-Cooldown ignoriert
* Schließen mit aktivem Listener beendet die Anwendung mit Exit-Code 0
* Listener lässt sich stoppen
* Schließen ohne Listener beendet die Anwendung mit Exit-Code 0
  (Regressionstest für den früheren `InvalidOperationException`-Absturz)

### C++ (`Test-CppListener.ps1`)

* Fenster und Steuerelemente (IDs 101/102/103) sind erreichbar
* Listener bindet UDP-Port 9
* Magic Packet wird erkannt und Fake-Kodi gestartet
* Cooldown ignoriert Folgepakete
* Ungültiger Kodi-Pfad wird abgefangen, ohne einen Prozess zu starten
* Listener stoppt sauber
* Anwendung beendet sich innerhalb von 15 s mit Exit-Code 0

## Nebenwirkungen und Aufräumen

Der WPF-Test sichert vor dem Lauf:

* `%LOCALAPPDATA%\KodiWolListener\settings.json`
* den Autostart-Wert `KodiWolListener` unter
  `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`

Beides wird im `finally`-Block wiederhergestellt, auch wenn ein Test
fehlschlägt.

Die Tests belegen UDP-Port 9. Läuft bereits ein anderer Listener auf diesem
Port oder eine echte `kodi.exe`, brechen die Tests mit einer Meldung ab,
statt fremde Prozesse zu beeinflussen.
