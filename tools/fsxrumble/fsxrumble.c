/* fsxrumble: Xbox controller rumble for FSX.
 *
 * FSX only sends force feedback through DirectInput, which Xbox controllers don't support (on Windows too).
 * This companion reads the user aircraft's state through SimConnect and drives the controller's motors
 * directly with HID output reports:
 *   - touchdown: a thump scaled by sink rate
 *   - ground roll: a low rumble scaled by ground speed
 *   - stall warning: a sharp buzz; overspeed warning: a lighter buzz
 *   - landing gear in transit: a light rumble
 *
 * SimConnect is loaded from SimConnect.dll beside this program (FSX ships it), with the few functions
 * declared here from the public SimConnect documentation. Rumble report for the Xbox Wireless Controller
 * over Bluetooth (045E:0B20): report 0x03 = {enable mask, left trigger, right trigger, left (strong) motor,
 * right (weak) motor, duration x10 ms, delay, repeat}, strengths 0-100.
 *
 * Start it with FSX via exe.xml (see docs/BUILD.md); it exits when FSX quits.
 * Build: i686-w64-mingw32-gcc -O2 -o fsxrumble.exe fsxrumble.c -lhid -lsetupapi
 */
#include <windows.h>
#include <setupapi.h>
#include <hidsdi.h>
#include <stdio.h>
#include <math.h>

/* ---- SimConnect (subset) ---- */
typedef struct { DWORD size, version, id; } SC_RECV;
typedef struct { SC_RECV hdr; DWORD request, object, define, flags, entry, outof, count; double data[1]; } SC_RECV_DATA;
#define SC_RECV_ID_QUIT         3
#define SC_RECV_ID_SIMOBJECT    8
#define SC_DATATYPE_FLOAT64     4
#define SC_PERIOD_SIM_FRAME     3
#define SC_OBJECT_USER          0

typedef HRESULT (__stdcall *sc_open_fn)(HANDLE *, const char *, HWND, DWORD, HANDLE, DWORD);
typedef HRESULT (__stdcall *sc_close_fn)(HANDLE);
typedef HRESULT (__stdcall *sc_add_fn)(HANDLE, DWORD, const char *, const char *, DWORD, float, DWORD);
typedef HRESULT (__stdcall *sc_request_fn)(HANDLE, DWORD, DWORD, DWORD, DWORD, DWORD, DWORD, DWORD, DWORD);
typedef HRESULT (__stdcall *sc_next_fn)(HANDLE, SC_RECV **, DWORD *);

static sc_open_fn sc_open;
static sc_close_fn sc_close;
static sc_add_fn sc_add;
static sc_request_fn sc_request;
static sc_next_fn sc_next;

enum { V_ON_GROUND, V_GROUND_SPEED, V_VERTICAL_SPEED, V_STALL, V_OVERSPEED, V_GEAR, V_COUNT };
static const struct { const char *name, *units; } vars[V_COUNT] =
{
    { "SIM ON GROUND", "Bool" },
    { "GROUND VELOCITY", "Knots" },
    { "VELOCITY WORLD Y", "Feet per second" },
    { "STALL WARNING", "Bool" },
    { "OVERSPEED WARNING", "Bool" },
    { "GEAR TOTAL PCT EXTENDED", "Percent over 100" },
};

static FILE *log_file;

static void log_msg(const char *msg)
{
    if (!log_file)
    {
        char path[MAX_PATH], *slash;
        GetModuleFileNameA(NULL, path, MAX_PATH);
        if ((slash = strrchr(path, '\\'))) strcpy(slash + 1, "fsxrumble.log");
        if (!(log_file = fopen(path, "w"))) return;
    }
    fprintf(log_file, "%s\n", msg);
    fflush(log_file);
}

/* ---- controller ---- */
static HANDLE pad = INVALID_HANDLE_VALUE;
static DWORD pad_report_len;

static void pad_close(void)
{
    if (pad != INVALID_HANDLE_VALUE) CloseHandle(pad);
    pad = INVALID_HANDLE_VALUE;
}

static BOOL pad_open(void)
{
    GUID hid;
    HDEVINFO set;
    SP_DEVICE_INTERFACE_DATA ifd = { sizeof(ifd) };
    DWORD i, need;

    HidD_GetHidGuid(&hid);
    set = SetupDiGetClassDevsA(&hid, NULL, NULL, DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
    if (set == INVALID_HANDLE_VALUE) return FALSE;
    for (i = 0; pad == INVALID_HANDLE_VALUE && SetupDiEnumDeviceInterfaces(set, NULL, &hid, i, &ifd); i++)
    {
        SP_DEVICE_INTERFACE_DETAIL_DATA_A *detail;
        HIDD_ATTRIBUTES attr = { sizeof(attr) };
        PHIDP_PREPARSED_DATA pp;
        HIDP_CAPS caps;
        HANDLE h;

        SetupDiGetDeviceInterfaceDetailA(set, &ifd, NULL, 0, &need, NULL);
        if (!(detail = malloc(need))) break;
        detail->cbSize = sizeof(*detail);
        if (SetupDiGetDeviceInterfaceDetailA(set, &ifd, detail, need, NULL, NULL) &&
            (h = CreateFileA(detail->DevicePath, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE,
                             NULL, OPEN_EXISTING, 0, NULL)) != INVALID_HANDLE_VALUE)
        {
            if (HidD_GetAttributes(h, &attr) && attr.VendorID == 0x045e && attr.ProductID == 0x0b20 &&
                HidD_GetPreparsedData(h, &pp))
            {
                HidP_GetCaps(pp, &caps);
                HidD_FreePreparsedData(pp);
                if (caps.OutputReportByteLength >= 9)
                {
                    pad = h;
                    pad_report_len = caps.OutputReportByteLength;
                }
            }
            if (pad != h) CloseHandle(h);
        }
        free(detail);
    }
    SetupDiDestroyDeviceInfoList(set);
    return pad != INVALID_HANDLE_VALUE;
}

/* strengths 0-100; duration in 10 ms units */
static void pad_rumble(int strong, int weak, int duration)
{
    BYTE report[64] = { 0x03, 0x0f, 0, 0, 0, 0, 0, 0, 0 };
    DWORD written;
    if (pad == INVALID_HANDLE_VALUE && !pad_open()) return;
    report[4] = (BYTE)max(0, min(100, strong));
    report[5] = (BYTE)max(0, min(100, weak));
    report[6] = (BYTE)duration;
    if (!WriteFile(pad, report, pad_report_len, &written, NULL)) pad_close();
}

/* ---- effects ---- */
struct state { double v[V_COUNT]; };

static void effects(const struct state *s, const struct state *prev, DWORD now)
{
    static DWORD thump_until, last_send;
    static int thump, last_strong = -1, last_weak = -1;
    int strong = 0, weak = 0;

    /* touchdown: sink rate at the moment the wheels touch, 100-700 fpm -> 30-100 */
    if (s->v[V_ON_GROUND] > 0.5 && prev->v[V_ON_GROUND] < 0.5)
    {
        double fpm = fabs(prev->v[V_VERTICAL_SPEED]) * 60.0;
        thump = (int)(30 + 70 * min(1.0, max(0.0, (fpm - 100.0) / 600.0)));
        thump_until = now + 250;
    }
    if (now < thump_until) { strong = thump; weak = thump / 2; }

    /* ground roll: up to 25 at 80 knots and above */
    if (s->v[V_ON_GROUND] > 0.5 && s->v[V_GROUND_SPEED] > 3.0)
        strong = max(strong, (int)(5 + 20 * min(1.0, s->v[V_GROUND_SPEED] / 80.0)));

    /* gear moving */
    if (s->v[V_GEAR] > 0.02 && s->v[V_GEAR] < 0.98 && fabs(s->v[V_GEAR] - prev->v[V_GEAR]) > 1e-4)
        strong = max(strong, 12);

    if (s->v[V_STALL] > 0.5) weak = max(weak, 45);
    if (s->v[V_OVERSPEED] > 0.5) weak = max(weak, 25);

    /* send on change, and refresh every 100 ms while active (each report lasts 200 ms) */
    if (strong != last_strong || weak != last_weak || ((strong || weak) && now - last_send >= 100))
    {
        pad_rumble(strong, weak, (strong || weak) ? 20 : 0);
        last_strong = strong;
        last_weak = weak;
        last_send = now;
    }
}

static BOOL load_simconnect(void)
{
    char path[MAX_PATH], *slash;
    HMODULE mod;
    GetModuleFileNameA(NULL, path, MAX_PATH);
    if ((slash = strrchr(path, '\\'))) strcpy(slash + 1, "SimConnect.dll");
    if (!(mod = LoadLibraryA(path)) && !(mod = LoadLibraryA("SimConnect.dll"))) return FALSE;
    sc_open = (sc_open_fn)GetProcAddress(mod, "SimConnect_Open");
    sc_close = (sc_close_fn)GetProcAddress(mod, "SimConnect_Close");
    sc_add = (sc_add_fn)GetProcAddress(mod, "SimConnect_AddToDataDefinition");
    sc_request = (sc_request_fn)GetProcAddress(mod, "SimConnect_RequestDataOnSimObject");
    sc_next = (sc_next_fn)GetProcAddress(mod, "SimConnect_GetNextDispatch");
    return sc_open && sc_close && sc_add && sc_request && sc_next;
}

int main(int argc, char **argv)
{
    HANDLE sc = NULL;
    struct state cur = { { 1 } }, prev;
    BOOL have_data = FALSE;
    int i, tries;

    if (argc > 1 && !strcmp(argv[1], "--test"))
    {
        printf("controller %s\n", pad_open() ? "found" : "not found");
        pad_rumble(60, 60, 50);
        Sleep(700);
        pad_rumble(0, 0, 0);
        return 0;
    }
    if (!load_simconnect()) { log_msg("SimConnect.dll not found"); return 1; }
    log_msg("waiting for FSX");

    /* FSX may still be starting: retry for two minutes */
    for (tries = 0; tries < 120 && FAILED(sc_open(&sc, "fsxrumble", NULL, 0, NULL, 0)); tries++) Sleep(1000);
    if (!sc) { log_msg("could not connect to FSX"); return 1; }
    log_msg("connected to FSX");
    for (i = 0; i < V_COUNT; i++) sc_add(sc, 0, vars[i].name, vars[i].units, SC_DATATYPE_FLOAT64, 0.0f, (DWORD)-1);
    sc_request(sc, 0, 0, SC_OBJECT_USER, SC_PERIOD_SIM_FRAME, 0, 0, 0, 0);
    log_msg(pad_open() ? "controller found" : "controller not found (will keep trying)");

    for (;;)
    {
        SC_RECV *msg;
        DWORD size;
        BOOL quit = FALSE;
        while (SUCCEEDED(sc_next(sc, &msg, &size)))
        {
            if (msg->id == SC_RECV_ID_QUIT) quit = TRUE;
            else if (msg->id == SC_RECV_ID_SIMOBJECT)
            {
                const SC_RECV_DATA *d = (const SC_RECV_DATA *)msg;
                prev = cur;
                memcpy(cur.v, d->data, sizeof(cur.v));
                if (!have_data) { prev = cur; have_data = TRUE; log_msg("receiving flight data"); }
                effects(&cur, &prev, GetTickCount());
            }
        }
        if (quit) { log_msg("FSX quit"); break; }
        Sleep(10);
    }
    pad_rumble(0, 0, 0);
    sc_close(sc);
    return 0;
}
