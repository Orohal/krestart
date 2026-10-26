using System;
using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Threading;
using System.Threading.Tasks;

namespace KodiWolListener;

internal static class WolListener
{
    // Senders such as Kore may emit the magic packet several times, and packets
    // that arrive while Kodi restarts stay queued in the socket. Ignore further
    // magic packets for this period after a restart so Kodi is not killed again
    // right after it was started.
    private static readonly TimeSpan RestartCooldown = TimeSpan.FromSeconds(10);

    public static async Task ListenAsync(
        int port,
        CancellationToken cancellationToken,
        Func<Task> onMagicPacket,
        Action<string> log,
        Action<bool> setActive)
    {
        UdpClient? udpClient = null;
        try
        {
            udpClient = new UdpClient(new IPEndPoint(IPAddress.Any, port));
        }
        catch (SocketException ex)
        {
            log($"Fehler beim Binden an Port {port}: {ex.Message}");
            return;
        }

        using (udpClient)
        {
            setActive(true);
            log($"Listener aktiv auf UDP-Port {port}. Warte auf WoL-Signal…");

            long lastRestartTimestamp = 0;
            try
            {
                while (!cancellationToken.IsCancellationRequested)
                {
                    UdpReceiveResult result = await udpClient.ReceiveAsync(cancellationToken);
                    if (!IsMagicPacket(result.Buffer))
                        continue;

                    if (lastRestartTimestamp != 0 &&
                        Stopwatch.GetElapsedTime(lastRestartTimestamp) < RestartCooldown)
                    {
                        log("Weiteres Magic Packet ignoriert (Neustart gerade ausgelöst).");
                        continue;
                    }

                    try
                    {
                        await onMagicPacket();
                    }
                    catch (Exception ex)
                    {
                        // A failed restart must not stop the listener.
                        log($"Kodi-Neustart fehlgeschlagen: {ex.Message}");
                    }
                    finally
                    {
                        lastRestartTimestamp = Stopwatch.GetTimestamp();
                    }
                }
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                // Normal shutdown via the stop button or window close.
            }
            catch (Exception ex)
            {
                log($"Fehler beim Empfangen: {ex.Message}");
            }
            finally
            {
                setActive(false);
                log("Listener gestoppt.");
            }
        }
    }

    private static bool IsMagicPacket(byte[] packet)
    {
        if (packet.Length != 102)
            return false;

        for (int i = 0; i < 6; i++)
        {
            if (packet[i] != 0xFF)
                return false;
        }

        ReadOnlySpan<byte> macAddress = packet.AsSpan(6, 6);
        for (int repetition = 1; repetition < 16; repetition++)
        {
            if (!packet.AsSpan(6 + repetition * 6, 6).SequenceEqual(macAddress))
                return false;
        }

        return true;
    }
}
