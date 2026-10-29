// Win32-GUI: Lauscht auf UDP-Port 9 und startet Kodi nach einem Magic Packet neu.
#define WIN32_LEAN_AND_MEAN
#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#include <winsock2.h>
#include <windows.h>
#include <commctrl.h>

#include <atomic>
#include <cstring>
#include <cwchar>
#include <deque>
#include <iterator>
#include <mutex>
#include <string>
#include <system_error>
#include <thread>

#ifdef _MSC_VER
#pragma comment(lib, "ws2_32.lib")
#pragma comment(lib, "comctl32.lib")
#endif

namespace {

// Steuerelemente-IDs
constexpr int ID_BTN_START = 101;
constexpr int ID_EDIT_PATH = 102;
constexpr int ID_EDIT_LOG = 103;

constexpr UINT WM_APP_LOG = WM_APP + 1;
constexpr UINT WM_APP_LISTENER_STATE = WM_APP + 2;

constexpr int ListenPort = 9;
constexpr wchar_t KodiProcessImage[] = L"kodi.exe";
constexpr size_t MaxLogLines = 500;
constexpr DWORD RestartCooldownMs = 10'000;

HWND g_mainWindow = nullptr;
HWND g_editPath = nullptr;
HWND g_editLog = nullptr;
HWND g_btnStart = nullptr;

std::atomic<bool> g_isRunning{ false };
std::atomic<SOCKET> g_serverSocket{ INVALID_SOCKET };
std::atomic<unsigned> g_listenerGeneration{ 0 };
std::thread g_listenerThread;

// Der Listener-Thread darf das Textfeld nicht direkt beschreiben (sonst
// Deadlock beim Join im UI-Thread). Stattdessen werden die Zeilen gesammelt
// und per PostMessage im UI-Thread in das Protokoll übernommen.
std::mutex g_logMutex;
std::deque<std::wstring> g_pendingLogLines;
std::deque<std::wstring> g_logLines; // nur im UI-Thread verwendet

void FlushLog();

void QueueLog(std::wstring message)
{
    SYSTEMTIME time{};
    GetLocalTime(&time);

    wchar_t prefix[32];
    std::swprintf(prefix, std::size(prefix), L"%02u:%02u:%02u  ",
                  static_cast<unsigned>(time.wHour),
                  static_cast<unsigned>(time.wMinute),
                  static_cast<unsigned>(time.wSecond));

    {
        std::lock_guard<std::mutex> lock(g_logMutex);
        g_pendingLogLines.push_back(std::wstring(prefix) + message);
        while (g_pendingLogLines.size() > MaxLogLines)
            g_pendingLogLines.pop_front();
    }

    if (g_mainWindow != nullptr)
        PostMessageW(g_mainWindow, WM_APP_LOG, 0, 0);
}

void FlushLog()
{
    std::deque<std::wstring> incoming;
    {
        std::lock_guard<std::mutex> lock(g_logMutex);
        incoming.swap(g_pendingLogLines);
    }

    if (incoming.empty() || g_editLog == nullptr)
        return;

    bool trimmed = false;
    for (const std::wstring& line : incoming)
    {
        g_logLines.push_back(line);
        while (g_logLines.size() > MaxLogLines)
        {
            g_logLines.pop_front();
            trimmed = true;
        }
    }

    std::wstring text;
    if (trimmed)
    {
        for (const std::wstring& line : g_logLines)
        {
            text += line;
            text += L"\r\n";
        }

        SetWindowTextW(g_editLog, text.c_str());
    }
    else
    {
        for (const std::wstring& line : incoming)
        {
            text += line;
            text += L"\r\n";
        }

        int length = GetWindowTextLengthW(g_editLog);
        SendMessageW(g_editLog, EM_SETSEL, static_cast<WPARAM>(length), static_cast<LPARAM>(length));
        SendMessageW(g_editLog, EM_REPLACESEL, FALSE, reinterpret_cast<LPARAM>(text.c_str()));
    }

    int length = GetWindowTextLengthW(g_editLog);
    SendMessageW(g_editLog, EM_SETSEL, static_cast<WPARAM>(length), static_cast<LPARAM>(length));
    SendMessageW(g_editLog, EM_SCROLLCARET, 0, 0);
}

void PostListenerState(bool active, unsigned generation)
{
    if (g_mainWindow != nullptr)
        PostMessageW(g_mainWindow, WM_APP_LISTENER_STATE, active ? 1 : 0, static_cast<LPARAM>(generation));
}

std::wstring GetControlText(HWND control)
{
    int length = GetWindowTextLengthW(control);
    if (length <= 0)
        return {};

    std::wstring text(static_cast<size_t>(length) + 1, L'\0');
    int copied = GetWindowTextW(control, text.data(), length + 1);
    text.resize(static_cast<size_t>(copied > 0 ? copied : 0));

    size_t first = text.find_first_not_of(L" \t\r\n");
    if (first == std::wstring::npos)
        return {};

    size_t last = text.find_last_not_of(L" \t\r\n");
    return text.substr(first, last - first + 1);
}

bool FileExists(const std::wstring& path)
{
    DWORD attributes = GetFileAttributesW(path.c_str());
    return attributes != INVALID_FILE_ATTRIBUTES && (attributes & FILE_ATTRIBUTE_DIRECTORY) == 0;
}

// Beendet Kodi ohne sichtbares Konsolenfenster; system("taskkill ...") würde
// bei einer GUI-Anwendung kurz eine Konsole aufblitzen lassen.
void StopKodiProcesses()
{
    std::wstring commandLine = L"taskkill.exe /f /im ";
    commandLine += KodiProcessImage;

    // CreateProcessW darf den Puffer verändern und benötigt ihn beschreibbar.
    std::wstring mutableCommandLine = commandLine;
    mutableCommandLine.push_back(L'\0');

    STARTUPINFOW startupInfo{};
    startupInfo.cb = sizeof(startupInfo);
    startupInfo.dwFlags = STARTF_USESHOWWINDOW;
    startupInfo.wShowWindow = SW_HIDE;

    PROCESS_INFORMATION processInfo{};
    if (!CreateProcessW(nullptr, mutableCommandLine.data(), nullptr, nullptr, FALSE,
                        CREATE_NO_WINDOW, nullptr, nullptr, &startupInfo, &processInfo))
    {
        QueueLog(L"[-] taskkill konnte nicht gestartet werden (Fehler " +
                 std::to_wstring(GetLastError()) + L").");
        return;
    }

    WaitForSingleObject(processInfo.hProcess, 10'000);
    CloseHandle(processInfo.hThread);
    CloseHandle(processInfo.hProcess);
}

void RestartKodi(const std::wstring& kodiPath)
{
    QueueLog(L"[*] Beende laufende Kodi-Instanzen...");
    StopKodiProcesses();
    Sleep(1000);

    if (!FileExists(kodiPath))
    {
        QueueLog(L"[-] Fehler: Kodi wurde nicht gefunden (" + kodiPath + L").");
        return;
    }

    std::wstring workingDirectory = kodiPath;
    size_t separator = workingDirectory.find_last_of(L"\\/");
    if (separator != std::wstring::npos)
        workingDirectory.resize(separator);
    else
        workingDirectory.clear();

    QueueLog(L"[*] Starte Kodi neu...");

    STARTUPINFOW startupInfo{};
    startupInfo.cb = sizeof(startupInfo);
    PROCESS_INFORMATION processInfo{};
    if (CreateProcessW(kodiPath.c_str(), nullptr, nullptr, nullptr, FALSE, 0, nullptr,
                       workingDirectory.empty() ? nullptr : workingDirectory.c_str(),
                       &startupInfo, &processInfo))
    {
        CloseHandle(processInfo.hThread);
        CloseHandle(processInfo.hProcess);
        QueueLog(L"[+] Kodi erfolgreich gestartet.");
    }
    else
    {
        QueueLog(L"[-] Fehler: Konnte Kodi nicht starten (Fehler " +
                 std::to_wstring(GetLastError()) + L"). Pfad prüfen!");
    }
}

bool IsMagicPacket(const char* data, int length)
{
    // Ein WoL Magic Packet hat exakt 102 Bytes: 6x 0xFF, danach 16x die MAC.
    if (length != 102)
        return false;

    const unsigned char* bytes = reinterpret_cast<const unsigned char*>(data);
    for (int i = 0; i < 6; ++i)
    {
        if (bytes[i] != 0xFF)
            return false;
    }

    for (int repetition = 1; repetition < 16; ++repetition)
    {
        if (std::memcmp(bytes + 6, bytes + 6 + repetition * 6, 6) != 0)
            return false;
    }

    return true;
}

void ListenLoop(std::wstring kodiPath, unsigned generation)
{
    WSADATA wsaData{};
    if (WSAStartup(MAKEWORD(2, 2), &wsaData) != 0)
    {
        QueueLog(L"[-] WSAStartup fehlgeschlagen.");
        g_isRunning = false;
        PostListenerState(false, generation);
        return;
    }

    SOCKET serverSocket = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (serverSocket == INVALID_SOCKET)
    {
        QueueLog(L"[-] Konnte Socket nicht erstellen (Fehler " +
                 std::to_wstring(WSAGetLastError()) + L").");
        WSACleanup();
        g_isRunning = false;
        PostListenerState(false, generation);
        return;
    }

    g_serverSocket = serverSocket;

    sockaddr_in serverAddress{};
    serverAddress.sin_family = AF_INET;
    serverAddress.sin_addr.s_addr = INADDR_ANY;
    serverAddress.sin_port = htons(ListenPort);

    if (bind(serverSocket, reinterpret_cast<sockaddr*>(&serverAddress), sizeof(serverAddress)) == SOCKET_ERROR)
    {
        QueueLog(L"[-] Port " + std::to_wstring(ListenPort) + L" ist belegt oder ungültig (Fehler " +
                 std::to_wstring(WSAGetLastError()) + L").");
        if (g_serverSocket.exchange(INVALID_SOCKET) == serverSocket)
            closesocket(serverSocket);
        WSACleanup();
        g_isRunning = false;
        PostListenerState(false, generation);
        return;
    }

    // Wurde während des Aufbaus bereits "Stopp" geklickt?
    if (!g_isRunning)
    {
        if (g_serverSocket.exchange(INVALID_SOCKET) == serverSocket)
            closesocket(serverSocket);
        WSACleanup();
        PostListenerState(false, generation);
        return;
    }

    QueueLog(L"[+] Listener aktiv auf UDP-Port " + std::to_wstring(ListenPort) + L".");
    PostListenerState(true, generation);

    char buffer[1500];
    ULONGLONG lastRestart = 0;

    while (g_isRunning)
    {
        sockaddr_in clientAddress{};
        int clientAddressSize = sizeof(clientAddress);
        int received = recvfrom(serverSocket, buffer, sizeof(buffer), 0,
                                reinterpret_cast<sockaddr*>(&clientAddress), &clientAddressSize);

        if (received == SOCKET_ERROR)
        {
            // closesocket() aus dem UI-Thread beendet den blockierenden Aufruf.
            if (!g_isRunning)
                break;

            int error = WSAGetLastError();
            if (error == WSAENOTSOCK || error == WSAEINTR)
                break;

            // Zu große Pakete und ICMP-Rückmeldungen sind für den Listener
            // unkritisch und dürfen ihn nicht beenden.
            if (error == WSAEMSGSIZE || error == WSAECONNRESET)
                continue;

            QueueLog(L"[-] Empfangsfehler (Fehler " + std::to_wstring(error) + L").");
            break;
        }

        if (!IsMagicPacket(buffer, received))
            continue;

        if (lastRestart != 0 && GetTickCount64() - lastRestart < RestartCooldownMs)
        {
            QueueLog(L"[!] Weiteres Magic Packet ignoriert (Neustart gerade ausgelöst).");
            continue;
        }

        QueueLog(L"[!] Magic Packet empfangen! Starte Kodi neu...");
        RestartKodi(kodiPath);
        lastRestart = GetTickCount64();
    }

    if (g_serverSocket.exchange(INVALID_SOCKET) == serverSocket)
        closesocket(serverSocket);
    WSACleanup();
    g_isRunning = false;
    QueueLog(L"[-] Listener gestoppt.");
    PostListenerState(false, generation);
}

void ResetListenerControls(bool active)
{
    SetWindowTextW(g_btnStart, active ? L"Listener stoppen" : L"Listener starten");
    EnableWindow(g_btnStart, TRUE);
    EnableWindow(g_editPath, !active);
}

void StartListener()
{
    if (g_listenerThread.joinable())
        g_listenerThread.join();

    std::wstring kodiPath = GetControlText(g_editPath);
    if (kodiPath.empty())
    {
        QueueLog(L"[-] Bitte einen Kodi-Pfad angeben.");
        return;
    }

    const unsigned generation = ++g_listenerGeneration;
    g_isRunning = true;
    SetWindowTextW(g_btnStart, L"Listener stoppen");
    EnableWindow(g_btnStart, FALSE);
    EnableWindow(g_editPath, FALSE);

    try
    {
        g_listenerThread = std::thread(ListenLoop, kodiPath, generation);
    }
    catch (const std::system_error&)
    {
        g_isRunning = false;
        QueueLog(L"[-] Listener-Thread konnte nicht gestartet werden.");
        ResetListenerControls(false);
    }
}

void StopListener()
{
    g_isRunning = false;
    EnableWindow(g_btnStart, FALSE);

    SOCKET serverSocket = g_serverSocket.exchange(INVALID_SOCKET);
    if (serverSocket != INVALID_SOCKET)
        closesocket(serverSocket); // Beendet den blockierenden recvfrom-Aufruf

    if (g_listenerThread.joinable())
        g_listenerThread.join();

    ResetListenerControls(false);
}

// Fensterprozedur für die GUI
LRESULT CALLBACK WindowProc(HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam)
{
    switch (message)
    {
    case WM_CREATE:
    {
        g_mainWindow = hwnd;

        CreateWindowExW(0, L"STATIC", L"Kodi Pfad:", WS_VISIBLE | WS_CHILD,
                        20, 20, 100, 20, hwnd, nullptr, nullptr, nullptr);

        g_editPath = CreateWindowExW(WS_EX_CLIENTEDGE, L"EDIT", L"C:\\Program Files\\Kodi\\kodi.exe",
                                     WS_VISIBLE | WS_CHILD | ES_AUTOHSCROLL,
                                     120, 18, 330, 24, hwnd,
                                     reinterpret_cast<HMENU>(static_cast<INT_PTR>(ID_EDIT_PATH)),
                                     nullptr, nullptr);

        g_btnStart = CreateWindowExW(0, L"BUTTON", L"Listener starten",
                                     WS_VISIBLE | WS_CHILD | BS_DEFPUSHBUTTON,
                                     120, 55, 120, 30, hwnd,
                                     reinterpret_cast<HMENU>(static_cast<INT_PTR>(ID_BTN_START)),
                                     nullptr, nullptr);

        g_editLog = CreateWindowExW(WS_EX_CLIENTEDGE, L"EDIT", L"",
                                    WS_VISIBLE | WS_CHILD | ES_MULTILINE | ES_AUTOVSCROLL |
                                        ES_READONLY | WS_VSCROLL,
                                    20, 100, 430, 230, hwnd,
                                    reinterpret_cast<HMENU>(static_cast<INT_PTR>(ID_EDIT_LOG)),
                                    nullptr, nullptr);

        HFONT font = static_cast<HFONT>(GetStockObject(DEFAULT_GUI_FONT));
        SendMessageW(g_editPath, WM_SETFONT, reinterpret_cast<WPARAM>(font), TRUE);
        SendMessageW(g_btnStart, WM_SETFONT, reinterpret_cast<WPARAM>(font), TRUE);
        SendMessageW(g_editLog, WM_SETFONT, reinterpret_cast<WPARAM>(font), TRUE);

        QueueLog(L"Bereit. Warte auf den Start des Listeners.");
        break;
    }
    case WM_APP_LOG:
        FlushLog();
        return 0;
    case WM_APP_LISTENER_STATE:
    {
        // Zustandsmeldungen eines bereits ersetzten Listeners ignorieren.
        if (static_cast<unsigned>(lParam) == g_listenerGeneration)
            ResetListenerControls(wParam != 0);
        return 0;
    }
    case WM_COMMAND:
        if (LOWORD(wParam) == ID_BTN_START && HIWORD(wParam) == BN_CLICKED)
        {
            if (g_isRunning)
                StopListener();
            else
                StartListener();
            return 0;
        }
        break;
    case WM_DESTROY:
        g_isRunning = false;
        {
            SOCKET serverSocket = g_serverSocket.exchange(INVALID_SOCKET);
            if (serverSocket != INVALID_SOCKET)
                closesocket(serverSocket);
        }
        if (g_listenerThread.joinable())
            g_listenerThread.join();

        // Letzte Meldungen des Listener-Threads noch anzeigen.
        FlushLog();
        g_mainWindow = nullptr;
        PostQuitMessage(0);
        return 0;
    }

    return DefWindowProcW(hwnd, message, wParam, lParam);
}

} // namespace

// Einstiegspunkt der Windows-Anwendung
int WINAPI WinMain(HINSTANCE hInstance, HINSTANCE, LPSTR, int nCmdShow)
{
    SetProcessDPIAware();

    INITCOMMONCONTROLSEX commonControls{ sizeof(INITCOMMONCONTROLSEX), ICC_STANDARD_CLASSES };
    InitCommonControlsEx(&commonControls);

    constexpr wchar_t className[] = L"KodiWolListenerClass";
    WNDCLASSEXW windowClass{};
    windowClass.cbSize = sizeof(windowClass);
    windowClass.style = CS_HREDRAW | CS_VREDRAW;
    windowClass.lpfnWndProc = WindowProc;
    windowClass.hInstance = hInstance;
    windowClass.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    windowClass.hbrBackground = reinterpret_cast<HBRUSH>(static_cast<INT_PTR>(COLOR_BTNFACE + 1));
    windowClass.lpszClassName = className;

    if (RegisterClassExW(&windowClass) == 0)
    {
        MessageBoxW(nullptr, L"Das Fenster konnte nicht registriert werden.",
                    L"Kodi WoL Listener", MB_ICONERROR);
        return 1;
    }

    HWND hwnd = CreateWindowExW(0, className, L"Kodi WoL Restart Listener",
                                WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX,
                                CW_USEDEFAULT, CW_USEDEFAULT, 485, 385,
                                nullptr, nullptr, hInstance, nullptr);

    if (hwnd == nullptr)
    {
        MessageBoxW(nullptr, L"Das Fenster konnte nicht erstellt werden.",
                    L"Kodi WoL Listener", MB_ICONERROR);
        return 1;
    }

    ShowWindow(hwnd, nCmdShow);
    UpdateWindow(hwnd);

    MSG message{};
    while (GetMessageW(&message, nullptr, 0, 0) > 0)
    {
        TranslateMessage(&message);
        DispatchMessageW(&message);
    }

    return static_cast<int>(message.wParam);
}
