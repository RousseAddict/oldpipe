// libS5 — libSystem compatibility shim for iOS 5.
//
// Swift 5.1.5's libswiftCore imports the compiler-rt generic atomic helpers and
// __mulodi4. iOS 5's libSystem does not export them, so libswiftCore fails to bind
// at load time. This dylib re-exports libSystem (everything iOS 5 does have passes
// straight through) and adds the four missing symbols; libswiftCore's dependency on
// /usr/lib/libSystem.B.dylib is then repointed here with install_name_tool -change,
// which preserves its two-level-namespace ordinals.
//
// The __atomic_* names are clang builtins, so they cannot be declared normally in C
// (conflicting-signature error). The asm() label on the forward declaration emits the
// exact symbol while keeping an ordinary C identifier for the definition.

#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <libkern/OSAtomic.h>
#include "ios5_launchlog.h"

// Address-hashed lock pool. The generic (non-inlined) compiler-rt atomics are always
// allowed to be lock-based; correctness only requires that every access to a given
// object takes the same lock.
#define S5_NLOCKS 64
static OSSpinLock s5_locks[S5_NLOCKS];

static OSSpinLock *s5_lock_for(const void *p) {
    uintptr_t a = (uintptr_t)p;
    return &s5_locks[((a >> 4) ^ (a >> 10)) & (S5_NLOCKS - 1)];
}

void s5_atomic_load(size_t size, const void *src, void *dest, int model) __asm__("___atomic_load");
void s5_atomic_load(size_t size, const void *src, void *dest, int model) {
    (void)model;
    OSSpinLock *l = s5_lock_for(src);
    OSSpinLockLock(l);
    memcpy(dest, src, size);
    OSSpinLockUnlock(l);
}

void s5_atomic_store(size_t size, void *dest, const void *src, int model) __asm__("___atomic_store");
void s5_atomic_store(size_t size, void *dest, const void *src, int model) {
    (void)model;
    OSSpinLock *l = s5_lock_for(dest);
    OSSpinLockLock(l);
    memcpy(dest, src, size);
    OSSpinLockUnlock(l);
}

int s5_atomic_compare_exchange(size_t size, void *ptr, void *expected, void *desired,
                               int success, int failure) __asm__("___atomic_compare_exchange");
int s5_atomic_compare_exchange(size_t size, void *ptr, void *expected, void *desired,
                               int success, int failure) {
    (void)success; (void)failure;
    OSSpinLock *l = s5_lock_for(ptr);
    OSSpinLockLock(l);
    int matched;
    if (memcmp(ptr, expected, size) == 0) {
        memcpy(ptr, desired, size);
        matched = 1;
    } else {
        memcpy(expected, ptr, size);   // report the observed value, per the ABI
        matched = 0;
    }
    OSSpinLockUnlock(l);
    return matched;
}

// Signed 64x64 multiply with overflow flag (compiler-rt __mulodi4).
long long s5_mulodi4(long long a, long long b, int *overflow) __asm__("___mulodi4");
long long s5_mulodi4(long long a, long long b, int *overflow) {
    enum { N = 64 };
    const long long MIN = (long long)1 << (N - 1);
    const long long MAX = ~MIN;
    *overflow = 0;
    long long result = (long long)((unsigned long long)a * (unsigned long long)b);
    if (a == MIN) {
        if (b != 0 && b != 1) *overflow = 1;
        return result;
    }
    if (b == MIN) {
        if (a != 0 && a != 1) *overflow = 1;
        return result;
    }
    long long sa = a >> (N - 1), abs_a = (a ^ sa) - sa;
    long long sb = b >> (N - 1), abs_b = (b ^ sb) - sb;
    if (abs_a < 2 || abs_b < 2) return result;
    if (sa == sb) {
        if (abs_a > MAX / abs_b) *overflow = 1;
    } else {
        if (abs_a > MIN / -abs_b) *overflow = 1;
    }
    return result;
}


/*
 * The first code of ours that can run at all.
 *
 * libS5 is a dependency of libswiftCore, and dyld runs initialisers
 * dependencies-first, so this constructor precedes the Swift runtime's own
 * initialisers and the app image's. That makes it the right place to rotate the
 * log and to arm the signal handlers: everything after this point is covered,
 * including the Swift runtime initialisation that CrashLog could never see.
 */
__attribute__((constructor))
static void s5_launchlog_boot(void) {
    ios5_log_resolve();
    ios5_log_rotate();
    ios5_log_arm();
    ios5_log("=== oldpipe launch ===\n");
    ios5_log("1. libS5 constructor: dyld loaded and bound every image\n");
}
