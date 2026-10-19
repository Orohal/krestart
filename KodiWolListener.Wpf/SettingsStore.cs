using System;
using System.IO;
using System.Text.Json;

namespace KodiWolListener;

internal sealed class SettingsStore
{
    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true };
    private readonly string _settingsPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "KodiWolListener",
        "settings.json");

    public AppSettings Load(out string? warning)
    {
        warning = null;
        if (!File.Exists(_settingsPath))
            return new AppSettings();

        try
        {
            AppSettings? settings = JsonSerializer.Deserialize<AppSettings>(
                File.ReadAllText(_settingsPath),
                JsonOptions);
            if (settings is null)
            {
                warning = "Die Einstellungsdatei war leer oder ungültig. Standardwerte werden verwendet.";
                return new AppSettings();
            }

            if (settings.Port is not (7 or 9))
            {
                settings.Port = 9;
                warning = "Der gespeicherte UDP-Port war ungültig. Port 9 wird verwendet.";
            }

            return settings;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException)
        {
            warning = $"Einstellungen konnten nicht geladen werden; Standardwerte werden verwendet: {ex.Message}";
            return new AppSettings();
        }
    }

    public void Save(AppSettings settings)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(_settingsPath)!);
        File.WriteAllText(_settingsPath, JsonSerializer.Serialize(settings, JsonOptions));
    }
}
