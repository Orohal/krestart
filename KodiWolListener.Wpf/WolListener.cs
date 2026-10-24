using System;
using System.Net;
using System.Net.Sockets;
using System.Threading;
using System.Threading.Tasks;

namespace KodiWolListener;

internal static class WolListener
{

























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

            try
            {
                while (!cancellationToken.IsCancellationRequested)
                {
                    // Create a task that completes when a packet is received
                    var receiveTask = udpClient.ReceiveAsync();
                    
                    // Wait for either the packet or the cancellation token
                    var completedTask = await Task.WhenAny(receiveTask, Task.Delay(-1, cancellationToken));

                    if (completedTask == receiveTask)
                    {
                        UdpReceiveResult result = await receiveTask;
                        if (IsMagicPacket(result.Buffer))
                            await onMagicPacket();
                    }
                    else
                    {
                        // Cancellation requested
                        break;
                    }
                }
            }
            catch (Exception ex) when (!(ex is OperationCanceledException))
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
