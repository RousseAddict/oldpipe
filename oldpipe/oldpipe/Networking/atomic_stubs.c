/*
 * atomic_stubs.c
 *
 * ___atomic_is_lock_free lives in atomic_stubs.S (assembly, because Clang
 * treats that name as a builtin with a conflicting signature).
 *
 * Everything below, up to the launch-log constructor at the end, exists only
 * for the iOS 5 build. Linking with
 * -ios_version_min 5.0 stops ld resolving the compiler-rt atomic helpers from
 * libSystem — iOS 5's libSystem genuinely does not export them — so OpenSSL's
 * threads_pthread.o, which calls them for its 64-bit counters, has nothing to
 * bind to. We supply them here instead.
 *
 * All of them serialise through a small OSSpinLock table rather than LDREXD /
 * STREXD: LDREXD faults unless the address is 8-byte aligned, and OpenSSL's
 * heap-allocated uint64_t fields are only guaranteed 4-byte alignment on
 * ARMv7. That is the same reasoning behind ___atomic_is_lock_free returning 0
 * for size 8, and it keeps these helpers consistent with it.
 *
 * The names are Clang builtins, so each one is defined under an ordinary C
 * identifier carrying an asm() label that emits the real symbol.
 */

#ifdef IOS5_TARGET

#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <libkern/OSAtomic.h>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

#define NLOCKS 64
static OSSpinLock locks[NLOCKS];

static OSSpinLock *lock_for(const void *p) {
    uintptr_t a = (uintptr_t)p;
    return &locks[((a >> 4) ^ (a >> 10)) & (NLOCKS - 1)];
}

void ios5_atomic_load(size_t size, const void *src, void *dest, int model) __asm__("___atomic_load");
void ios5_atomic_load(size_t size, const void *src, void *dest, int model) {
    (void)model;
    OSSpinLock *l = lock_for(src);
    OSSpinLockLock(l);
    memcpy(dest, src, size);
    OSSpinLockUnlock(l);
}

void ios5_atomic_store(size_t size, void *dest, const void *src, int model) __asm__("___atomic_store");
void ios5_atomic_store(size_t size, void *dest, const void *src, int model) {
    (void)model;
    OSSpinLock *l = lock_for(dest);
    OSSpinLockLock(l);
    memcpy(dest, src, size);
    OSSpinLockUnlock(l);
}

uint64_t ios5_atomic_load_8(const volatile void *src, int model) __asm__("___atomic_load_8");
uint64_t ios5_atomic_load_8(const volatile void *src, int model) {
    (void)model;
    OSSpinLock *l = lock_for((const void *)src);
    OSSpinLockLock(l);
    uint64_t v = *(const volatile uint64_t *)src;
    OSSpinLockUnlock(l);
    return v;
}

/* Each returns the value held BEFORE the update, per the compiler-rt ABI. */
#define FETCH_OP(suffix, op)                                                      \
    uint64_t ios5_atomic_fetch_##suffix(volatile void *ptr, uint64_t val,         \
                                        int model) __asm__("___atomic_fetch_" #suffix); \
    uint64_t ios5_atomic_fetch_##suffix(volatile void *ptr, uint64_t val,         \
                                        int model) {                              \
        (void)model;                                                              \
        volatile uint64_t *p = (volatile uint64_t *)ptr;                          \
        OSSpinLock *l = lock_for((const void *)ptr);                              \
        OSSpinLockLock(l);                                                        \
        uint64_t old = *p;                                                        \
        *p = old op val;                                                          \
        OSSpinLockUnlock(l);                                                      \
        return old;                                                               \
    }

FETCH_OP(add_8, +)
FETCH_OP(sub_8, -)
FETCH_OP(and_8, &)
FETCH_OP(or_8,  |)

/*
 * __mulodi4 — signed 64-bit multiply with overflow flag. Clang emits a call to
 * it for Swift's overflow-checked Int64 arithmetic. It normally comes from
 * libSystem's compiler-rt, but iOS 5 predates it, so the import would fail to
 * bind at launch (it is a STRONG undefined, unlike the weak
 * ___darwin_check_fd_set_overflow next to it). Defining it here resolves the
 * call inside the app binary and removes the import entirely.
 *
 * Body is the standard compiler-rt algorithm: multiply in unsigned to dodge
 * the UB, then detect overflow from the magnitudes and the sign agreement.
 */
int64_t ios5_mulodi4(int64_t a, int64_t b, int *overflow) __asm__("___mulodi4");
int64_t ios5_mulodi4(int64_t a, int64_t b, int *overflow) {
    const int N = 64;
    const int64_t MIN = (int64_t)1 << (N - 1);
    const int64_t MAX = ~MIN;
    *overflow = 0;
    int64_t result = (int64_t)((uint64_t)a * (uint64_t)b);
    if (a == MIN) {
        if (b != 0 && b != 1) *overflow = 1;
        return result;
    }
    if (b == MIN) {
        if (a != 0 && a != 1) *overflow = 1;
        return result;
    }
    int64_t sa = a >> (N - 1);
    int64_t abs_a = (a ^ sa) - sa;
    int64_t sb = b >> (N - 1);
    int64_t abs_b = (b ^ sb) - sb;
    if (abs_a < 2 || abs_b < 2) return result;
    if (sa == sb) {
        if (abs_a > MAX / abs_b) *overflow = 1;
    } else {
        if (abs_a > MIN / -abs_b) *overflow = 1;
    }
    return result;
}


/*
 * __program_vars — the section crt1.o would have given us.
 *
 * Linking with -ios_version_min 5.0 emits LC_UNIXTHREAD instead of LC_MAIN and
 * demands a `start` symbol, and SDK 15.2 ships no crt1.o for iOS 5, so
 * ios5_start.S replaces it. crt1.o does one more thing we did not replace: it
 * emits __DATA,__program_vars, a struct of pointers through which dyld publishes
 * argc, argv, environ and the program name to the rest of the process.
 *
 * Without it dyld has nowhere to write them. It falls back to looking up
 * _NXArgc / _NXArgv / _environ / ___progname by name in the executable, and we
 * defined none of those either, so `environ` stays null. libdyld's
 * _NSGetEnviron() hands out a pointer to this very struct's environPtr, so
 * everything downstream that reads the environment reads null — including
 * libobjc, whose _objc_init starts by walking environ in environ_init() to pick
 * up the OBJC_* settings. That is a null dereference inside the ObjC runtime's
 * own initialiser, before a single line of app code, which is exactly the crash
 * we chased: it also explains why OBJC_PRINT_IMAGES produced no output at all,
 * since libobjc died at the moment it tried to read its own environment.
 *
 * Invisible on iOS 6+: those builds use LC_MAIN, where dyld sets the program
 * vars up itself and never consults this section.
 *
 * The variables are static on purpose. dyld writes through the pointers held
 * here, and nothing needs to find them by name once the section exists, so
 * keeping them private avoids colliding with libSystem's own `environ`
 * declaration. Layout must match dyld's ProgramVars exactly: five pointers,
 * 20 bytes on 32-bit, which is what zirk-a's working binary carries.
 */

/* Canonical names, deliberately NOT static. dyld on this vintage resolves the
   program vars by looking these four symbols up BY NAME in the executable, so
   the privately-named statics this used to carry left getenv() returning null:
   environ was never published, which silently disabled every OBJC_PRINT_*
   diagnostic we tried AND our own launch logger, which calls getenv("HOME").
   crt1.o defines them exactly like this, and zirk-a's working binary exports
   _NXArgc / _NXArgv / _environ / ___progname too. */
/* visibility("default") is required, not decorative: Release sets
   GCC_SYMBOLS_PRIVATE_EXTERN, which would make these local symbols (nm "s")
   and invisible to dyld's by-name lookup. zirk-a's binary exports them as
   external ("S"), and we need to match that for the fallback path to work. */
#define IOS5_EXPORT __attribute__((visibility("default"), used))

IOS5_EXPORT int NXArgc = 0;
IOS5_EXPORT const char **NXArgv = 0;
IOS5_EXPORT char **environ = 0;     /* type matches unistd.h's declaration */
IOS5_EXPORT const char *__progname = 0;

extern const struct mach_header _mh_execute_header;

struct ios5_program_vars {
    const void   *mh;
    int          *NXArgcPtr;
    const char ***NXArgvPtr;
    const char ***environPtr;
    const char  **prognamePtr;
};

__attribute__((used, section("__DATA,__program_vars")))
static const struct ios5_program_vars ios5_pvars = {
    &_mh_execute_header,
    &NXArgc,
    &NXArgv,
    (const char ***)&environ,
    &__progname,
};

#endif /* IOS5_TARGET */

/*
 * Second checkpoint: the app image's own initialiser, on every target.
 *
 * Reaching here means every dependent dylib loaded, bound AND ran its
 * initialisers without dying — the Swift runtime's included. If marker 1 is in
 * the log and this one is not, the fault is in that interval.
 *
 * iOS 6+ has no libS5, so this is the first code of ours there: it rotates the
 * log itself, and from here on a crash on any target leaves its signal, frames
 * and queue in the log instead of nothing.
 */
#include "ios5_launchlog.h"

__attribute__((constructor))
static void ios5_app_image_init(void) {
    const char *home;
    ios5_log_resolve();
#ifndef IOS5_TARGET
    ios5_log_rotate();
    ios5_log("=== oldpipe launch ===\n");
#endif
    ios5_log_capture_stderr();
    ios5_log_arm();     /* re-arm against this image; idempotent */
    ios5_log("2. app image constructor: all dylib initialisers completed\n");
    home = getenv("HOME");
    if (home) {         /* record the container so the log can be found again */
        ios5_log("   container: ");
        ios5_log(home);
        ios5_log("\n");
    }
}
