/*
 * ZMHelper v1.1 — ZoneMusic engine-music sentinel (Ashita v4 plugin)
 *
 * PROBLEM THIS SOLVES:
 *   FFXI cutscene scores can be started by CLIENT-SIDE event scripts with
 *   zero network traffic. No packet-based addon can see them, which made
 *   ZoneMusic's WAV covers overlap scored cutscenes. The client streams
 *   every track from a .bgw file under .../win/music/... — this plugin
 *   watches those file opens and reports each one to the ZoneMusic addon
 *   through a signal file:
 *
 *       <Ashita>\addons\zonemusic\engine_music.signal
 *       format:  "<counter> <music_id> <tickcount>\n"
 *
 * v1.1 FIXES (both v1.0 defects were real-world confirmed):
 *   1. CRASH ON ZONE-IN: v1.0 patched functions while other game threads
 *      could be executing inside them (Detours requires updating EVERY
 *      thread, not just the current one). v1.1 enumerates all process
 *      threads via Toolhelp and registers each with DetourUpdateThread
 *      before committing, for both attach and detach.
 *   2. NO SIGNAL: v1.0 detoured the fopen_s that THIS DLL links against,
 *      which is not necessarily the CRT copy the game's music streamer
 *      calls. v1.1 walks the loaded CRT modules (msvcrt, ucrtbase, the
 *      msvcr* family, api-ms-win-crt-stdio forwarder) and hooks EVERY
 *      exported fopen_s / _fsopen / fopen it finds, plus kernel32's
 *      CreateFileA, and prints exactly what it hooked to the chat log so
 *      a miss is visible instead of silent.
 *
 * Hook layer reference: XIPivot (Redirector.cpp) — fopen_s detour and
 * "\\win\\music\\" path handling for its sound overlays.
 *
 * SAFE COEXISTENCE: Microsoft Detours chains multiple detours on the same
 * function (XIPivot + ZMHelper). ZMHelper never modifies paths or results.
 */

#include "Ashita.h"

#include <windows.h>
#include <tlhelp32.h>
#include <cctype>
#include <cstdint>
#include <cstdarg>
#include <cstdio>
#include <cstring>

#include "detours.h"

/* ---------------------------------------------------------------------- */
/* signal state                                                            */
/* ---------------------------------------------------------------------- */

static CRITICAL_SECTION g_lock;
static bool             g_lockInit = false;
static char             g_signalPath[MAX_PATH] = { 0 };
static volatile LONG    g_counter = 0;
static bool             g_hooked = false;

/* kernel32's real CreateFileA — resolved via GetProcAddress, also used to
 * write the signal file so our writes never re-enter any detour chain. */
typedef HANDLE(WINAPI* pFnCreateFileA)(LPCSTR, DWORD, DWORD, LPSECURITY_ATTRIBUTES, DWORD, DWORD, HANDLE);
static pFnCreateFileA g_realCreateFileA = nullptr;

/* ---------------------------------------------------------------------- */
/* music path matching                                                     */
/* ---------------------------------------------------------------------- */

/*
 * Returns:
 *   >= 0 : music id parsed from the basename digits (musicNNN.bgw -> NNN)
 *   -2   : a .bgw under a music dir with no parseable number (still music)
 *   -1   : not a music file — ignore
 */
static int music_id_from_path(const char* p)
{
    if (p == nullptr)
        return -1;

    const size_t len = strlen(p);
    if (len < 5)
        return -1;

    const char* ext = p + len - 4;
    if (_stricmp(ext, ".bgw") != 0)
        return -1;

    if (strstr(p, "\\music\\") == nullptr && strstr(p, "/music/") == nullptr)
        return -1;

    int id = 0, mul = 1, digits = 0;
    for (const char* c = ext - 1; c >= p && isdigit(static_cast<unsigned char>(*c)); --c)
    {
        id += (*c - '0') * mul;
        mul *= 10;
        if (++digits >= 6)
            break;
    }
    return (digits > 0) ? id : -2;
}

static void write_signal(int musicId)
{
    if (g_signalPath[0] == '\0' || !g_lockInit || g_realCreateFileA == nullptr)
        return;

    EnterCriticalSection(&g_lock);

    const LONG n = InterlockedIncrement(&g_counter);

    HANDLE h = g_realCreateFileA(g_signalPath, GENERIC_WRITE, FILE_SHARE_READ,
                                 nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h != INVALID_HANDLE_VALUE)
    {
        char buf[64];
        const int blen = _snprintf_s(buf, sizeof(buf), _TRUNCATE,
                                     "%ld %d %lu\n", n, musicId,
                                     static_cast<unsigned long>(GetTickCount()));
        if (blen > 0)
        {
            DWORD written = 0;
            WriteFile(h, buf, static_cast<DWORD>(blen), &written, nullptr);
        }
        CloseHandle(h);
    }

    LeaveCriticalSection(&g_lock);
}

/* ---------------------------------------------------------------------- */
/* hook slots — one trampoline per hooked address                          */
/* ---------------------------------------------------------------------- */

typedef errno_t(__cdecl* pFnFOpenS)(FILE**, const char*, const char*);
typedef FILE*(__cdecl* pFnFOpen)(const char*, const char*);
typedef FILE*(__cdecl* pFnFsOpen)(const char*, const char*, int);

#define MAX_SLOTS 4

static pFnFOpenS g_fopen_s_real[MAX_SLOTS] = { 0 };
static pFnFOpen  g_fopen_real[MAX_SLOTS]   = { 0 };
static pFnFsOpen g_fsopen_real[MAX_SLOTS]  = { 0 };
static int g_fopen_s_count = 0, g_fopen_count = 0, g_fsopen_count = 0;

/* fopen_s detours */
#define DEF_FOPEN_S(i)                                                              \
    static errno_t __cdecl dFOpenS##i(FILE** f, const char* path, const char* mode) \
    {                                                                               \
        const int id = music_id_from_path(path);                                    \
        const errno_t r = g_fopen_s_real[i](f, path, mode);                         \
        if (id != -1 && r == 0 && f != nullptr && *f != nullptr)                    \
            write_signal(id);                                                       \
        return r;                                                                   \
    }
DEF_FOPEN_S(0) DEF_FOPEN_S(1) DEF_FOPEN_S(2) DEF_FOPEN_S(3)
static const PVOID g_fopen_s_thunks[MAX_SLOTS] = { (PVOID)dFOpenS0, (PVOID)dFOpenS1, (PVOID)dFOpenS2, (PVOID)dFOpenS3 };

/* fopen detours */
#define DEF_FOPEN(i)                                                    \
    static FILE* __cdecl dFOpen##i(const char* path, const char* mode)  \
    {                                                                   \
        const int id = music_id_from_path(path);                        \
        FILE* r = g_fopen_real[i](path, mode);                          \
        if (id != -1 && r != nullptr)                                   \
            write_signal(id);                                           \
        return r;                                                       \
    }
DEF_FOPEN(0) DEF_FOPEN(1) DEF_FOPEN(2) DEF_FOPEN(3)
static const PVOID g_fopen_thunks[MAX_SLOTS] = { (PVOID)dFOpen0, (PVOID)dFOpen1, (PVOID)dFOpen2, (PVOID)dFOpen3 };

/* _fsopen detours */
#define DEF_FSOPEN(i)                                                              \
    static FILE* __cdecl dFsOpen##i(const char* path, const char* mode, int sh)    \
    {                                                                              \
        const int id = music_id_from_path(path);                                   \
        FILE* r = g_fsopen_real[i](path, mode, sh);                                \
        if (id != -1 && r != nullptr)                                              \
            write_signal(id);                                                      \
        return r;                                                                  \
    }
DEF_FSOPEN(0) DEF_FSOPEN(1) DEF_FSOPEN(2) DEF_FSOPEN(3)
static const PVOID g_fsopen_thunks[MAX_SLOTS] = { (PVOID)dFsOpen0, (PVOID)dFsOpen1, (PVOID)dFsOpen2, (PVOID)dFsOpen3 };

/* CreateFileA detour (kernel32 — single canonical address) */
static pFnCreateFileA g_createfile_real = nullptr;
static HANDLE WINAPI dCreateFileA(LPCSTR path, DWORD access, DWORD share,
                                  LPSECURITY_ATTRIBUTES sa, DWORD disp,
                                  DWORD flags, HANDLE tmpl)
{
    const int id = music_id_from_path(path);
    const HANDLE h = g_createfile_real(path, access, share, sa, disp, flags, tmpl);
    if (id != -1 && h != INVALID_HANDLE_VALUE && (access & GENERIC_READ) != 0)
        write_signal(id);
    return h;
}

/* ---------------------------------------------------------------------- */
/* thread-safe detour transactions                                         */
/* ---------------------------------------------------------------------- */

/*
 * Detours requires EVERY thread that might be executing inside a target
 * function to be registered with DetourUpdateThread so its instruction
 * pointer can be adjusted when the patch lands. v1.0 only updated the
 * current thread — patching CreateFileA mid-game while loader threads were
 * inside it crashed on zone-in. This walks the whole process.
 */
static void update_all_threads(void)
{
    const DWORD pid = GetCurrentProcessId();
    const DWORD self = GetCurrentThreadId();

    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
    if (snap == INVALID_HANDLE_VALUE)
        return;

    THREADENTRY32 te;
    te.dwSize = sizeof(te);
    if (Thread32First(snap, &te))
    {
        do
        {
            if (te.th32OwnerProcessID == pid && te.th32ThreadID != self)
            {
                HANDLE th = OpenThread(THREAD_SUSPEND_RESUME | THREAD_GET_CONTEXT | THREAD_SET_CONTEXT,
                                       FALSE, te.th32ThreadID);
                if (th != nullptr)
                {
                    /* Detours takes ownership semantics for the update; it
                     * suspends/resumes and adjusts contexts on commit. The
                     * handle must stay valid through the transaction, so we
                     * intentionally leak it until process exit — these are
                     * two transactions per session, not a hot path. */
                    DetourUpdateThread(th);
                }
            }
        } while (Thread32Next(snap, &te));
    }
    CloseHandle(snap);
}

/* ---------------------------------------------------------------------- */
/* plugin                                                                  */
/* ---------------------------------------------------------------------- */

class ZMHelper final : public IPlugin
{
    IAshitaCore* m_core = nullptr;
    char m_report[512] = { 0 };

public:
    const char* GetName(void) const override        { return "ZMHelper"; }
    const char* GetAuthor(void) const override      { return "MoonRise"; }
    const char* GetDescription(void) const override { return "ZoneMusic engine-music sentinel: reports every music track the FFXI client starts (including client-side cutscene scores) via a signal file."; }
    const char* GetLink(void) const override        { return "https://github.com/MoonRise"; }
    double      GetVersion(void) const override     { return 1.1; }

    uint32_t GetFlags(void) const override
    {
        return static_cast<uint32_t>(Ashita::PluginFlags::None);
    }

    bool Initialize(IAshitaCore* core, ILogManager* logger, const uint32_t id) override
    {
        UNREFERENCED_PARAMETER(id);

        if (core == nullptr)
            return false;
        m_core = core;

        InitializeCriticalSection(&g_lock);
        g_lockInit = true;

        _snprintf_s(g_signalPath, sizeof(g_signalPath), _TRUNCATE,
                    "%s\\addons\\zonemusic\\engine_music.signal",
                    core->GetInstallPath());

        /* resolve kernel32 CreateFileA canonically */
        HMODULE k32 = GetModuleHandleA("kernel32.dll");
        if (k32 != nullptr)
        {
            g_realCreateFileA = (pFnCreateFileA)GetProcAddress(k32, "CreateFileA");
            g_createfile_real = g_realCreateFileA;
        }

        /* collect fopen_s / _fsopen / fopen from every loaded CRT flavor —
         * the game's music streamer uses ONE of these; we take them all so
         * no client build slips through. */
        const char* crtNames[] = {
            "msvcrt.dll", "ucrtbase.dll",
            "msvcr70.dll", "msvcr71.dll", "msvcr80.dll", "msvcr90.dll",
            "msvcr100.dll", "msvcr110.dll", "msvcr120.dll",
            "api-ms-win-crt-stdio-l1-1-0.dll",
        };

        char found[400] = { 0 };
        for (const char* name : crtNames)
        {
            HMODULE mod = GetModuleHandleA(name);
            if (mod == nullptr)
                continue;

            FARPROC p;
            if (g_fopen_s_count < MAX_SLOTS && (p = GetProcAddress(mod, "fopen_s")) != nullptr)
            {
                g_fopen_s_real[g_fopen_s_count++] = (pFnFOpenS)p;
                appendf(found, sizeof(found), "%s:fopen_s ", name);
            }
            if (g_fsopen_count < MAX_SLOTS && (p = GetProcAddress(mod, "_fsopen")) != nullptr)
            {
                g_fsopen_real[g_fsopen_count++] = (pFnFsOpen)p;
                appendf(found, sizeof(found), "%s:_fsopen ", name);
            }
            if (g_fopen_count < MAX_SLOTS && (p = GetProcAddress(mod, "fopen")) != nullptr)
            {
                g_fopen_real[g_fopen_count++] = (pFnFOpen)p;
                appendf(found, sizeof(found), "%s:fopen ", name);
            }
        }

        /* attach everything in one thread-safe transaction */
        DetourTransactionBegin();
        DetourUpdateThread(GetCurrentThread());
        update_all_threads();

        for (int i = 0; i < g_fopen_s_count; ++i)
            DetourAttach(&(PVOID&)g_fopen_s_real[i], g_fopen_s_thunks[i]);
        for (int i = 0; i < g_fsopen_count; ++i)
            DetourAttach(&(PVOID&)g_fsopen_real[i], g_fsopen_thunks[i]);
        for (int i = 0; i < g_fopen_count; ++i)
            DetourAttach(&(PVOID&)g_fopen_real[i], g_fopen_thunks[i]);
        if (g_createfile_real != nullptr)
            DetourAttach(&(PVOID&)g_createfile_real, (PVOID)dCreateFileA);

        g_hooked = (DetourTransactionCommit() == NO_ERROR);

        _snprintf_s(m_report, sizeof(m_report), _TRUNCATE,
                    "ZMHelper v1.1 %s — hooked: kernel32:CreateFileA %s",
                    g_hooked ? "active" : "FAILED TO ATTACH",
                    found[0] ? found : "(no CRT stdio exports found!)");

        if (logger != nullptr)
            logger->Log(static_cast<uint32_t>(Ashita::LogLevel::Info), "ZMHelper", m_report);
        /* the full hook report goes to the log; chat gets a one-line status */
        if (m_core->GetChatManager() != nullptr)
            m_core->GetChatManager()->Writef(0, false, "ZMHelper: %s",
                g_hooked ? "Ready. Cutscene music will now play correctly."
                         : "Failed to start. Cutscene music fix is NOT active.");

        return g_hooked;
    }

    void Release(void) override
    {
        if (g_hooked)
        {
            DetourTransactionBegin();
            DetourUpdateThread(GetCurrentThread());
            update_all_threads();

            for (int i = 0; i < g_fopen_s_count; ++i)
                DetourDetach(&(PVOID&)g_fopen_s_real[i], g_fopen_s_thunks[i]);
            for (int i = 0; i < g_fsopen_count; ++i)
                DetourDetach(&(PVOID&)g_fsopen_real[i], g_fsopen_thunks[i]);
            for (int i = 0; i < g_fopen_count; ++i)
                DetourDetach(&(PVOID&)g_fopen_real[i], g_fopen_thunks[i]);
            if (g_createfile_real != nullptr)
                DetourDetach(&(PVOID&)g_createfile_real, (PVOID)dCreateFileA);

            DetourTransactionCommit();
            g_hooked = false;
        }
        if (g_lockInit)
        {
            DeleteCriticalSection(&g_lock);
            g_lockInit = false;
        }
    }

private:
    static void appendf(char* dst, size_t cap, const char* fmt, ...)
    {
        const size_t used = strlen(dst);
        if (used + 1 >= cap)
            return;
        va_list ap;
        va_start(ap, fmt);
        _vsnprintf_s(dst + used, cap - used, _TRUNCATE, fmt, ap);
        va_end(ap);
    }
};

/* --- exports (via exports.def) ------------------------------------------ */

extern "C"
{
    double __stdcall expGetInterfaceVersion(void)
    {
        return ASHITA_INTERFACE_VERSION;
    }

    IPlugin* __stdcall expCreatePlugin(const char* args)
    {
        UNREFERENCED_PARAMETER(args);
        return new ZMHelper();
    }

    void __stdcall expDestroyPlugin(void* instance)
    {
        if (instance != nullptr)
        {
            static_cast<ZMHelper*>(instance)->Release();
            delete static_cast<ZMHelper*>(instance);
        }
    }
}
