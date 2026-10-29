# Kodi WoL Listener (Windows x64 Standalone)

Ein leichtgewichtiger, im Hintergrund laufender UDP-Listener für Windows x64. Das Programm wartet auf ein standardisiertes **Wake-on-LAN (WoL) Magic Packet**, beendet eine eventuell hängende Kodi-Instanz und startet Kodi frisch neu. 

Da die Anwendung als **Self-Contained (eigenständig)** kompiliert wird, ist **keine separate Installation von .NET oder einer Laufzeitumgebung auf dem Ziel-PC erforderlich**.

---

## 📱 Steuerung über die Kore Android-App

Dieses Tool ist so konzipiert, dass es nahtlos mit **Kore**, der offiziellen Fernbedienung für Kodi unter Android, zusammenarbeitet. Wenn sich Ihr Kodi-PC im Ruhezustand befindet oder Kodi abgestürzt ist, verhält sich Kore wie folgt:

1. **Automatischer WoL-Trigger**: Beim Öffnen der Kore-App versucht diese, Verbindung mit Kodi aufzunehmen. Schlägt dies fehl, blendet die App eine Option ein, um den PC via **Wake-on-LAN** zu starten.
2. **Signal-Versand**: Sobald Sie in Kore auf "Aufwecken" (Send WoL) tippen, sendet die App ein Magic Packet an die Broadcast-Adresse Ihres Netzwerks auf **UDP-Port 9**.
3. **Reaktion des Listeners**: Unser Tool fängt dieses Paket ab, erkennt den Startwunsch der Kore-App und startet Kodi sofort auf dem Windows-PC.

---

## 🛠️ Build-Anleitung (Standalone-EXE)

Voraussetzung ist das .NET 8 SDK. Wechseln Sie in das Projektverzeichnis und führen Sie folgenden Befehl aus:

```bash
cd KodiWolListener.Wpf
dotnet publish -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:PublishReadyToRun=true -p:IncludeNativeLibrariesForSelfExtract=true
```

`IncludeNativeLibrariesForSelfExtract` packt auch die nativen WPF-Bibliotheken in die EXE. Ohne diese Option würden zusätzliche DLLs neben der EXE liegen.

Die fertige Datei befindet sich anschließend unter:
`bin\Release\net8.0-windows\win-x64\publish\KodiWolListener.exe`

Beim ersten Start entpackt die EXE die nativen Bibliotheken in ein temporäres Verzeichnis; danach startet sie schneller. Eine separate Installation von .NET ist nicht erforderlich. Die ebenfalls erzeugte `.pdb`-Datei wird zum Ausführen nicht benötigt.

---

## 🚀 Nutzung

Starten Sie die Anwendung per Doppelklick. Der Listener startet automatisch und lauscht standardmäßig auf **UDP-Port 9**. Pfad und Port stellen Sie direkt im Fenster ein.

* **Kodi-Installationspfad**: Standard ist `C:\Program Files\Kodi\kodi.exe`. Über „Datei auswählen…“ oder direkt im Textfeld ändern.
* **UDP-Port**: Muss zum in Kore eingestellten WoL-Port passen. Verfügbar sind `7` und `9` (Standard: `9`).
* **Listener starten/stoppen**: Der Listener läuft nach dem Start der Anwendung automatisch und lässt sich über den Button jederzeit stoppen und wieder starten.
* **System-Tray**: Beim Minimieren verschwindet das Fenster in den Tray. Ein Doppelklick öffnet es wieder, das Kontextmenü bietet „Öffnen“ und „Beenden“.

Die Einstellungen werden unter `%LOCALAPPDATA%\KodiWolListener\settings.json` gespeichert und beim nächsten Start automatisch geladen.

Beim Empfang eines Magic Packets wird ausschließlich die Kodi-Instanz beendet, die aus dem konfigurierten Pfad stammt. Weitere Magic Packets werden für 10 Sekunden nach einem Neustart ignoriert, damit Kodi nicht direkt nach dem Start erneut beendet wird.

---

## 💡 Einrichtung als Windows-Autostart

Aktivieren Sie im Fenster die Option **„Beim Windows-Start minimiert im System-Tray starten“**. Die Anwendung trägt sich dann selbst unter `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` ein und startet beim nächsten Login unsichtbar im Tray.

Zum Entfernen des Autostarts genügt es, die Option wieder zu deaktivieren. Wird die EXE an einen anderen Ort verschoben, starten Sie sie einmal mit aktiver Option, damit der neue Pfad registriert wird – der Eintrag wird bei jedem Start automatisch aktualisiert.

---

## 🧪 Tests

Im Ordner `tests\` liegen Funktionstests für beide Varianten. Sie verwenden
einen mitgelieferten Fake-Kodi und starten oder beenden niemals eine echte
Kodi-Installation. Details siehe [tests/README.md](tests/README.md).

```powershell
dotnet build KodiWolListener.Wpf\KodiWolListener.Wpf.csproj -c Release
pwsh -NoProfile -File tests\Run-All.ps1
```

Optional lässt sich die C++-Variante mitprüfen, sofern sie zuvor per CMake
gebaut wurde:

```powershell
cmake -S . -B build\mingw -G "MinGW Makefiles" -DCMAKE_BUILD_TYPE=Release
cmake --build build\mingw
pwsh -NoProfile -File tests\Run-All.ps1
```

---

## ⚠️ Hinweise

* **Windows-Firewall**: Erlauben Sie eingehende UDP-Verbindungen auf dem gewählten Port (`7` oder `9`) für `KodiWolListener.exe`. Ohne Freigabe erreichen die Magic Packets den Listener nicht.
* **Rechte**: Läuft Kodi erhöht (als Administrator), muss der Listener mit denselben Rechten laufen. Andernfalls kann er den laufenden Kodi-Prozess nicht beenden; in diesem Fall startet er bewusst keine zweite Instanz und schreibt einen Hinweis ins Protokoll.
* **Wake-on-LAN**: Damit der PC aus dem Ruhezustand aufgeweckt wird, muss WoL im BIOS/UEFI und im Netzwerkadapter aktiviert sein. Der Listener kann Kodi erst neu starten, wenn Windows bereits läuft.

---

## 📊 Clone Statistics

See the [full clone statistics](CLONE_STATS.md).
