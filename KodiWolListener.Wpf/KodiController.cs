using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Threading;
using System.Threading.Tasks;

namespace KodiWolListener;

/// <summary>
/// Beendet die Kodi-Instanz aus dem konfigurierten Pfad und startet sie neu.
/// </summary>
internal sealed class KodiController
{
    private static readonly TimeSpan GracefulExitTimeout = TimeSpan.FromSeconds(5);
    private static readonly TimeSpan RestartDelay = TimeSpan.FromSeconds(1);

    private readonly string _kodiPath;
    private readonly Action<string> _log;

    public KodiController(string kodiPath, Action<string> log)
    {
        _kodiPath = kodiPath;
        _log = log;
    }

    public async Task RestartAsync()
    {
        _log("Magic Packet empfangen.");
        _log("Kodi wird neu gestartet…");

        string fullKodiPath;
        try
        {
            fullKodiPath = Path.GetFullPath(_kodiPath);
        }
        catch (Exception ex)
        {
            _log($"Kodi konnte nicht neu gestartet werden: ungültiger Pfad ({_kodiPath}): {ex.Message}");
            return;
        }

        Process[] kodiProcesses;
        try
        {
            kodiProcesses = Process.GetProcessesByName("kodi");
        }
        catch (Exception ex)
        {
            _log($"Kodi-Prozesse konnten nicht ermittelt werden: {ex.Message}");
            return;
        }

        bool inaccessibleInstance = false;
        bool matchingProcessNotStopped = false;

        foreach (Process process in kodiProcesses)
        {
            using (process)
            {
                bool isMatchingProcess = false;
                try
                {
                    if (process.HasExited)
                        continue;

                    string? processPath = process.MainModule?.FileName;
                    if (processPath is null)
                        continue;

                    // Only touch the Kodi instance that was configured in the UI.
                    if (!PathsEqual(processPath, fullKodiPath))
                    {
                        _log($"Kodi-Prozess (PID: {process.Id}) stammt aus einem anderen Verzeichnis und bleibt unangetastet.");
                        continue;
                    }

                    isMatchingProcess = true;
                    _log($"Beende Kodi-Prozess (PID: {process.Id})…");

                    // Without a main window (or if it refuses to close) there is
                    // nothing to wait for, so the process is killed right away.
                    if (process.CloseMainWindow())
                        await WaitForExitAsync(process, GracefulExitTimeout);

                    if (!process.HasExited)
                    {
                        process.Kill(entireProcessTree: true);
                        await process.WaitForExitAsync();
                    }
                }
                catch (Exception ex)
                {
                    // Reading MainModule fails with access denied when Kodi runs
                    // elevated or under another user account.
                    if (ex is UnauthorizedAccessException or Win32Exception { NativeErrorCode: 5 })
                        inaccessibleInstance = true;
                    else if (isMatchingProcess)
                        matchingProcessNotStopped = true;

                    _log($"Kodi-Prozess (PID: {process.Id}) konnte nicht beendet werden: {ex.Message}");
                }
            }
        }

        if (inaccessibleInstance)
        {
            _log("Kodi wurde nicht gestartet, um keine zweite Instanz zu erzeugen. Bitte den Listener mit denselben Rechten wie Kodi (ggf. als Administrator) ausführen.");
            return;
        }

        if (matchingProcessNotStopped)
        {
            _log("Kodi wurde nicht gestartet, weil der laufende Kodi-Prozess nicht beendet werden konnte.");
            return;
        }

        await Task.Delay(RestartDelay);
        try
        {
            if (!File.Exists(fullKodiPath))
            {
                _log($"Kodi konnte nicht gestartet werden: Datei nicht gefunden ({fullKodiPath}).");
                return;
            }

            Process? startedProcess = Process.Start(new ProcessStartInfo
            {
                FileName = fullKodiPath,
                WorkingDirectory = Path.GetDirectoryName(fullKodiPath)!,
                UseShellExecute = true
            });

            if (startedProcess is null)
            {
                _log("Kodi konnte nicht gestartet werden: Windows hat keinen Prozess erzeugt.");
                return;
            }

            startedProcess.Dispose();
            _log("Kodi wurde gestartet.");
        }
        catch (Exception ex)
        {
            _log($"Kodi konnte nicht gestartet werden: {ex.Message}");
        }
    }

    private static async Task WaitForExitAsync(Process process, TimeSpan timeout)
    {
        using var timeoutSource = new CancellationTokenSource(timeout);
        try
        {
            await process.WaitForExitAsync(timeoutSource.Token);
        }
        catch (OperationCanceledException)
        {
            // Timed out; the caller kills the process.
        }
    }

    private static bool PathsEqual(string first, string second)
    {
        try
        {
            return string.Equals(
                Path.GetFullPath(first),
                Path.GetFullPath(second),
                StringComparison.OrdinalIgnoreCase);
        }
        catch (Exception)
        {
            return false;
        }
    }
}
