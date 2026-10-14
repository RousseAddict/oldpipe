/*
 * atomic_stubs.c
 *
 * ___atomic_is_lock_free lives in atomic_stubs.S (assembly, because Clang
 * treats that name as a builtin with a conflicting signature).
 *
 * Everything below exists only for the iOS 5 build. Linking with
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

#endif /* IOS5_TARGET */
