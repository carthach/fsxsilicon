/* fsxopt: SSE2 replacement for FSX g2d's GDevice_DrawImmediate (GDevice vtbl +0xdc, 0x206c8fd0),
 * the CPU vertex transform that dominates FSX's main thread under Rosetta (x87 code).
 *
 * No code is patched: the DrawImmediate slot (+0xdc) of g2d's GDX10Device vtable (read-only data) is pointed
 * at the replacement, so every DX10 device object uses it. Only unlit draws ((flags & 0x10) == 0) take the
 * fast path; lit draws call FSX's original.
 *
 * Verify mode (default for the first VERIFY_CALLS fast-path calls): the original runs and fills the real
 * outputs, the replacement fills scratch buffers, and the two are compared. If anything differs beyond
 * float rounding, the replacement is disabled for the rest of the run. Log: fsxopt.log beside the game executable (or %FSXOPT_LOG%).
 *
 * Found by analysing a local copy of g2d.dll (GDevice_DrawImmediate @ 206c8fd0).
 * Build: i686-w64-mingw32-gcc -O2 -msse2 -mfpmath=sse -mpreferred-stack-boundary=2
 *        -mincoming-stack-boundary=2 -shared -static -static-libgcc -o fsxopt.dll fsxopt.c
 */
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <math.h>

#define G2D_PREFERRED          0x20640000u
#define RVA(va)                ((DWORD)(va) - G2D_PREFERRED)
#define RVA_DRAWIMMEDIATE      RVA(0x206c8fd0)
#define RVA_GDX10_VTABLE       RVA(0x2064d0f8)
#define RVA_SETUP_2068EA10     RVA(0x2068ea10)
#define RVA_FOG_206872A0       RVA(0x206872a0)
#define VTABLE_SLOTS           136
#define SLOT_DRAWIMMEDIATE     (0xdc / 4)
#define VERIFY_CALLS           4000

typedef void (__attribute__((thiscall)) *draw_immediate_fn)(void *, unsigned int, const float *, float *,
                                                             unsigned int *, int, unsigned int *, unsigned int *);
typedef void (__attribute__((thiscall)) *vfunc0_fn)(void *);
typedef void (__attribute__((thiscall)) *setup_fn)(void *, int);
typedef int (__attribute__((thiscall)) *fog_fn)(void *, float);

static FILE *log_file;
static DWORD g2d_base;
static draw_immediate_fn original;
static setup_fn setup_2068ea10;
static fog_fn fog_206872a0;
static LONG verify_left = VERIFY_CALLS, mismatches, disabled, fast_calls;

#define F(off) (*(const float *)((const BYTE *)dev + (off)))

/* Fast path of GDevice_DrawImmediate for unlit vertices: transform by the 4x4 at +0x2257c, perspective
 * divide, viewport scale/offset (+0x11aec..+0x11af8), depth clamp, colours, fog, texcoords, clip codes. */
static void transform(void *dev, unsigned int flags, const float *in, float *out, unsigned int *clip, int count,
                      unsigned int *and_out, unsigned int *or_out)
{
    /* FSX's MSVC x87 code evaluates each expression in double precision (53-bit precision control) and
     * rounds to float only when assigning a float variable; mirror that with double expressions and
     * float assignments so the results match FSX's bit for bit (verify mode checks this). */
    const double m00 = F(0x2257c), m01 = F(0x22580), m02 = F(0x22584), m03 = F(0x22588);
    const double m10 = F(0x2258c), m11 = F(0x22590), m12 = F(0x22594), m13 = F(0x22598);
    const double m20 = F(0x2259c), m21 = F(0x225a0), m22 = F(0x225a4), m23 = F(0x225a8);
    const double m30 = F(0x225ac), m31 = F(0x225b0), m32 = F(0x225b4), m33 = F(0x225b8);
    const double ox = F(0x11aec), oy = F(0x11af0), sx = F(0x11af4), sy = F(0x11af8);
    const int fog = *((const BYTE *)dev + 0x11901) != 0;
    const unsigned int ntex = (flags >> 8) & 0xf;
    unsigned int acc_and = 0xffffffff, acc_or = 0;
    int i;

    for (i = 0; i < count; i++, out += 8)
    {
        const double x = in[0], y = in[1], z = in[2];
        const float X = (float)(m30 + z * m20 + y * m10 + x * m00);
        const float Y = (float)(z * m21 + m11 * y + x * m01 + m31);
        const float Z = (float)(z * m22 + m02 * x + y * m12 + m32);
        const float W = (float)(z * m23 + y * m13 + m03 * x + m33);
        const float rhw = W == 0.0f ? 3.40282347e+38f : (float)(1.0 / (double)W);
        float sz = (float)((double)rhw * Z);
        const float *p = in + 3;
        UINT32 diffuse = 0xffffffff, specular = 0xff000000;

        out[0] = (float)((double)rhw * X * sx + ox);
        out[1] = (float)((double)rhw * Y * sy + oy);
        out[3] = rhw;
        if (!(0.0f <= sz)) sz = 0.0f;
        else if ((double)sz > 0.9999899864196777) sz = 0.99999f;
        out[2] = sz;

        if (flags & 0x40) memcpy(&diffuse, p++, 4);
        if (flags & 0x80) memcpy(&specular, p++, 4);
        if (fog) specular = (UINT32)fog_206872a0(dev, W);
        memcpy(&out[4], &diffuse, 4);
        memcpy(&out[5], &specular, 4);
        if (flags & 0xf00)
        {
            out[6] = p[0];
            out[7] = p[1];
            p += ntex * 2;
        }
        in = p;

        if (clip)
        {
            unsigned int code = 0;
            if (X < -W) code = 1;
            if (W <= X) code |= 2;
            if (Y < -W) code |= 8;
            if (W <= Y) code |= 4;
            if (Z < 0.0f) code |= 0x10;
            if (W <= Z) code |= 0x20;
            clip[0] = code;
            memcpy(&clip[1], &X, 4);
            memcpy(&clip[2], &Y, 4);
            memcpy(&clip[3], &Z, 4);
            acc_and &= code;
            acc_or |= code;
            clip += 4;
        }
    }
    if (and_out) *and_out = acc_and;
    if (or_out) *or_out = acc_or;
}

static int close_enough(float a, float b)
{
    float d = fabsf(a - b), m = fmaxf(fabsf(a), fabsf(b));
    return a == b || d <= 1e-5f * m || d <= 1e-6f;
}

static void __attribute__((thiscall)) draw_immediate(void *dev, unsigned int flags, const float *in, float *out,
                                                     unsigned int *clip, int count, unsigned int *and_out,
                                                     unsigned int *or_out)
{
    static float scratch_out[8 * 4096];
    static unsigned int scratch_clip[4 * 4096];
    unsigned int a = 0, o = 0;
    int i, j, bad = 0;

    if ((flags & 0x10) || disabled || count <= 0 || count > 4096)
    {
        original(dev, flags, in, out, clip, count, and_out, or_out);
        return;
    }
    if (verify_left <= 0)
    {
        /* same per-draw state set-up as the original: vtbl +0x21c, then FUN_2068ea10(flags) */
        ((vfunc0_fn)(*(void ***)dev)[0x21c / 4])(dev);
        setup_2068ea10(dev, flags);
        transform(dev, flags, in, out, clip, count, and_out, or_out);
        InterlockedIncrement(&fast_calls);
        return;
    }

    original(dev, flags, in, out, clip, count, and_out, or_out);
    transform(dev, flags, in, scratch_out, clip ? scratch_clip : NULL, count, and_out ? &a : NULL, or_out ? &o : NULL);
    for (i = 0; i < count && !bad; i++)
    {
        for (j = 0; j < 8 && !bad; j++)
        {
            if (j == 4 || j == 5) bad = memcmp(&out[i * 8 + j], &scratch_out[i * 8 + j], 4) != 0;
            else bad = !close_enough(out[i * 8 + j], scratch_out[i * 8 + j]);
            if (bad)
            {
                UINT32 ua, ub;
                memcpy(&ua, &out[i * 8 + j], 4);
                memcpy(&ub, &scratch_out[i * 8 + j], 4);
                fprintf(log_file, "mismatch flags=%#x vertex %d field %d: fsx %08x (%g) ours %08x (%g)\n", flags, i, j,
                        ua, out[i * 8 + j], ub, scratch_out[i * 8 + j]);
            }
        }
        if (clip && !bad && clip[i * 4] != scratch_clip[i * 4])
        {
            bad = 1;
            fprintf(log_file, "mismatch flags=%#x vertex %d clip code fsx %#x ours %#x\n", flags, i, clip[i * 4], scratch_clip[i * 4]);
        }
    }
    if (!bad && and_out && *and_out != a) { bad = 1; fprintf(log_file, "mismatch clip AND %#x vs %#x\n", *and_out, a); }
    if (!bad && or_out && *or_out != o) { bad = 1; fprintf(log_file, "mismatch clip OR %#x vs %#x\n", *or_out, o); }
    if (bad && InterlockedIncrement(&mismatches) > 20)
    {
        disabled = 1;
        fprintf(log_file, "too many mismatches: replacement disabled\n");
    }
    if (InterlockedDecrement(&verify_left) == 0)
        fprintf(log_file, "verify done: %ld mismatching draws; replacement %s\n", mismatches, disabled ? "disabled" : "active");
    fflush(log_file);
}

static DWORD WINAPI install_thread(void *arg)
{
    DWORD vtable;
    int i;

    for (i = 0; i < 2400 && !(g2d_base = (DWORD)GetModuleHandleA("g2d.dll")); i++) Sleep(50);
    if (!g2d_base) { fprintf(log_file, "g2d.dll not found\n"); fflush(log_file); return 0; }
    vtable = g2d_base + RVA_GDX10_VTABLE;
    original = (draw_immediate_fn)((void **)vtable)[SLOT_DRAWIMMEDIATE];
    setup_2068ea10 = (setup_fn)(g2d_base + RVA_SETUP_2068EA10);
    fog_206872a0 = (fog_fn)(g2d_base + RVA_FOG_206872A0);
    if ((DWORD)original != g2d_base + RVA_DRAWIMMEDIATE)
    {
        fprintf(log_file, "unexpected vtable slot %p, not installing\n", original);
        fflush(log_file);
        return 0;
    }
    /* patch the DrawImmediate slot of g2d's GDX10Device vtable itself (read-only data in memory, not
     * code), so every DX10 device object, whenever created, uses the replacement */
    {
        DWORD old_protect;
        void **slot = (void **)vtable + SLOT_DRAWIMMEDIATE;
        if (!VirtualProtect(slot, sizeof(*slot), PAGE_READWRITE, &old_protect))
        {
            fprintf(log_file, "VirtualProtect failed (%lu), not installing\n", GetLastError());
            fflush(log_file);
            return 0;
        }
        InterlockedExchange((LONG *)slot, (LONG)draw_immediate);
        VirtualProtect(slot, sizeof(*slot), old_protect, &old_protect);
    }
    fprintf(log_file, "g2d %08lx: DrawImmediate replaced in the device vtable (verify %d calls)\n", g2d_base, VERIFY_CALLS);
    fflush(log_file);

    return 0;
}

BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, void *reserved)
{
    if (reason == DLL_PROCESS_ATTACH)
    {
        DisableThreadLibraryCalls(inst);
        {
            /* log: %FSXOPT_LOG% if set, else fsxopt.log next to the game executable */
            char path[MAX_PATH];
            DWORD n = GetEnvironmentVariableA("FSXOPT_LOG", path, MAX_PATH);
            if (!n || n >= MAX_PATH)
            {
                n = GetModuleFileNameA(NULL, path, MAX_PATH);
                while (n && path[n - 1] != '\\' && path[n - 1] != '/') n--;
                if (n + 11 < MAX_PATH) memcpy(path + n, "fsxopt.log", 11);
            }
            log_file = fopen(path, "a");
        }
        if (!log_file) log_file = fopen("NUL", "w");
        fprintf(log_file, "--- fsxopt loaded (pid %lu)\n", GetCurrentProcessId());
        fflush(log_file);
        CloseHandle(CreateThread(NULL, 0, install_thread, NULL, 0, NULL));
    }
    return TRUE;
}
