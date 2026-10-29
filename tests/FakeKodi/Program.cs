using System;
using System.IO;

namespace FakeKodi;

/// <summary>
/// Schreibt beim Start eine Markerdatei. Wird von den Tests als Kodi-Ersatz
/// verwendet, damit niemals eine echte Kodi-Installation gestartet wird.
/// </summary>
internal static class Program
{
    private static void Main()
    {
        try
        {
            string? markerPath = Environment.GetEnvironmentVariable("FAKE_KODI_MARKER");
            if (!string.IsNullOrWhiteSpace(markerPath))
                File.WriteAllText(markerPath, DateTime.UtcNow.ToString("O"));
        }
        catch (Exception)
        {
            // Fehlt die Markerdatei, schlaegt der Test bewusst fehl.
        }
    }
}
