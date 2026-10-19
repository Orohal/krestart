namespace KodiWolListener;

internal sealed class AppSettings
{
    public string KodiPath { get; set; } = @"C:\Program Files\Kodi\kodi.exe";
    public int Port { get; set; } = 9;
    public bool StartAtWindowsStartup { get; set; }
}
