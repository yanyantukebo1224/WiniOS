// wine_stubs.c - Provide missing symbols for Wine on iOS

#include <CoreFoundation/CoreFoundation.h>

// Wine build version string (normally generated at compile time)
const char wine_build[] = "wine-10.0-ios";

// IOPowerSources stubs - not available on iOS
CFTypeRef IOPSCopyPowerSourcesInfo(void) { return NULL; }
CFArrayRef IOPSCopyPowerSourcesList(CFTypeRef blob) { (void)blob; return NULL; }
CFDictionaryRef IOPSGetPowerSourceDescription(CFTypeRef blob, CFTypeRef ps) {
    (void)blob; (void)ps; return NULL;
}

// Wineserver debug dump stubs
void ios_dump_msg_queues(void) {}
void ios_dump_stuck_waits(void) {}

// Wine Unixlib weak stubs
__attribute__((weak)) const void *dwrite_unix_call_funcs = NULL;
__attribute__((weak)) int win32u_unix_lib_init(void) { return 0; }
