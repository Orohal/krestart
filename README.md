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

Führen Sie zum Erstellen der einzelnen, unabhängigen EXE-Datei folgenden Befehl im Projektverzeichnis aus:

```bash
dotnet publish -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:PublishReadyToRun=true
```

Die fertige Datei befindet sich anschließend unter:
`\bin\Release\netX.X\win-x64\publish\KodiWolListener.exe`

---

## 🚀 Nutzung und Parameter

Sie können die Anwendung direkt über die Kommandozeile starten. Standardmäßig lauscht das Programm auf **Port 9** und sucht Kodi im Standard-Installationspfad.

### Standardaufruf:
```cmd
KodiWolListener.exe
```

### Erweiterter Aufruf mit benutzerdefinierten Pfaden/Ports:
Falls Ihr Kodi an einem anderen Ort liegt oder Sie in Kore den WoL-Port (z. B. auf Port 7) geändert haben, übergeben Sie die Parameter beim Start:

```cmd
KodiWolListener.exe --port 7 --path "D:\Media\Kodi\kodi.exe"
```

### Parameter-Übersicht:
* `--port` oder `-p`: Der UDP-Port, auf den gehorcht wird (Standard: `9`).
* `--path` oder `-path`: Der absolute Pfad zur `kodi.exe` (Standard: `C:\Program Files\Kodi\kodi.exe`).

---

## 💡 Einrichtung als Windows-Autostart

Damit die Kore-App Ihren Kodi-PC jederzeit reaktivieren kann, sollte der Listener unsichtbar im Hintergrund laufen.

1. Drücken Sie `Win + R`, geben Sie `shell:startup` ein und drücken Sie Enter.
2. Erstellen Sie eine Verknüpfung der `KodiWolListener.exe` in diesem Ordner.
3. *Optional:* Setzen Sie in den Eigenschaften der Verknüpfung das Ausführen-Fenster auf "Minimiert", damit beim Windows-Start kein Konsolenfenster stört.
