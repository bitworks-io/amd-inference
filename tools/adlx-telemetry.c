/* Private, read-only lab diagnostic. Build against the pinned AMD ADLX SDK.
 * No tuning interfaces are referenced. This program is not an inference probe. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <math.h>
#include "ADLX.h"
#include "IPerformanceMonitoring.h"

typedef struct {
    IADLXGPU *gpu;
    IADLXGPUMetricsSupport *support;
    char pnp[256];
    char vendor[32];
    char device[32];
} GpuRow;

static void json_string(const char *s) {
    unsigned i;
    putchar('"');
    if (s) for (i = 0; s[i] && i < 255; ++i) {
        unsigned char c = (unsigned char)s[i];
        if (c == '"' || c == '\\') { putchar('\\'); putchar(c); }
        else if (c >= 32 && c <= 126) putchar(c);
        else printf("\\u%04x", c);
    }
    putchar('"');
}

static void copy_bounded(char *dst, size_t cap, const char *src) {
    size_t i = 0;
    if (!src) { dst[0] = 0; return; }
    while (i + 1 < cap && src[i]) { dst[i] = src[i]; ++i; }
    /* Never present a truncated PNP identifier as an exact adapter identity. */
    dst[i] = 0;
    if (src[i]) dst[0] = 0;
}

static void int_metric(const char *name, ADLX_RESULT support_result, adlx_bool supported,
                       ADLX_RESULT value_result, adlx_int value) {
    printf(",\"%s\":{\"status\":", name);
    if (ADLX_FAILED(support_result)) json_string("support-query-error");
    else if (!supported) json_string("unsupported");
    else if (ADLX_FAILED(value_result)) json_string("sample-error");
    else json_string("available");
    printf(",\"value\":");
    if (ADLX_SUCCEEDED(support_result) && supported && ADLX_SUCCEEDED(value_result)) printf("%d", (int)value);
    else printf("null");
    putchar('}');
}

static void double_metric(const char *name, ADLX_RESULT support_result, adlx_bool supported,
                          ADLX_RESULT value_result, adlx_double value) {
    int valid = isfinite(value) && value > -1000.0 && value < 1000000.0;
    printf(",\"%s\":{\"status\":", name);
    if (ADLX_FAILED(support_result)) json_string("support-query-error");
    else if (!supported) json_string("unsupported");
    else if (ADLX_FAILED(value_result)) json_string("sample-error");
    else if (!valid) json_string("invalid-value");
    else json_string("available");
    printf(",\"value\":");
    if (ADLX_SUCCEEDED(support_result) && supported && ADLX_SUCCEEDED(value_result) && valid)
        printf("%.3f", (double)value);
    else printf("null");
    putchar('}');
}

#define INT_METRIC(key, support_call, sample_call) do { \
    adlx_bool yes = false; adlx_int val = 0; ADLX_RESULT sr = ADLX_FAIL, vr = ADLX_FAIL; \
    if (s) sr = s->pVtbl->support_call(s, &yes); \
    if (m && ADLX_SUCCEEDED(sr) && yes) vr = m->pVtbl->sample_call(m, &val); \
    int_metric(key, sr, yes, vr, val); \
} while (0)
#define DOUBLE_METRIC(key, support_call, sample_call) do { \
    adlx_bool yes = false; adlx_double val = 0; ADLX_RESULT sr = ADLX_FAIL, vr = ADLX_FAIL; \
    if (s) sr = s->pVtbl->support_call(s, &yes); \
    if (m && ADLX_SUCCEEDED(sr) && yes) vr = m->pVtbl->sample_call(m, &val); \
    double_metric(key, sr, yes, vr, val); \
} while (0)

static void sample_gpu(unsigned sample, unsigned index, GpuRow *row,
                       IADLXPerformanceMonitoringServices *perf) {
    FILETIME ft;
    ULARGE_INTEGER stamp;
    IADLXGPUMetrics *m = NULL;
    IADLXGPUMetricsSupport *s = row->support;
    ADLX_RESULT mr = perf->pVtbl->GetCurrentGPUMetrics(perf, row->gpu, &m);
    GetSystemTimeAsFileTime(&ft);
    stamp.LowPart = ft.dwLowDateTime;
    stamp.HighPart = ft.dwHighDateTime;
    printf("{\"schemaVersion\":1,\"kind\":\"adlx-gpu-sample\",\"sample\":%u,\"gpuIndex\":%u,\"utcFileTime\":%llu,\"pnp\":", sample, index, (unsigned long long)stamp.QuadPart);
    json_string(row->pnp);
    printf(",\"vendorId\":"); json_string(row->vendor);
    printf(",\"deviceId\":"); json_string(row->device);
    printf(",\"identityStatus\":");
    json_string(row->pnp[0] && row->vendor[0] && row->device[0] ? "available" : "incomplete");
    printf(",\"metricsStatus\":"); json_string(ADLX_SUCCEEDED(mr) && m ? "available" : "sample-error");
    INT_METRIC("gpuClockMHz", IsSupportedGPUClockSpeed, GPUClockSpeed);
    INT_METRIC("vramClockMHz", IsSupportedGPUVRAMClockSpeed, GPUVRAMClockSpeed);
    DOUBLE_METRIC("gpuUsagePercent", IsSupportedGPUUsage, GPUUsage);
    DOUBLE_METRIC("totalBoardPowerW", IsSupportedGPUTotalBoardPower, GPUTotalBoardPower);
    DOUBLE_METRIC("gpuTemperatureC", IsSupportedGPUTemperature, GPUTemperature);
    DOUBLE_METRIC("hotspotTemperatureC", IsSupportedGPUHotspotTemperature, GPUHotspotTemperature);
    printf(",\"qualification\":false,\"servingDeviceBound\":false}\n");
    fflush(stdout);
    if (m) m->pVtbl->Release(m);
}

int main(void) {
    wchar_t dll[MAX_PATH];
    UINT n;
    HMODULE lib = NULL;
    ADLXInitialize_Fn init;
    ADLXTerminate_Fn term;
    IADLXSystem *sys = NULL;
    IADLXGPUList *list = NULL;
    IADLXPerformanceMonitoringServices *perf = NULL;
    GpuRow rows[8] = {0};
    unsigned count = 0, i, tick;
    int rc = 1;
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
    if (ADLX_FAILED(sys->pVtbl->GetPerformanceMonitoringServices(sys, &perf)) || !perf) { fprintf(stderr, "adlx-metrics-service-failed\n"); goto terminate; }
    count = list->pVtbl->Size(list);
    if (count == 0 || count > 8) { fprintf(stderr, "adlx-gpu-count-out-of-bounds\n"); goto terminate; }
    for (i = 0; i < count; ++i) {
        const char *id = NULL;
        unsigned pos = list->pVtbl->Begin(list) + i;
        if (ADLX_FAILED(list->pVtbl->At_GPUList(list, pos, &rows[i].gpu)) || !rows[i].gpu) { fprintf(stderr, "adlx-gpu-enumeration-failed\n"); goto terminate; }
        if (ADLX_SUCCEEDED(rows[i].gpu->pVtbl->PNPString(rows[i].gpu, &id))) copy_bounded(rows[i].pnp, sizeof(rows[i].pnp), id);
        id = NULL;
        if (ADLX_SUCCEEDED(rows[i].gpu->pVtbl->VendorId(rows[i].gpu, &id))) copy_bounded(rows[i].vendor, sizeof(rows[i].vendor), id);
        id = NULL;
        if (ADLX_SUCCEEDED(rows[i].gpu->pVtbl->DeviceId(rows[i].gpu, &id))) copy_bounded(rows[i].device, sizeof(rows[i].device), id);
        if (ADLX_FAILED(perf->pVtbl->GetSupportedGPUMetrics(perf, rows[i].gpu, &rows[i].support))) rows[i].support = NULL;
    }
    for (tick = 0; tick < 10; ++tick) {
        for (i = 0; i < count; ++i) sample_gpu(tick, i, &rows[i], perf);
        if (tick + 1 < 10) Sleep(1000);
    }
    rc = 0;
terminate:
    for (i = 0; i < 8; ++i) {
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
