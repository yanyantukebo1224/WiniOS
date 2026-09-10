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

// Terminfo / curses stubs for LLVM
int setupterm(char *term, int fildes, int *errret) { if (errret) *errret = -1; return -1; }
void *set_curterm(void *nterm) { return NULL; }
int del_curterm(void *oterm) { return 0; }
int tigetnum(char *capname) { return -1; }
