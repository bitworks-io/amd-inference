/* Private ADLX v2 diagnostic. The pinned v1 collector is included unchanged
 * to reuse its exact sample/identity path; its renamed main is never called.
 * All additional ADLX calls below are getters or support queries. */
#define main adlx_v1_unused_main
#include "adlx-telemetry.c"
#undef main
#include "IPerformanceMonitoring2.h"
#include "IGPUTuning.h"
#include "IGPUManualVRAMTuning.h"
#include "IGPUManualPowerTuning.h"
#include "IGPUPresetTuning.h"

typedef struct {
    IADLXInterface *vramBase;
    IADLXManualVRAMTuning2 *vram;
    IADLXInterface *powerBase;
    IADLXManualPowerTuning *power;
    IADLXInterface *presetBase;
    IADLXGPUPresetTuning *preset;
    adlx_bool vramSupported, powerSupported, presetSupported;
    ADLX_RESULT vramSupportResult, powerSupportResult, presetSupportResult;
} TuningRow;

static void print_status_int(const char *name, const char *unavailable,
                             ADLX_RESULT result, adlx_int value) {
    printf(",\"%s\":{\"status\":", name);
    json_string(unavailable ? unavailable : (ADLX_SUCCEEDED(result) ? "available" : "query-error"));
    printf(",\"value\":");
    if (!unavailable && ADLX_SUCCEEDED(result)) printf("%d", (int)value);
    else printf("null");
    putchar('}');
}

static void print_status_bool(const char *name, const char *unavailable,
                              ADLX_RESULT result, adlx_bool value) {
    printf(",\"%s\":{\"status\":", name);
    json_string(unavailable ? unavailable : (ADLX_SUCCEEDED(result) ? "available" : "query-error"));
    printf(",\"value\":");
    if (!unavailable && ADLX_SUCCEEDED(result)) printf(value ? "true" : "false");
    else printf("null");
    putchar('}');
}

static void print_status_range(const char *name, const char *unavailable,
                               ADLX_RESULT result, ADLX_IntRange range) {
    int valid = range.step > 0 && range.minValue <= range.maxValue;
    printf(",\"%s\":{\"status\":", name);
    json_string(unavailable ? unavailable : (ADLX_FAILED(result) ? "query-error" : (valid ? "available" : "invalid-range")));
    printf(",\"value\":");
    if (!unavailable && ADLX_SUCCEEDED(result) && valid)
        printf("{\"min\":%d,\"max\":%d,\"step\":%d}", (int)range.minValue, (int)range.maxValue, (int)range.step);
    else printf("null");
    putchar('}');
}

static const char *tuning_unavailable(ADLX_RESULT supportResult, adlx_bool supported, const void *interface) {
    if (ADLX_FAILED(supportResult)) return "support-query-error";
    if (!supported) return "unsupported";
    if (!interface) return "interface-unavailable";
    return NULL;
}

static void print_preset_flags(TuningRow *t, IADLXGPUTuningServices *tuning) {
    const char *unavailable = tuning ? tuning_unavailable(t->presetSupportResult, t->presetSupported, t->preset) : "service-unavailable";
    adlx_bool b = false; ADLX_RESULT r = ADLX_FAIL;
#define PRESET_FLAG(key, method) do { \
    b = false; r = ADLX_FAIL; \
    if (!unavailable) r = t->preset->pVtbl->method(t->preset, &b); \
    print_status_bool(key, unavailable, r, b); \
} while (0)
    PRESET_FLAG("presetPowerSaverCurrent", IsCurrentPowerSaver);
    PRESET_FLAG("presetQuietCurrent", IsCurrentQuiet);
    PRESET_FLAG("presetBalancedCurrent", IsCurrentBalanced);
    PRESET_FLAG("presetTurboCurrent", IsCurrentTurbo);
    PRESET_FLAG("presetRageCurrent", IsCurrentRage);
#undef PRESET_FLAG
}

static void print_vram_extension(unsigned sample, unsigned index, GpuRow *row,
                                 TuningRow *t, IADLXPerformanceMonitoringServices *perf,
                                 IADLXGPUTuningServices *tuning) {
    FILETIME ft; ULARGE_INTEGER stamp;
    IADLXGPUMetrics *m = NULL;
    IADLXGPUMetrics1 *m1 = NULL;
    IADLXGPUMetricsSupport1 *s1 = NULL;
    adlx_bool supported = false, b = false;
    adlx_double memoryTemp = 0;
    adlx_int integer = 0;
    ADLX_IntRange range = {0};
    ADLX_RESULT supportResult = ADLX_FAIL, valueResult = ADLX_FAIL, r = ADLX_FAIL;
    const char *unavailable;
    if (row->support) row->support->pVtbl->QueryInterface(row->support, IID_IADLXGPUMetricsSupport1(), (void**)&s1);
    if (ADLX_SUCCEEDED(perf->pVtbl->GetCurrentGPUMetrics(perf, row->gpu, &m)) && m)
        m->pVtbl->QueryInterface(m, IID_IADLXGPUMetrics1(), (void**)&m1);
    if (s1) supportResult = s1->pVtbl->IsSupportedGPUMemoryTemperature(s1, &supported);
    if (ADLX_SUCCEEDED(supportResult) && supported && m1)
        valueResult = m1->pVtbl->GPUMemoryTemperature(m1, &memoryTemp);
    GetSystemTimeAsFileTime(&ft);
    stamp.LowPart = ft.dwLowDateTime; stamp.HighPart = ft.dwHighDateTime;
    printf("{\"schemaVersion\":2,\"kind\":\"adlx-vram-diagnostic-sample\",\"sample\":%u,\"gpuIndex\":%u,\"utcFileTime\":%llu", sample, index, (unsigned long long)stamp.QuadPart);
    printf(",\"memoryTemperatureC\":{\"status\":");
    if (!s1 || !m1) json_string("interface-unavailable");
    else if (ADLX_FAILED(supportResult)) json_string("support-query-error");
    else if (!supported) json_string("unsupported");
    else if (ADLX_FAILED(valueResult) || !isfinite(memoryTemp) || memoryTemp < -100.0 || memoryTemp > 300.0) json_string("sample-error");
    else json_string("available");
    printf(",\"value\":");
    if (s1 && m1 && ADLX_SUCCEEDED(supportResult) && supported && ADLX_SUCCEEDED(valueResult) && isfinite(memoryTemp) && memoryTemp >= -100.0 && memoryTemp <= 300.0)
        printf("%.3f", (double)memoryTemp);
    else printf("null");
    putchar('}');

    b = false; r = ADLX_FAIL;
    if (tuning) r = tuning->pVtbl->IsAtFactory(tuning, row->gpu, &b);
    print_status_bool("tuningAtFactory", tuning ? NULL : "service-unavailable", r, b);

    unavailable = tuning ? tuning_unavailable(t->vramSupportResult, t->vramSupported, t->vram) : "service-unavailable";
    integer = 0; r = ADLX_FAIL;
    if (!unavailable) r = t->vram->pVtbl->GetMaxVRAMFrequency(t->vram, &integer);
    print_status_int("configuredMaxVramMHz", unavailable, r, integer);
    memset(&range, 0, sizeof(range)); r = ADLX_FAIL;
    if (!unavailable) r = t->vram->pVtbl->GetMaxVRAMFrequencyRange(t->vram, &range);
    print_status_range("vramTunableMaxRangeMHz", unavailable, r, range);

    unavailable = tuning ? tuning_unavailable(t->powerSupportResult, t->powerSupported, t->power) : "service-unavailable";
    integer = 0; r = ADLX_FAIL;
    if (!unavailable) r = t->power->pVtbl->GetPowerLimit(t->power, &integer);
    print_status_int("manualPowerLimitPercent", unavailable, r, integer);
    memset(&range, 0, sizeof(range)); r = ADLX_FAIL;
    if (!unavailable) r = t->power->pVtbl->GetPowerLimitRange(t->power, &range);
    print_status_range("powerTunableRangePercent", unavailable, r, range);
    print_preset_flags(t, tuning);
    printf(",\"settingsProveEffectiveCap\":false,\"qualification\":false,\"servingDeviceBound\":false}\n");
    fflush(stdout);
    if (m1) m1->pVtbl->Release(m1);
    if (m) m->pVtbl->Release(m);
    if (s1) s1->pVtbl->Release(s1);
}

int main(void) {
    wchar_t dll[MAX_PATH]; UINT n;
    HMODULE lib = NULL;
    ADLXInitialize_Fn init; ADLXTerminate_Fn term;
    IADLXSystem *sys = NULL; IADLXGPUList *list = NULL;
    IADLXPerformanceMonitoringServices *perf = NULL;
    IADLXGPUTuningServices *tuning = NULL;
    GpuRow rows[8] = {0}; TuningRow extra[8] = {0};
    unsigned count = 0, i, tick; int rc = 1;
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
    /* Tuning service failure does not suppress temperature/current-clock evidence. */
    if (ADLX_FAILED(sys->pVtbl->GetGPUTuningServices(sys, &tuning))) tuning = NULL;
    count = list->pVtbl->Size(list);
    if (count == 0 || count > 8) { fprintf(stderr, "adlx-gpu-count-out-of-bounds\n"); goto terminate; }
    for (i = 0; i < count; ++i) {
        const char *id = NULL;
        unsigned pos = list->pVtbl->Begin(list) + i;
        if (ADLX_FAILED(list->pVtbl->At_GPUList(list, pos, &rows[i].gpu)) || !rows[i].gpu) { fprintf(stderr, "adlx-gpu-enumeration-failed\n"); goto terminate; }
        if (ADLX_SUCCEEDED(rows[i].gpu->pVtbl->PNPString(rows[i].gpu, &id))) copy_bounded(rows[i].pnp, sizeof(rows[i].pnp), id);
        id = NULL; if (ADLX_SUCCEEDED(rows[i].gpu->pVtbl->VendorId(rows[i].gpu, &id))) copy_bounded(rows[i].vendor, sizeof(rows[i].vendor), id);
        id = NULL; if (ADLX_SUCCEEDED(rows[i].gpu->pVtbl->DeviceId(rows[i].gpu, &id))) copy_bounded(rows[i].device, sizeof(rows[i].device), id);
        if (ADLX_FAILED(perf->pVtbl->GetSupportedGPUMetrics(perf, rows[i].gpu, &rows[i].support))) rows[i].support = NULL;
        extra[i].vramSupportResult = extra[i].powerSupportResult = extra[i].presetSupportResult = ADLX_FAIL;
        if (!tuning) continue;
        extra[i].vramSupportResult = tuning->pVtbl->IsSupportedManualVRAMTuning(tuning, rows[i].gpu, &extra[i].vramSupported);
        if (ADLX_SUCCEEDED(extra[i].vramSupportResult) && extra[i].vramSupported &&
            ADLX_SUCCEEDED(tuning->pVtbl->GetManualVRAMTuning(tuning, rows[i].gpu, &extra[i].vramBase)) && extra[i].vramBase)
            extra[i].vramBase->pVtbl->QueryInterface(extra[i].vramBase, IID_IADLXManualVRAMTuning2(), (void**)&extra[i].vram);
        extra[i].powerSupportResult = tuning->pVtbl->IsSupportedManualPowerTuning(tuning, rows[i].gpu, &extra[i].powerSupported);
        if (ADLX_SUCCEEDED(extra[i].powerSupportResult) && extra[i].powerSupported &&
            ADLX_SUCCEEDED(tuning->pVtbl->GetManualPowerTuning(tuning, rows[i].gpu, &extra[i].powerBase)) && extra[i].powerBase)
            extra[i].powerBase->pVtbl->QueryInterface(extra[i].powerBase, IID_IADLXManualPowerTuning(), (void**)&extra[i].power);
        extra[i].presetSupportResult = tuning->pVtbl->IsSupportedPresetTuning(tuning, rows[i].gpu, &extra[i].presetSupported);
        if (ADLX_SUCCEEDED(extra[i].presetSupportResult) && extra[i].presetSupported &&
            ADLX_SUCCEEDED(tuning->pVtbl->GetPresetTuning(tuning, rows[i].gpu, &extra[i].presetBase)) && extra[i].presetBase)
            extra[i].presetBase->pVtbl->QueryInterface(extra[i].presetBase, IID_IADLXGPUPresetTuning(), (void**)&extra[i].preset);
    }
    for (tick = 0; tick < 10; ++tick) {
        for (i = 0; i < count; ++i) {
            sample_gpu(tick, i, &rows[i], perf);
            print_vram_extension(tick, i, &rows[i], &extra[i], perf, tuning);
        }
        if (tick + 1 < 10) Sleep(1000);
    }
    rc = 0;
terminate:
    for (i = 0; i < 8; ++i) {
        if (extra[i].vram) extra[i].vram->pVtbl->Release(extra[i].vram);
        if (extra[i].vramBase) extra[i].vramBase->pVtbl->Release(extra[i].vramBase);
        if (extra[i].power) extra[i].power->pVtbl->Release(extra[i].power);
        if (extra[i].powerBase) extra[i].powerBase->pVtbl->Release(extra[i].powerBase);
        if (extra[i].preset) extra[i].preset->pVtbl->Release(extra[i].preset);
        if (extra[i].presetBase) extra[i].presetBase->pVtbl->Release(extra[i].presetBase);
        if (rows[i].support) rows[i].support->pVtbl->Release(rows[i].support);
        if (rows[i].gpu) rows[i].gpu->pVtbl->Release(rows[i].gpu);
    }
    if (tuning) tuning->pVtbl->Release(tuning);
    if (perf) perf->pVtbl->Release(perf);
    if (list) list->pVtbl->Release(list);
    term();
done:
    if (lib) FreeLibrary(lib);
    return rc;
}
