cmake_minimum_required(VERSION 3.15)
project(KodiWolListener VERSION 1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Nur für Windows geeignet
if(NOT WIN32)
    message(FATAL_ERROR "Dieses Programm ist nur für Windows 10/11 konzipiert.")
endif()

# WIN32 sorgt dafür, dass kein Konsolenfenster im Hintergrund aufpoppt
add_executable(KodiWolListener WIN32 main.cpp)

find_package(Threads REQUIRED)

if(MSVC)
    # Quelltext ist UTF-8; ohne /utf-8 würden Umlaute in L"..."-Literalen
    # abhängig von der Systemcodepage falsch interpretiert.
    target_compile_options(KodiWolListener PRIVATE /utf-8)
endif()

# Benötigte Windows-Bibliotheken linken:
# ws2_32 für Netzwerk/UDP (Winsock2), comctl32 für moderne GUI-Steuerelemente
target_link_libraries(KodiWolListener PRIVATE ws2_32 comctl32 Threads::Threads)