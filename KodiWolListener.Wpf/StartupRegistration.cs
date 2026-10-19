using Microsoft.Win32;
using System;
using System.Diagnostics;

namespace KodiWolListener;

internal static class StartupRegistration
{
    private const string RunKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "KodiWolListener";
    public const string MinimizedArgument = "--minimized-to-tray";

    public static void SetEnabled(bool enabled)
    {
        using RegistryKey key = Registry.CurrentUser.CreateSubKey(RunKeyPath, writable: true)
            ?? throw new InvalidOperationException("Der Autostart-Registrierungsschlüssel konnte nicht geöffnet werden.");

        if (!enabled)
        {
            key.DeleteValue(ValueName, throwOnMissingValue: false);
            return;
        }

        string executablePath = Environment.ProcessPath
            ?? throw new InvalidOperationException("Der Pfad der laufenden Anwendung konnte nicht ermittelt werden.");
        key.SetValue(ValueName, $"\"{executablePath}\" {MinimizedArgument}", RegistryValueKind.String);
    }
}
