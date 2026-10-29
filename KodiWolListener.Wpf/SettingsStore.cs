using System;
using System.IO;
using System.Text.Json;

namespace KodiWolListener;

internal sealed class SettingsStore
{
    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true };
    private readonly string _settingsDirectory = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "KodiWolListener");
    private readonly string _settingsPath;

    public SettingsStore()
    {
        _settingsPath = Path.Combine(_settingsDirectory, "settings.json");
    }

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
        Directory.CreateDirectory(_settingsDirectory);

        // Write to a temporary file first so an interrupted save cannot leave a
        // truncated settings file behind.
        string temporaryPath = _settingsPath + ".tmp";
        File.WriteAllText(temporaryPath, JsonSerializer.Serialize(settings, JsonOptions));
        File.Move(temporaryPath, _settingsPath, overwrite: true);
    }
}
