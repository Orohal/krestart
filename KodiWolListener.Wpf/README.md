# Kodi WoL Listener

Windows 10/11 WPF-Anwendung auf Basis von .NET 8. Sie lauscht auf UDP-Port 7
oder 9 und startet Kodi nach einem gültigen 102-Byte-Wake-on-LAN-Magic-Packet
neu. Das Paket muss mit sechs `FF`-Bytes beginnen und danach dieselbe
6-Byte-MAC-Adresse genau 16-mal enthalten.

## Starten

`KodiWolListener.Wpf.csproj` mit dem .NET-8-SDK unter Windows öffnen oder im
Projektordner ausführen:

```powershell
dotnet run --project .\KodiWolListener.Wpf.csproj
```

Der Kodi-Pfad, UDP-Port und Autostart-Schalter werden unter
`%LOCALAPPDATA%\KodiWolListener\settings.json` gespeichert. Der Autostart wird
für den aktuellen Windows-Benutzer eingerichtet und startet die Anwendung
minimiert im Infobereich. Das Kontextmenü des Tray-Symbols bietet „Öffnen“ und
„Beenden“.

Für eingehende WoL-Pakete muss UDP-Port 7 oder 9 in der Windows-Firewall und
gegebenenfalls im Router freigegeben sein.
