/* Madeira session agent (ml791).
 *
 * A native AArch64 Windows program that lives inside the virtual desktop
 * session and starts games on the app's behalf. explorer's /desktop switch
 * runs exactly one command (it used to be services.exe); that command is now
 *
 *     madeira-agent.exe C:\windows\system32\services.exe
 *
 * The agent starts whatever it was given (services.exe: the SCM the desktop
 * needs), then polls C:\madeira\launch.txt. The app (SessionLauncher.swift)
 * writes that file to launch a game from the Games tab:
 *
 *     id=<token>
 *     exe=C:\Games\Hollow Knight\hollow_knight.exe
 *     dir=C:\Games\Hollow Knight
 *     args=<optional>
 *
 * The agent deletes the request, CreateProcess()es the game with its folder
 * as working directory, and answers in C:\madeira\launch.result:
 *
 *     id=<token>
 *     ok pid=<pid>          or          err code=<GetLastError>
 *
 * Why a helper instead of the app calling into Wine: every Wine "process" is
 * a thread here, and NtCreateUserProcess needs a caller with a TEB, server
 * connection and process parameters — only Windows code inside the session
 * has those. A polling helper is dumb, but it is the same CreateProcess path
 * File Explorer's double-click uses, and it needs nothing from Wine that a
 * regular program does not. Native AArch64 so it costs no FEX translation.
 *
 * C:\madeira\agent.ready is (re)created once services.exe has been started,
 * so the app can tell the session is able to take requests. No window, no
 * console (GUI subsystem), sleeps 200 ms between polls. */

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <wchar.h>

#define AGENT_DIR    L"C:\\madeira"
#define REQUEST_PATH L"C:\\madeira\\launch.txt"
#define RESULT_PATH  L"C:\\madeira\\launch.result"
#define READY_PATH   L"C:\\madeira\\agent.ready"
#define LOG_PATH     L"C:\\madeira\\agent.log"
#define EXIT_PATH    L"C:\\madeira\\exit.txt"

/* ml797: programs we started, so their exit can be reported (the app's
 * Games tab turns "Resume" back into "Play"). */
static HANDLE g_child_handle[32];
static DWORD  g_child_pid[32];
static DWORD  g_child_kill_at[32];   /* ml799: tick when a hard kill is due, 0 = none */
static int    g_child_n;

static void agent_log( const char *fmt, ... );   /* defined below; reap_children logs */

/* ml799: a violent TerminateProcess from outside wedges the desktop on
 * this port (the victim's threads never get the signal and keep their
 * locks), so "force close" first asks every window of the process to
 * close — what Alt+F4 does, which Unity and most games honour — and only
 * terminates after CLOSE_GRACE_MS if the process is still there. */
#define CLOSE_GRACE_MS 8000
static int g_close_posted;

static BOOL CALLBACK close_windows_proc( HWND hwnd, LPARAM lp )
{
    DWORD pid = 0;
    GetWindowThreadProcessId( hwnd, &pid );
    if (pid == (DWORD)lp)
    {
        PostMessageW( hwnd, WM_CLOSE, 0, 0 );
        g_close_posted++;
    }
    return TRUE;
}

static void append_text_file( const WCHAR *path, const char *text )
{
    HANDLE h = CreateFileW( path, FILE_APPEND_DATA, FILE_SHARE_READ, NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL );
    DWORD written;
    if (h == INVALID_HANDLE_VALUE) return;
    WriteFile( h, text, (DWORD)strlen( text ), &written, NULL );
    CloseHandle( h );
}

static void reap_children( void )
{
    int i = 0;
    while (i < g_child_n)
    {
        if (WaitForSingleObject( g_child_handle[i], 0 ) == WAIT_OBJECT_0)
        {
            DWORD code = 0;
            char line[96];
            GetExitCodeProcess( g_child_handle[i], &code );
            CloseHandle( g_child_handle[i] );
            snprintf( line, sizeof(line), "pid=%lu code=%ld\r\n", (unsigned long)g_child_pid[i], (long)(int)code );
            append_text_file( EXIT_PATH, line );
            agent_log( "%s", line );
            g_child_n--;
            g_child_handle[i] = g_child_handle[g_child_n];
            g_child_pid[i] = g_child_pid[g_child_n];
            g_child_kill_at[i] = g_child_kill_at[g_child_n];
            continue;
        }
        if (g_child_kill_at[i] && (LONG)(GetTickCount() - g_child_kill_at[i]) >= 0)
        {
            agent_log( "pid=%lu ignored WM_CLOSE for %d ms -> TerminateProcess", (unsigned long)g_child_pid[i], CLOSE_GRACE_MS );
            TerminateProcess( g_child_handle[i], 1 );
            g_child_kill_at[i] = 0;
        }
        i++;
    }
}

static void agent_log( const char *fmt, ... )
{
    char line[1024];
    va_list ap;
    DWORD written, len;
    HANDLE h;
    SYSTEMTIME st;

    GetLocalTime( &st );
    len = (DWORD)snprintf( line, sizeof(line), "[%02u:%02u:%02u] ", st.wHour, st.wMinute, st.wSecond );
    va_start( ap, fmt );
    len += (DWORD)vsnprintf( line + len, sizeof(line) - len - 2, fmt, ap );
    va_end( ap );
    line[len++] = '\n';
    line[len] = 0;
    /* Also to stderr: the app maps a child's stderr onto madeira-log.txt. */
    h = GetStdHandle( STD_ERROR_HANDLE );
    if (h && h != INVALID_HANDLE_VALUE) WriteFile( h, line, len, &written, NULL );
    h = CreateFileW( LOG_PATH, FILE_APPEND_DATA, FILE_SHARE_READ, NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL );
    if (h != INVALID_HANDLE_VALUE)
    {
        WriteFile( h, line, len, &written, NULL );
        CloseHandle( h );
    }
}

static void write_text_file( const WCHAR *path, const char *text )
{
    HANDLE h = CreateFileW( path, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL );
    DWORD written;
    if (h == INVALID_HANDLE_VALUE) return;
    WriteFile( h, text, (DWORD)strlen( text ), &written, NULL );
    CloseHandle( h );
}

/* Read a whole small UTF-8 file (the request is a few hundred bytes). */
static char *read_text_file( const WCHAR *path )
{
    HANDLE h = CreateFileW( path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                            NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL );
    DWORD size, got;
    char *buf;
    if (h == INVALID_HANDLE_VALUE) return NULL;
    size = GetFileSize( h, NULL );
    if (size == INVALID_FILE_SIZE || size > 65536) { CloseHandle( h ); return NULL; }
    buf = HeapAlloc( GetProcessHeap(), 0, size + 1 );
    if (!buf) { CloseHandle( h ); return NULL; }
    if (!ReadFile( h, buf, size, &got, NULL )) got = 0;
    buf[got] = 0;
    CloseHandle( h );
    return buf;
}

/* "key=value" line lookup; value is copied without the trailing CR/LF. */
static int get_field( const char *text, const char *key, char *out, size_t out_size )
{
    size_t klen = strlen( key );
    const char *p = text;
    out[0] = 0;
    while (p && *p)
    {
        const char *eol = strpbrk( p, "\r\n" );
        size_t len = eol ? (size_t)(eol - p) : strlen( p );
        if (len > klen + 1 && !strncmp( p, key, klen ) && p[klen] == '=')
        {
            size_t vlen = len - klen - 1;
            if (vlen >= out_size) vlen = out_size - 1;
            memcpy( out, p + klen + 1, vlen );
            out[vlen] = 0;
            return 1;
        }
        if (!eol) break;
        p = eol;
        while (*p == '\r' || *p == '\n') p++;
    }
    return 0;
}

static WCHAR *utf8_to_wide( const char *s )
{
    int n = MultiByteToWideChar( CP_UTF8, 0, s, -1, NULL, 0 );
    WCHAR *w = HeapAlloc( GetProcessHeap(), 0, n * sizeof(WCHAR) );
    if (w) MultiByteToWideChar( CP_UTF8, 0, s, -1, w, n );
    return w;
}

static void apply_game_environment( const WCHAR *dir )
{
    WCHAR appid_path[MAX_PATH];
    WCHAR appid[64] = {0};
    HANDLE h;

    if (dir && *dir)
    {
        swprintf( appid_path, MAX_PATH, L"%ls\\steam_appid.txt", dir );
        h = CreateFileW( appid_path, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL );
        if (h != INVALID_HANDLE_VALUE)
        {
            char buf[64] = {0};
            DWORD got = 0;
            if (ReadFile( h, buf, sizeof(buf) - 1, &got, NULL ) && got > 0)
            {
                char *p = strpbrk( buf, "\r\n " );
                if (p) *p = 0;
                MultiByteToWideChar( CP_UTF8, 0, buf, -1, appid, 64 );
            }
            CloseHandle( h );
        }
    }

    if (!appid[0])
    {
        wcscpy( appid, L"480" ); /* Fallback standard Steam AppID */
    }

    SetEnvironmentVariableW( L"SteamAppId", appid );
    SetEnvironmentVariableW( L"SteamGameId", appid );
    if (dir && *dir) SetEnvironmentVariableW( L"SteamAppPath", dir );
    SetEnvironmentVariableW( L"SteamClientLaunch", L"1" );
    SetEnvironmentVariableW( L"SteamEnv", L"1" );
    SetEnvironmentVariableW( L"WINE_LARGE_ADDRESS_AWARE", L"1" );
}

/* Start a program; returns the pid or 0 (GetLastError() set). */
static DWORD start_process( const WCHAR *exe, const WCHAR *args, const WCHAR *dir )
{
    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    size_t len = wcslen( exe ) + (args ? wcslen( args ) : 0) + 4;
    WCHAR *cmdline = HeapAlloc( GetProcessHeap(), 0, len * sizeof(WCHAR) );
    DWORD pid = 0;

    if (!cmdline) return 0;

    apply_game_environment( dir );

    /* Quote the exe: game folders have spaces. */
    /* %ls means a wide string under both MSVC and ISO wide-printf rules. */
    swprintf( cmdline, len, L"\"%ls\"%ls%ls", exe, (args && *args) ? L" " : L"", (args && *args) ? args : L"" );
    memset( &si, 0, sizeof(si) );
    si.cb = sizeof(si);
    if (CreateProcessW( exe, cmdline, NULL, NULL, FALSE, 0, NULL, (dir && *dir) ? dir : NULL, &si, &pi ))
    {
        pid = pi.dwProcessId;
        CloseHandle( pi.hThread );
        if (g_child_n < 32)
        {
            g_child_handle[g_child_n] = pi.hProcess;
            g_child_pid[g_child_n] = pi.dwProcessId;
            g_child_kill_at[g_child_n] = 0;
            g_child_n++;
        }
        else CloseHandle( pi.hProcess );
    }
    HeapFree( GetProcessHeap(), 0, cmdline );
    return pid;
}

static void handle_request( void )
{
    char *text = read_text_file( REQUEST_PATH );
    char id[128], exe[1024], dir[1024], args[2048], result[256];
    WCHAR *wexe, *wdir, *wargs;
    DWORD pid, err = 0;

    if (!text) return;
    /* Delete first so a failure cannot be retried forever. */
    DeleteFileW( REQUEST_PATH );
    get_field( text, "id", id, sizeof(id) );
    /* ml798: "kill=<pid>" — force close a program we started. */
    if (get_field( text, "kill", args, sizeof(args) ))
    {
        DWORD kpid = strtoul( args, NULL, 10 );
        BOOL ok = FALSE;
        int i;
        g_close_posted = 0;
        EnumWindows( close_windows_proc, (LPARAM)kpid );
        for (i = 0; i < g_child_n; i++)
            if (g_child_pid[i] == kpid)
            {
                /* Polite close first; the reap loop terminates after the grace. */
                g_child_kill_at[i] = GetTickCount() + CLOSE_GRACE_MS;
                if (!g_child_kill_at[i]) g_child_kill_at[i] = 1;
                ok = TRUE;
                break;
            }
        if (i == g_child_n)
        {
            /* Not ours: close its windows now, terminate if none took it. */
            if (g_close_posted) ok = TRUE;
            else
            {
                HANDLE h = OpenProcess( PROCESS_TERMINATE, FALSE, kpid );
                if (h) { ok = TerminateProcess( h, 1 ); CloseHandle( h ); }
            }
        }
        agent_log( "kill id=%s pid=%lu -> %s (WM_CLOSE to %d window(s), hard kill in %d ms if ignored)",
                   id, (unsigned long)kpid, ok ? "ok" : "err", g_close_posted, CLOSE_GRACE_MS );
        snprintf( result, sizeof(result), ok ? "id=%s\r\nok kill\r\n" : "id=%s\r\nerr code=%lu\r\n", id, (unsigned long)GetLastError() );
        write_text_file( RESULT_PATH, result );
        HeapFree( GetProcessHeap(), 0, text );
        return;
    }
    if (!get_field( text, "exe", exe, sizeof(exe) ))
    {
        agent_log( "request without exe= ignored" );
        snprintf( result, sizeof(result), "id=%s\r\nerr code=87\r\n", id );
        write_text_file( RESULT_PATH, result );
        HeapFree( GetProcessHeap(), 0, text );
        return;
    }
    get_field( text, "dir", dir, sizeof(dir) );
    get_field( text, "args", args, sizeof(args) );
    HeapFree( GetProcessHeap(), 0, text );

    wexe = utf8_to_wide( exe );
    wdir = utf8_to_wide( dir );
    wargs = utf8_to_wide( args );
    agent_log( "launch id=%s exe=%s dir=%s args=%s", id, exe, dir, args );
    pid = start_process( wexe, wargs, wdir );
    if (!pid) err = GetLastError();
    if (pid) snprintf( result, sizeof(result), "id=%s\r\nok pid=%lu\r\n", id, (unsigned long)pid );
    else     snprintf( result, sizeof(result), "id=%s\r\nerr code=%lu\r\n", id, (unsigned long)err );
    agent_log( "%s", result );
    write_text_file( RESULT_PATH, result );
    HeapFree( GetProcessHeap(), 0, wexe );
    HeapFree( GetProcessHeap(), 0, wdir );
    HeapFree( GetProcessHeap(), 0, wargs );
}

int WINAPI wWinMain( HINSTANCE inst, HINSTANCE prev, LPWSTR cmdline, int show )
{
    char ready[64];

    CreateDirectoryW( AGENT_DIR, NULL );
    DeleteFileW( READY_PATH );
    DeleteFileW( REQUEST_PATH );
    DeleteFileW( RESULT_PATH );
    agent_log( "madeira-agent started, pid=%lu, cmdline=%ls", (unsigned long)GetCurrentProcessId(), cmdline );

    /* Run the command explorer used to run itself (services.exe). It is a
     * plain command line, so no quoting games: start it as given. */
    if (cmdline && *cmdline)
    {
        STARTUPINFOW si;
        PROCESS_INFORMATION pi;
        memset( &si, 0, sizeof(si) );
        si.cb = sizeof(si);
        if (CreateProcessW( NULL, cmdline, NULL, NULL, FALSE, 0, NULL, NULL, &si, &pi ))
        {
            agent_log( "started %ls pid=%lu", cmdline, (unsigned long)pi.dwProcessId );
            CloseHandle( pi.hThread );
            CloseHandle( pi.hProcess );
        }
        else agent_log( "failed to start %ls: %lu", cmdline, (unsigned long)GetLastError() );
    }

    snprintf( ready, sizeof(ready), "pid=%lu\r\n", (unsigned long)GetCurrentProcessId() );
    write_text_file( READY_PATH, ready );

    DeleteFileW( EXIT_PATH );
    for (;;)
    {
        Sleep( 200 );
        if (GetFileAttributesW( REQUEST_PATH ) != INVALID_FILE_ATTRIBUTES) handle_request();
        if (g_child_n) reap_children();
    }
    return 0;
}
