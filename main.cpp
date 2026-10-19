#winsock2, windows headers
#define _WINSOCK_DEPRECATED_NO_WARNINGS
#include <winsock2.h>
#include <windows.h>
#include <commctrl.h>
#include <thread>
#include <atomic>
#include <string>

#pragma comment(lib, "ws2_32.lib")
#pragma comment(lib, "comctl32.lib")

// Steuerelemente-IDs
#define ID_BTN_START 101
#define ID_EDIT_PATH 102
#define ID_EDIT_LOG  103

HWND hEditPath, hEditLog, hBtnStart;
std::atomic<bool> isRunning(false);
std::thread listenerThread;
SOCKET serverSocket = INVALID_SOCKET;

// Log-Nachricht in das GUI-Textfeld schreiben
void AppendLog(const std::string& message) {
    int len = GetWindowTextLength(hEditLog);
    SendMessage(hEditLog, EM_SETSEL, len, len);
    SendMessage(hEditLog, EM_REPLACESEL, 0, (LPARAM)(message + "\r\n").c_str());
}

// Kodi neustarten
void RestartKodi(std::wstring kodiPath) {
    AppendLog("[*] Beende laufende Kodi-Instanzen...");
    
    // Kodi beenden via taskkill
    system("taskkill /f /im kodi.exe >nul 2>&1");
    Sleep(1000); // Kurze Pause

    AppendLog("[*] Starte Kodi neu...");
    
    STARTUPINFO si = { sizeof(STARTUPINFO) };
    PROCESS_INFORMATION pi;

    if (CreateProcessW(kodiPath.c_str(), NULL, NULL, NULL, FALSE, 0, NULL, NULL, &si, &pi)) {
        AppendLog("[+] Kodi erfolgreich gestartet.");
        CloseHandle(pi.hProcess);
        CloseHandle(pi.hThread);
    } else {
        AppendLog("[-] Fehler: Konnte Kodi nicht starten (Pfad prüfen!).");
    }
}

// UDP Listener Thread (lauscht auf Port 9 für WoL)
void ListenLoop(int port, std::wstring kodiPath) {
    WSADATA wsaData;
    if (WSAStartup(MAKEWORD(2, 2), &wsaData) != 0) {
        AppendLog("[-] WSAStartup fehlgeschlagen.");
        return;
    }

    serverSocket = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (serverSocket == INVALID_SOCKET) {
        AppendLog("[-] Konnte Socket nicht erstellen.");
        WSACleanup();
        return;
    }

    sockaddr_in serverAddr{};
    serverAddr.sin_family = AF_INET;
    serverAddr.sin_addr.s_addr = INADDR_ANY;
    serverAddr.sin_port = htons(port);

    if (bind(serverSocket, (SOCKADDR*)&serverAddr, sizeof(serverAddr)) == SOCKET_ERROR) {
        AppendLog("[-] Port belegt oder ungültig.");
        closesocket(serverSocket);
        WSACleanup();
        return;
    }

    AppendLog("[+] Listener aktiv auf UDP Port " + std::to_string(port));

    char buffer[1024];
    while (isRunning) {
        sockaddr_in clientAddr;
        int clientAddrSize = sizeof(clientAddr);
        int bytesReceived = recvfrom(serverSocket, buffer, sizeof(buffer), 0, (SOCKADDR*)&clientAddr, &clientAddrSize);

        if (bytesReceived == 102) { // Ein WoL Magic Packet hat exakt 102 Bytes
            bool isMagic = true;
            for (int i = 0; i < 6; i++) {
                if ((unsigned char)buffer[i] != 0xFF) {
                    isMagic = false;
                    break;
                }
            }

            if (isMagic) {
                AppendLog("[!] Magic Packet empfangen! Triggers Kodi Neustart...");
                RestartKodi(kodiPath);
            }
        }
    }

    closesocket(serverSocket);
    WSACleanup();
    AppendLog("[-] Listener gestoppt.");
}

// Fensterprozedur für die GUI
LRESULT CALLBACK WindowProc(HWND hwnd, UINT uMsg, WPARAM wParam, LPARAM lParam) {
    switch (uMsg) {
    case WM_CREATE: {
        // Controls erstellen
        CreateWindowW(L"STATIC", L"Kodi Pfad:", WS_VISIBLE | WS_CHILD, 20, 20, 100, 20, hwnd, NULL, NULL, NULL);
        hEditPath = CreateWindowW(L"EDIT", L"C:\\Program Files\\Kodi\\kodi.exe", WS_VISIBLE | WS_CHILD | WS_BORDER | ES_AUTOHSCROLL, 120, 18, 330, 24, hwnd, (HMENU)ID_EDIT_PATH, NULL, NULL);

        hBtnStart = CreateWindowW(L"BUTTON", L"Start Listener", WS_VISIBLE | WS_CHILD | BS_DEFPUSHBUTTON, 120, 55, 120, 30, hwnd, (HMENU)ID_BTN_START, NULL, NULL);

        hEditLog = CreateWindowW(L"EDIT", L"Bereit...\r\n", WS_VISIBLE | WS_CHILD | WS_BORDER | ES_MULTILINE | ES_AUTOVSCROLL | WS_VSCROLL, 20, 100, 430, 230, hwnd, (HMENU)ID_EDIT_LOG, NULL, NULL);
        break;
    }
    case WM_COMMAND:
        if (LOWORD(wParam) == ID_BTN_START) {
            if (!isRunning) {
                wchar_t pathBuf[MAX_PATH];
                GetWindowTextW(hEditPath, pathBuf, MAX_PATH);

                isRunning = true;
                SetWindowTextW(hBtnStart, L"Stopp Listener");
                listenerThread = std::thread(ListenLoop, 9, std::wstring(pathBuf));
            } else {
                isRunning = false;
                if (serverSocket != INVALID_SOCKET) {
                    closesocket(serverSocket); // Zwingt den recvfrom-Block zum Beenden
                }
                if (listenerThread.joinable()) {
                    listenerThread.join();
                }
                SetWindowTextW(hBtnStart, L"Start Listener");
            }
        }
        break;
    case WM_DESTROY:
        isRunning = false;
        if (serverSocket != INVALID_SOCKET) closesocket(serverSocket);
        if (listenerThread.joinable()) listenerThread.join();
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProc(hwnd, uMsg, wParam, lParam);
}

// Einstiegspunkt der Windows-Anwendung
int WINAPI WinMain(HINSTANCE hInstance, HINSTANCE hPrevInstance, LPSTR lpCmdLine, int nCmdShow) {
    INITCOMMONCONTROLSEX icx = { sizeof(INITCOMMONCONTROLSEX), ICC_STANDARD_CLASSES };
    InitCommonControlsEx(&icx);

    const wchar_class_name = L"KodiWolListenerClass";
    WNDCLASSW wc = {};
    wc.lpfnWndProc = WindowProc;
    wc.hInstance = hInstance;
    wc.lpszClassName = class_name;
    wc.hCursor = LoadCursor(NULL, IDC_ARROW);
    wc.hbrBackground = (HBRUSH)(COLOR_BTNFACE + 1);

    RegisterClassW(&wc);

    HWND hwnd = CreateWindowExW(0, class_name, L"Kodi WoL Restart Listener", WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX,
        CW_USEDEFAULT, CW_USEDEFAULT, 485, 385, NULL, NULL, hInstance, NULL);

    if (!hwnd) return 0;

    ShowWindow(hwnd, nCmdShow);
    UpdateWindow(hwnd);

    MSG msg = {};
    while (GetMessage(&msg, NULL, 0, 0)) {
        TranslateMessage(&msg);
        DispatchMessage(&msg);
    }

    return 0;
}