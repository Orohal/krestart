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
        using var udpClient = new UdpClient(new IPEndPoint(IPAddress.Any, port));
        setActive(true);
        log($"Listener aktiv auf UDP-Port {port}. Warte auf WoL-Signal…");

        try
        {
            while (!cancellationToken.IsCancellationRequested)
            {
                UdpReceiveResult result = await udpClient.ReceiveAsync(cancellationToken);
                if (IsMagicPacket(result.Buffer))
                    await onMagicPacket();
            }
        }
        finally
        {
            setActive(false);
            log("Listener gestoppt.");
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
