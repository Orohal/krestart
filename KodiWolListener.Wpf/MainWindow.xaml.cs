using Microsoft.Win32;
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Forms = System.Windows.Forms;

namespace KodiWolListener;

public partial class MainWindow : Window
{
    private const string DefaultKodiPath = @"C:\Program Files\Kodi\kodi.exe";
    private readonly SettingsStore _settingsStore = new();
    private readonly Queue<string> _logLines = new();
    private readonly Forms.NotifyIcon _trayIcon;
    private readonly Forms.ContextMenuStrip _trayMenu;
    private AppSettings _settings = new();
    private CancellationTokenSource? _listenerCancellation;
    private Task? _listenerTask;
    private bool _initializing = true;
    private bool _allowClose;
    private bool _isClosing;

    public MainWindow()
    {
        InitializeComponent();

        _trayIcon = new Forms.NotifyIcon
        {
            Icon = System.Drawing.SystemIcons.Application,
            Text = "Kodi WoL Listener",
            Visible = true
        };
        _trayMenu = new Forms.ContextMenuStrip();
        _trayMenu.Items.Add("Öffnen", null, (_, _) => ShowFromTray());
        _trayMenu.Items.Add("Beenden", null, async (_, _) => await RequestExitAsync());
        _trayIcon.ContextMenuStrip = _trayMenu;
        _trayIcon.DoubleClick += (_, _) => ShowFromTray();

        string? loadWarning;
        _settings = _settingsStore.Load(out loadWarning);
        KodiPathTextBox.Text = string.IsNullOrWhiteSpace(_settings.KodiPath)
            ? DefaultKodiPath
            : _settings.KodiPath;
        PortComboBox.SelectedItem = PortComboBox.Items
            .Cast<ComboBoxItem>()
            .FirstOrDefault(item => string.Equals(item.Content?.ToString(), _settings.Port.ToString(), StringComparison.Ordinal))
            ?? PortComboBox.Items[0];
        StartupCheckBox.IsChecked = _settings.StartAtWindowsStartup;
        _initializing = false;

        if (loadWarning is not null)
            WriteLog(loadWarning);

        try
        {
            StartupRegistration.SetEnabled(_settings.StartAtWindowsStartup);
        }
        catch (Exception ex)
        {
            WriteLog($"Autostart konnte nicht aktualisiert werden: {ex.Message}");
        }

        WriteLog("Bereit. Warte auf den Start des Listeners.");
    }

    private void Window_Loaded(object sender, RoutedEventArgs e)
    {
        var args = Environment.GetCommandLineArgs();
        if (args.Any(argument => string.Equals(argument, StartupRegistration.MinimizedArgument, StringComparison.OrdinalIgnoreCase)))
        {
            HideToTray();
        }

        // Automatisch starten
        StartListener();
    }

    private void Window_StateChanged(object? sender, EventArgs e)
    {
        if (WindowState == WindowState.Minimized)
            HideToTray();
    }

    private void Window_Closing(object? sender, CancelEventArgs e)
    {
        if (_allowClose)
        {
            _trayIcon.Visible = false;
            _trayIcon.Dispose();
            _trayMenu.Dispose();
            return;
        }

        e.Cancel = true;

        // Close() darf nicht ausgeführt werden, solange das Closing-Ereignis
        // noch läuft (sonst InvalidOperationException). Deshalb den Shutdown
        // erst nach Abschluss dieses Ereignisses einplanen.
        Dispatcher.BeginInvoke(new Action(() => _ = RequestExitAsync()));
    }

    private async void ListenerButton_Click(object sender, RoutedEventArgs e)
    {
        if (_listenerCancellation is null)
            StartListener();
        else
            await StopListenerAsync();
    }

    private void StartListener()
    {
        string kodiPath = KodiPathTextBox.Text.Trim();
        if (!File.Exists(kodiPath))
        {
            WriteLog("Kodi-Datei nicht gefunden. Bitte einen gültigen Installationspfad auswählen.");
            return;
        }

        if (PortComboBox.SelectedItem is not ComboBoxItem selectedPort ||
            !int.TryParse(selectedPort.Content?.ToString(), out int port) ||
            port is not (7 or 9))
        {
            WriteLog("Ungültiger UDP-Port. Erlaubt sind 7 oder 9.");
            return;
        }

        SaveSettings();
        var controller = new KodiController(kodiPath, WriteLog);
        var cancellation = new CancellationTokenSource();
        _listenerCancellation = cancellation;
        ListenerButton.Content = "Listener stoppen";
        ListenerButton.IsEnabled = false;
        KodiPathTextBox.IsEnabled = false;
        BrowseButton.IsEnabled = false;
        PortComboBox.IsEnabled = false;
        StatusText.Text = "Wird gestartet";
        StatusIndicator.Fill = Brushes.DarkOrange;
        WriteLog($"Starte Listener auf UDP-Port {port}…");

        Task listenerTask = ListenAsync(port, controller, cancellation);
        if (!listenerTask.IsCompleted)
            _listenerTask = listenerTask;
    }

    private async Task ListenAsync(int port, KodiController controller, CancellationTokenSource cancellation)
    {
        try
        {
            await WolListener.ListenAsync(
                port,
                cancellation.Token,
                controller.RestartAsync,
                WriteLog,
                SetListenerActive);
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested)
        {
        }
        catch (Exception ex)
        {
            WriteLog($"Listenerfehler: {ex.Message}");
        }
        finally
        {
            if (ReferenceEquals(_listenerCancellation, cancellation))
            {
                _listenerCancellation = null;
                _listenerTask = null;
                cancellation.Dispose();
                SetListenerActive(false);
            }
        }
    }

    private async Task StopListenerAsync()
    {
        CancellationTokenSource? cancellation = _listenerCancellation;
        Task? listenerTask = _listenerTask;
        if (cancellation is null)
            return;

        ListenerButton.IsEnabled = false;
        StatusText.Text = "Wird gestoppt";
        try
        {
            cancellation.Cancel();
            if (listenerTask is not null)
                await listenerTask;
        }
        catch (Exception ex)
        {
            WriteLog($"Listener konnte nicht sauber gestoppt werden: {ex.Message}");
        }
        finally
        {
            if (ReferenceEquals(_listenerCancellation, cancellation))
            {
                _listenerCancellation = null;
                _listenerTask = null;
                cancellation.Dispose();
                SetListenerActive(false);
            }
        }
    }

    private void SetListenerActive(bool active)
    {
        if (!Dispatcher.CheckAccess())
        {
            Dispatcher.BeginInvoke(new Action(() => SetListenerActive(active)));
            return;
        }

        StatusText.Text = active ? "Aktiv" : "Inaktiv";
        StatusIndicator.Fill = active ? Brushes.ForestGreen : Brushes.Gray;
        ListenerButton.Content = active ? "Listener stoppen" : "Listener starten";
        ListenerButton.IsEnabled = true;
        KodiPathTextBox.IsEnabled = !active;
        BrowseButton.IsEnabled = !active;
        PortComboBox.IsEnabled = !active;
    }

    private void BrowseButton_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFileDialog
        {
            Title = "Kodi-Programmdatei auswählen",
            Filter = "Kodi (kodi.exe)|kodi.exe|Programme (*.exe)|*.exe",
            CheckFileExists = true,
            FileName = File.Exists(KodiPathTextBox.Text) ? KodiPathTextBox.Text : DefaultKodiPath
        };

        if (dialog.ShowDialog(this) == true)
        {
            KodiPathTextBox.Text = dialog.FileName;
            SaveSettings();
        }
    }

    private void KodiPathTextBox_LostFocus(object sender, RoutedEventArgs e)
    {
        if (!_initializing)
            SaveSettings();
    }

    private void PortComboBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_initializing && IsInitialized)
            SaveSettings();
    }

    private void StartupCheckBox_Changed(object sender, RoutedEventArgs e)
    {
        if (_initializing || !IsInitialized)
            return;

        bool enabled = StartupCheckBox.IsChecked == true;
        try
        {
            StartupRegistration.SetEnabled(enabled);
            _settings.StartAtWindowsStartup = enabled;
            SaveSettings();
            WriteLog(enabled
                ? "Autostart aktiviert: Die Anwendung wird beim Windows-Start im Tray geöffnet."
                : "Autostart deaktiviert.");
        }
        catch (Exception ex)
        {
            StartupCheckBox.IsChecked = _settings.StartAtWindowsStartup;
            WriteLog($"Autostart-Einstellung konnte nicht gespeichert werden: {ex.Message}");
        }
    }

    private void SaveSettings()
    {
        if (_initializing)
            return;

        _settings.KodiPath = KodiPathTextBox.Text.Trim();
        if (PortComboBox.SelectedItem is ComboBoxItem item &&
            int.TryParse(item.Content?.ToString(), out int port))
        {
            _settings.Port = port;
        }

        _settings.StartAtWindowsStartup = StartupCheckBox.IsChecked == true;
        try
        {
            _settingsStore.Save(_settings);
        }
        catch (Exception ex)
        {
            WriteLog($"Einstellungen konnten nicht gespeichert werden: {ex.Message}");
        }
    }

    private const int MaxLogLines = 500;

    private void WriteLog(string message)
    {
        // Sicherstellen, dass wir immer im UI-Thread sind
        if (!Dispatcher.CheckAccess())
        {
            Dispatcher.BeginInvoke(new Action(() => WriteLog(message)));
            return;
        }

        string line = $"{DateTime.Now:HH:mm:ss}  {message}";
        _logLines.Enqueue(line);

        bool trimmed = false;
        while (_logLines.Count > MaxLogLines)
        {
            _logLines.Dequeue();
            trimmed = true;
        }

        // A full rebuild is only needed when the oldest line was dropped;
        // otherwise appending is enough and keeps the update cheap.
        if (trimmed)
        {
            LogTextBox.Text = string.Join(Environment.NewLine, _logLines);
        }
        else
        {
            if (LogTextBox.Text.Length > 0)
                LogTextBox.AppendText(Environment.NewLine);
            LogTextBox.AppendText(line);
        }

        LogTextBox.ScrollToEnd();
    }

    private void HideToTray()
    {
        Hide();
        ShowInTaskbar = false;
    }

    private void ShowFromTray()
    {
        ShowInTaskbar = true;
        Show();
        WindowState = WindowState.Normal;
        Activate();
    }

    private async Task RequestExitAsync()
    {
        if (_isClosing)
            return;

        _isClosing = true;
        try
        {
            await StopListenerAsync();
        }
        catch (Exception ex)
        {
            WriteLog($"Fehler beim Beenden: {ex.Message}");
        }
        finally
        {
            _allowClose = true;
            Close();
        }
    }
}
