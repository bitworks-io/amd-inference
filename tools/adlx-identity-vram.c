/* Private, read-only lab collector. Build against the pinned AMD ADLX SDK.
 * Getter and support-query calls only: no tuning interfaces, no power-state
 * transitions, nothing that mutates driver or GPU state. Not an inference probe.
 *
 * Modes:
 *   identity                                one-shot identity records, one per GPU
 *   sample --interval-ms N --count M        bounded metric samples (JSON lines)
 *
 * Every field carries a status and the raw ADLX_RESULT of the call that
 * produced it; nothing is defaulted silently. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <math.h>
#include "ADLX.h"
#include "ISystem1.h"
#include "ISystem2.h"
#include "IPerformanceMonitoring.h"

#define MAX_GPUS 8
#define MIN_INTERVAL_MS 200u
#define MAX_INTERVAL_MS 5000u
#define MAX_COUNT 36000u
#define MAX_WALL_MS 7200000ull
#define MAX_STRING 1023u
#define SCHEMA_VERSION 1

typedef struct {
    IADLXGPU *gpu;
    IADLXGPUMetricsSupport *support;
    ADLX_RESULT supportResult;
    char pnp[256];
    ADLX_RESULT pnpResult;
} GpuRow;

/* ---- JSON helpers ------------------------------------------------------ */

static void json_string(const char *s) {
    unsigned i;
    putchar('"');
    if (s) for (i = 0; s[i] && i < MAX_STRING; ++i) {
        unsigned char c = (unsigned char)s[i];
        if (c == '"' || c == '\\') { putchar('\\'); putchar(c); }
        else if (c >= 32 && c <= 126) putchar(c);
        else printf("\\u%04x", c);
    }
    putchar('"');
}

static void field_open(const char *name, const char *status, int called, ADLX_RESULT result) {
    printf(",\"%s\":{\"status\":\"%s\",\"adlxResult\":", name, status);
    if (called) printf("%d", (int)result); else printf("null");
    printf(",\"value\":");
}

/* iface == 0 means the owning interface was not obtained; result then holds
 * the QueryInterface result. */
static const char *field_status(int iface, ADLX_RESULT result) {
    if (!iface) return "unsupported-interface";
    return ADLX_FAILED(result) ? "failed" : "available";
}

static void field_str(const char *name, int iface, ADLX_RESULT result, const char *s) {
    const char *status = field_status(iface, result);
    int good = iface && ADLX_SUCCEEDED(result);
    if (good && (!s || strnlen(s, MAX_STRING + 1) > MAX_STRING)) status = "invalid-value";
    field_open(name, status, 1, result);
    if (good && s && strnlen(s, MAX_STRING + 1) <= MAX_STRING) json_string(s); else printf("null");
    putchar('}');
}

static void field_uint(const char *name, int iface, ADLX_RESULT result, adlx_uint v) {
    field_open(name, field_status(iface, result), 1, result);
    if (iface && ADLX_SUCCEEDED(result)) printf("%u", (unsigned)v); else printf("null");
    putchar('}');
}

static void field_int(const char *name, int iface, ADLX_RESULT result, adlx_int v) {
    field_open(name, field_status(iface, result), 1, result);
    if (iface && ADLX_SUCCEEDED(result)) printf("%d", (int)v); else printf("null");
    putchar('}');
}

static void field_bool(const char *name, int iface, ADLX_RESULT result, adlx_bool v) {
    field_open(name, field_status(iface, result), 1, result);
    if (iface && ADLX_SUCCEEDED(result)) printf(v ? "true" : "false"); else printf("null");
    putchar('}');
}

/* Enumerations keep the raw integer next to the decoded label. */
static void field_enum(const char *name, int iface, ADLX_RESULT result, int raw, const char *label) {
    field_open(name, field_status(iface, result), 1, result);
    if (iface && ADLX_SUCCEEDED(result)) {
        printf("{\"raw\":%d,\"name\":", raw);
        json_string(label ? label : "unknown-enum-value");
        putchar('}');
    } else printf("null");
    putchar('}');
}

static const char *asic_name(int v) {
    switch (v) {
    case ASIC_UNDEFINED: return "ASIC_UNDEFINED";
    case ASIC_RADEON: return "ASIC_RADEON";
    case ASIC_FIREPRO: return "ASIC_FIREPRO";
    case ASIC_FIREMV: return "ASIC_FIREMV";
    case ASIC_FIRESTREAM: return "ASIC_FIRESTREAM";
    case ASIC_FUSION: return "ASIC_FUSION";
    case ASIC_EMBEDDED: return "ASIC_EMBEDDED";
    default: return NULL;
    }
}

static const char *gpu_type_name(int v) {
    switch (v) {
    case GPUTYPE_UNDEFINED: return "GPUTYPE_UNDEFINED";
    case GPUTYPE_INTEGRATED: return "GPUTYPE_INTEGRATED";
    case GPUTYPE_DISCRETE: return "GPUTYPE_DISCRETE";
    default: return NULL;
    }
}

/* ADLX_PCI_BUS_TYPE, ADLXDefines.h. */
static const char *pci_bus_name(int v) {
    switch (v) {
    case 0: return "UNDEFINED";
    case 1: return "PCI";
    case 2: return "AGP";
    case 3: return "PCIE";
    case 4: return "PCIE_2_0";
    case 5: return "PCIE_3_0";
    case 6: return "PCIE_4_0";
    case 7: return "PCIE_5_0";
    default: return NULL;
    }
}

static const char *mgpu_name(int v) {
    switch (v) {
    case MGPU_NONE: return "MGPU_NONE";
    case MGPU_PRIMARY: return "MGPU_PRIMARY";
    case MGPU_SECONDARY: return "MGPU_SECONDARY";
    default: return NULL;
    }
}

static void copy_bounded(char *dst, size_t cap, const char *src) {
    size_t i = 0;
    if (!src) { dst[0] = 0; return; }
    while (i + 1 < cap && src[i]) { dst[i] = src[i]; ++i; }
    dst[i] = 0;
    /* Never present a truncated PNP identifier as an exact adapter identity. */
    if (src[i]) dst[0] = 0;
}

static unsigned long long file_time_now(void) {
    FILETIME ft; ULARGE_INTEGER stamp;
    GetSystemTimeAsFileTime(&ft);
    stamp.LowPart = ft.dwLowDateTime; stamp.HighPart = ft.dwHighDateTime;
    return (unsigned long long)stamp.QuadPart;
}

static void record_open(const char *kind, unsigned gpuIndex, unsigned gpuCount) {
    printf("{\"schemaVersion\":%d,\"kind\":\"%s\",\"gpuIndex\":%u,\"gpuCount\":%u,\"utcFileTime\":%llu",
           SCHEMA_VERSION, kind, gpuIndex, gpuCount, file_time_now());
}

static int record_close(void) {
    printf(",\"qualification\":false,\"servingDeviceBound\":false}\n");
    if (fflush(stdout) != 0 || ferror(stdout)) return 0;
    return 1;
}

/* ---- identity ---------------------------------------------------------- */

#define STR_FIELD(obj, iface, qi, key, call) do { \
    const char *sv = NULL; ADLX_RESULT rv = (qi); \
    if (iface) rv = (obj)->pVtbl->call((obj), &sv); \
    field_str(key, (iface) != 0, rv, sv); \
} while (0)
#define UINT_FIELD(obj, iface, qi, key, call) do { \
    adlx_uint uv = 0; ADLX_RESULT rv = (qi); \
    if (iface) rv = (obj)->pVtbl->call((obj), &uv); \
    field_uint(key, (iface) != 0, rv, uv); \
} while (0)
#define BOOL_FIELD(obj, iface, qi, key, call) do { \
    adlx_bool bv = false; ADLX_RESULT rv = (qi); \
    if (iface) rv = (obj)->pVtbl->call((obj), &bv); \
    field_bool(key, (iface) != 0, rv, bv); \
} while (0)

static void identity_record(unsigned index, unsigned count, GpuRow *row) {
    IADLXGPU *g = row->gpu;
    IADLXGPU1 *g1 = NULL;
    IADLXGPU2 *g2 = NULL;
    ADLX_RESULT qi1, qi2;
    int have1, have2;
    record_open("adlx-identity", index, count);

    STR_FIELD(g, 1, ADLX_OK, "pnpString", PNPString);
    STR_FIELD(g, 1, ADLX_OK, "vendorId", VendorId);
    STR_FIELD(g, 1, ADLX_OK, "deviceId", DeviceId);
    STR_FIELD(g, 1, ADLX_OK, "revisionId", RevisionId);
    STR_FIELD(g, 1, ADLX_OK, "subSystemId", SubSystemId);
    STR_FIELD(g, 1, ADLX_OK, "subSystemVendorId", SubSystemVendorId);
    STR_FIELD(g, 1, ADLX_OK, "name", Name);
    UINT_FIELD(g, 1, ADLX_OK, "totalVramMB", TotalVRAM);
    STR_FIELD(g, 1, ADLX_OK, "vramType", VRAMType);
    {
        adlx_int v = 0; ADLX_RESULT r = g->pVtbl->UniqueId(g, &v);
        field_int("uniqueId", 1, r, v);
    }
    {
        ADLX_ASIC_FAMILY_TYPE v = ASIC_UNDEFINED; ADLX_RESULT r = g->pVtbl->ASICFamilyType(g, &v);
        field_enum("asicFamilyType", 1, r, (int)v, asic_name((int)v));
    }
    {
        ADLX_GPU_TYPE v = GPUTYPE_UNDEFINED; ADLX_RESULT r = g->pVtbl->Type(g, &v);
        field_enum("type", 1, r, (int)v, gpu_type_name((int)v));
    }
    BOOL_FIELD(g, 1, ADLX_OK, "isExternal", IsExternal);
    BOOL_FIELD(g, 1, ADLX_OK, "hasDesktops", HasDesktops);
    STR_FIELD(g, 1, ADLX_OK, "driverPath", DriverPath);
    {
        const char *part = NULL, *ver = NULL, *date = NULL;
        ADLX_RESULT r = g->pVtbl->BIOSInfo(g, &part, &ver, &date);
        int ok = ADLX_SUCCEEDED(r) && part && ver && date &&
                 strnlen(part, MAX_STRING + 1) <= MAX_STRING && strnlen(ver, MAX_STRING + 1) <= MAX_STRING &&
                 strnlen(date, MAX_STRING + 1) <= MAX_STRING;
        field_open("biosInfo", ADLX_FAILED(r) ? "failed" : (ok ? "available" : "invalid-value"), 1, r);
        if (ok) {
            printf("{\"partNumber\":"); json_string(part);
            printf(",\"version\":"); json_string(ver);
            printf(",\"date\":"); json_string(date);
            putchar('}');
        } else printf("null");
        putchar('}');
    }

    qi1 = g->pVtbl->QueryInterface(g, IID_IADLXGPU1(), (void **)&g1);
    have1 = ADLX_SUCCEEDED(qi1) && g1 != NULL;
    if (!have1) g1 = NULL;
    printf(",\"gpu1Interface\":{\"name\":\"IADLXGPU1\",\"status\":\"%s\",\"adlxResult\":%d}",
           have1 ? "available" : "unsupported-interface", (int)qi1);
    STR_FIELD(g1, have1, qi1, "productName", ProductName);
    {
        ADLX_PCI_BUS_TYPE v = UNDEFINED; ADLX_RESULT r = qi1;
        if (have1) r = g1->pVtbl->PCIBusType(g1, &v);
        field_enum("pciBusType", have1, r, (int)v, pci_bus_name((int)v));
    }
    UINT_FIELD(g1, have1, qi1, "pciBusLaneWidth", PCIBusLaneWidth);
    {
        ADLX_MGPU_MODE v = MGPU_NONE; ADLX_RESULT r = qi1;
        if (have1) r = g1->pVtbl->MultiGPUMode(g1, &v);
        field_enum("multiGpuMode", have1, r, (int)v, mgpu_name((int)v));
    }

    qi2 = g->pVtbl->QueryInterface(g, IID_IADLXGPU2(), (void **)&g2);
    have2 = ADLX_SUCCEEDED(qi2) && g2 != NULL;
    if (!have2) g2 = NULL;
    printf(",\"gpu2Interface\":{\"name\":\"IADLXGPU2\",\"status\":\"%s\",\"adlxResult\":%d}",
           have2 ? "available" : "unsupported-interface", (int)qi2);
    BOOL_FIELD(g2, have2, qi2, "isPowerOff", IsPowerOff);
    STR_FIELD(g2, have2, qi2, "amdSoftwareEdition", AMDSoftwareEdition);
    STR_FIELD(g2, have2, qi2, "amdSoftwareVersion", AMDSoftwareVersion);
    STR_FIELD(g2, have2, qi2, "driverVersion", DriverVersion);
    STR_FIELD(g2, have2, qi2, "amdWindowsDriverVersion", AMDWindowsDriverVersion);
    {
        adlx_uint y = 0, m = 0, d = 0; ADLX_RESULT r = qi2;
        if (have2) r = g2->pVtbl->AMDSoftwareReleaseDate(g2, &y, &m, &d);
        field_open("amdSoftwareReleaseDate", field_status(have2, r), 1, r);
        if (have2 && ADLX_SUCCEEDED(r)) printf("{\"year\":%u,\"month\":%u,\"day\":%u}", (unsigned)y, (unsigned)m, (unsigned)d);
        else printf("null");
        putchar('}');
    }
    {
        ADLX_LUID luid; ADLX_RESULT r = qi2;
        luid.lowPart = 0; luid.highPart = 0;
        if (have2) r = g2->pVtbl->LUID(g2, &luid);
        field_open("luid", field_status(have2, r), 1, r);
        if (have2 && ADLX_SUCCEEDED(r)) printf("{\"lowPart\":%lu,\"highPart\":%ld}", (unsigned long)luid.lowPart, (long)luid.highPart);
        else printf("null");
        putchar('}');
    }
    if (g2) g2->pVtbl->Release(g2);
    if (g1) g1->pVtbl->Release(g1);
    if (!record_close()) fprintf(stderr, "stdout-write-failed\n");
}

/* ---- sample ------------------------------------------------------------ */

/* Status vocabulary: available, unsupported (support query said no),
 * unsupported-interface (no support interface), failed (raw result carried),
 * invalid-value (out-of-range reading). */
static void metric_open(const char *name, const char *status, ADLX_RESULT result, int called) {
    field_open(name, status, called, result);
}

static void int_metric(const char *name, IADLXGPUMetricsSupport *s, ADLX_RESULT supportResult,
                       IADLXGPUMetrics *m, ADLX_RESULT metricsResult, int which) {
    adlx_bool yes = false; adlx_int val = 0;
    ADLX_RESULT sr = supportResult, vr = ADLX_FAIL;
    int valueCalled = 0;
    if (s) {
        sr = which == 0 ? s->pVtbl->IsSupportedGPUVRAM(s, &yes)
           : which == 1 ? s->pVtbl->IsSupportedGPUClockSpeed(s, &yes)
           :              s->pVtbl->IsSupportedGPUVRAMClockSpeed(s, &yes);
    }
    if (!s) { metric_open(name, "unsupported-interface", supportResult, 1); printf("null}"); return; }
    if (ADLX_FAILED(sr)) { metric_open(name, "failed", sr, 1); printf("null}"); return; }
    if (!yes) { metric_open(name, "unsupported", sr, 1); printf("null}"); return; }
    if (!m) { metric_open(name, "failed", metricsResult, 1); printf("null}"); return; }
    vr = which == 0 ? m->pVtbl->GPUVRAM(m, &val)
       : which == 1 ? m->pVtbl->GPUClockSpeed(m, &val)
       :              m->pVtbl->GPUVRAMClockSpeed(m, &val);
    valueCalled = 1;
    if (ADLX_FAILED(vr)) { metric_open(name, "failed", vr, valueCalled); printf("null}"); return; }
    if (val < 0 || val > 10000000) { metric_open(name, "invalid-value", vr, valueCalled); printf("null}"); return; }
    metric_open(name, "available", vr, valueCalled);
    printf("%d}", (int)val);
}

static void double_metric(const char *name, IADLXGPUMetricsSupport *s, ADLX_RESULT supportResult,
                          IADLXGPUMetrics *m, ADLX_RESULT metricsResult, int which) {
    adlx_bool yes = false; adlx_double val = 0;
    ADLX_RESULT sr = supportResult, vr;
    if (!s) { metric_open(name, "unsupported-interface", supportResult, 1); printf("null}"); return; }
    sr = which == 0 ? s->pVtbl->IsSupportedGPUUsage(s, &yes)
       : which == 1 ? s->pVtbl->IsSupportedGPUTotalBoardPower(s, &yes)
       : which == 2 ? s->pVtbl->IsSupportedGPUTemperature(s, &yes)
       :              s->pVtbl->IsSupportedGPUHotspotTemperature(s, &yes);
    if (ADLX_FAILED(sr)) { metric_open(name, "failed", sr, 1); printf("null}"); return; }
    if (!yes) { metric_open(name, "unsupported", sr, 1); printf("null}"); return; }
    if (!m) { metric_open(name, "failed", metricsResult, 1); printf("null}"); return; }
    vr = which == 0 ? m->pVtbl->GPUUsage(m, &val)
       : which == 1 ? m->pVtbl->GPUTotalBoardPower(m, &val)
       : which == 2 ? m->pVtbl->GPUTemperature(m, &val)
       :              m->pVtbl->GPUHotspotTemperature(m, &val);
    if (ADLX_FAILED(vr)) { metric_open(name, "failed", vr, 1); printf("null}"); return; }
    if (!isfinite(val) || val < -1000.0 || val > 1000000.0) { metric_open(name, "invalid-value", vr, 1); printf("null}"); return; }
    metric_open(name, "available", vr, 1);
    printf("%.3f}", (double)val);
}

static int sample_gpu(unsigned sample, unsigned index, unsigned count, GpuRow *row,
                      IADLXPerformanceMonitoringServices *perf) {
    IADLXGPUMetrics *m = NULL;
    ADLX_RESULT mr = perf->pVtbl->GetCurrentGPUMetrics(perf, row->gpu, &m);
    if (ADLX_FAILED(mr) || !m) { if (ADLX_SUCCEEDED(mr)) mr = ADLX_FAIL; m = NULL; }
    record_open("adlx-sample", index, count);
    printf(",\"sample\":%u", sample);
    field_str("pnpString", 1, row->pnpResult, row->pnp[0] ? row->pnp : NULL);
    printf(",\"metricsResult\":%d", (int)mr);
    int_metric("gpuVramMB", row->support, row->supportResult, m, mr, 0);
    double_metric("gpuUsagePercent", row->support, row->supportResult, m, mr, 0);
    int_metric("gpuClockMHz", row->support, row->supportResult, m, mr, 1);
    int_metric("gpuVramClockMHz", row->support, row->supportResult, m, mr, 2);
    double_metric("gpuTotalBoardPowerW", row->support, row->supportResult, m, mr, 1);
    double_metric("gpuTemperatureC", row->support, row->supportResult, m, mr, 2);
    double_metric("gpuHotspotTemperatureC", row->support, row->supportResult, m, mr, 3);
    if (m) m->pVtbl->Release(m);
    return record_close();
}

/* ---- argument parsing -------------------------------------------------- */

static int parse_uint(const char *s, unsigned long long max, unsigned long long *out) {
    unsigned long long v = 0; size_t i;
    if (!s || !s[0] || strlen(s) > 10) return 0;
    for (i = 0; s[i]; ++i) {
        if (s[i] < '0' || s[i] > '9') return 0;
        v = v * 10 + (unsigned)(s[i] - '0');
    }
    if (v > max) return 0;
    *out = v;
    return 1;
}

static int usage(const char *why) {
    fprintf(stderr, "usage-error:%s\n", why);
    return 2;
}

int main(int argc, char **argv) {
    wchar_t dll[MAX_PATH];
    UINT n;
    HMODULE lib = NULL;
    ADLXInitialize_Fn init;
    ADLXTerminate_Fn term;
    IADLXSystem *sys = NULL;
    IADLXGPUList *list = NULL;
    IADLXPerformanceMonitoringServices *perf = NULL;
    GpuRow rows[MAX_GPUS] = {0};
    unsigned count = 0, i;
    int rc = 1, sampleMode = 0;
    unsigned long long intervalMs = 0, sampleCount = 0, v;
    if (argc < 2) return usage("mode-required");
    if (strcmp(argv[1], "identity") == 0) {
        if (argc != 2) return usage("identity-takes-no-arguments");
    } else if (strcmp(argv[1], "sample") == 0) {
        int haveInterval = 0, haveCount = 0, a;
        sampleMode = 1;
        for (a = 2; a < argc; a += 2) {
            if (a + 1 >= argc) return usage("missing-option-value");
            if (strcmp(argv[a], "--interval-ms") == 0 && !haveInterval) {
                if (!parse_uint(argv[a + 1], MAX_INTERVAL_MS, &v) || v < MIN_INTERVAL_MS) return usage("interval-out-of-range");
                intervalMs = v; haveInterval = 1;
            } else if (strcmp(argv[a], "--count") == 0 && !haveCount) {
                if (!parse_uint(argv[a + 1], MAX_COUNT, &v) || v < 1) return usage("count-out-of-range");
                sampleCount = v; haveCount = 1;
            } else return usage("unknown-or-duplicate-option");
        }
        if (!haveInterval || !haveCount) return usage("interval-and-count-required");
        if (intervalMs * sampleCount > MAX_WALL_MS) return usage("total-wall-time-exceeds-2h");
    } else return usage("unknown-mode");

    n = GetSystemDirectoryW(dll, MAX_PATH);
    if (n == 0 || n > MAX_PATH - 16) { fprintf(stderr, "system-directory-unavailable\n"); return 2; }
    wcscat_s(dll, MAX_PATH, L"\\amdadlx64.dll");
    lib = LoadLibraryExW(dll, NULL, LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (!lib) { fprintf(stderr, "adlx-library-unavailable:%lu\n", GetLastError()); return 3; }
    init = (ADLXInitialize_Fn)GetProcAddress(lib, "ADLXInitialize");
    term = (ADLXTerminate_Fn)GetProcAddress(lib, "ADLXTerminate");
    if (!init || !term) { fprintf(stderr, "adlx-exports-unavailable\n"); goto done; }
    if (ADLX_FAILED(init(ADLX_FULL_VERSION, &sys)) || !sys) { fprintf(stderr, "adlx-initialize-failed\n"); goto done; }
    if (ADLX_FAILED(sys->pVtbl->GetGPUs(sys, &list)) || !list) { fprintf(stderr, "adlx-gpu-list-failed\n"); goto terminate; }
    count = list->pVtbl->Size(list);
    if (count == 0 || count > MAX_GPUS) { fprintf(stderr, "adlx-gpu-count-out-of-bounds\n"); goto terminate; }
    if (sampleMode && (ADLX_FAILED(sys->pVtbl->GetPerformanceMonitoringServices(sys, &perf)) || !perf)) {
        fprintf(stderr, "adlx-metrics-service-failed\n"); goto terminate;
    }
    for (i = 0; i < count; ++i) {
        const char *id = NULL;
        unsigned pos = list->pVtbl->Begin(list) + i;
        if (ADLX_FAILED(list->pVtbl->At_GPUList(list, pos, &rows[i].gpu)) || !rows[i].gpu) { fprintf(stderr, "adlx-gpu-enumeration-failed\n"); goto terminate; }
        rows[i].pnpResult = rows[i].gpu->pVtbl->PNPString(rows[i].gpu, &id);
        if (ADLX_SUCCEEDED(rows[i].pnpResult)) copy_bounded(rows[i].pnp, sizeof(rows[i].pnp), id);
        rows[i].supportResult = ADLX_FAIL;
        if (sampleMode) {
            rows[i].supportResult = perf->pVtbl->GetSupportedGPUMetrics(perf, rows[i].gpu, &rows[i].support);
            if (ADLX_FAILED(rows[i].supportResult)) rows[i].support = NULL;
        }
    }
    if (!sampleMode) {
        for (i = 0; i < count; ++i) identity_record(i, count, &rows[i]);
        rc = 0;
    } else {
        unsigned long long start = GetTickCount64(), k;
        rc = 0;
        for (k = 0; k < sampleCount && rc == 0; ++k) {
            unsigned long long due = start + k * intervalMs, now;
            now = GetTickCount64();
            if (now < due) Sleep((DWORD)(due - now));
            for (i = 0; i < count; ++i) {
                if (!sample_gpu((unsigned)k, i, count, &rows[i], perf)) { fprintf(stderr, "stdout-write-failed\n"); rc = 4; break; }
            }
        }
    }
terminate:
    for (i = 0; i < MAX_GPUS; ++i) {
        if (rows[i].support) rows[i].support->pVtbl->Release(rows[i].support);
        if (rows[i].gpu) rows[i].gpu->pVtbl->Release(rows[i].gpu);
    }
    if (perf) perf->pVtbl->Release(perf);
    if (list) list->pVtbl->Release(list);
    term();
done:
    if (lib) FreeLibrary(lib);
    return rc;
}
