/*
 * atomic_stubs.S — ARM assembly, armv7 only (preprocessed with cpp)
 *
 * Provides ___atomic_is_lock_free (Mach-O symbol for C's __atomic_is_lock_free).
 *
 * OpenSSL 3.4.x calls __atomic_is_lock_free at runtime in threads_pthread.o
 * to decide whether 64-bit (8-byte) atomics are lock-free.  The compiler
 * runtime normally provides this, but it is not linked for iOS device targets.
 *
 * We return 1 only for sizes <= 4 (LDREX/STREX, safely lock-free on ARMv7).
 * For size 8 we return 0, forcing OpenSSL to take the CRYPTO_RWLOCK mutex
 * path instead of emitting LDREXD/STREXD inline assembly.  LDREXD requires
 * strict 8-byte alignment; OpenSSL internal uint64_t fields in heap-allocated
 * structs may not satisfy that requirement, causing an alignment fault.
 * The mutex path is always correct and the performance difference is negligible
 * for TLS handshake use.
 *
 * Using assembly avoids the C type-system conflict with Clang's builtin
 * declaration of __atomic_is_lock_free.
 */

#if defined(__arm__) && !defined(__arm64__)

    .syntax unified
    .text
    .align  2
    .globl  ___atomic_is_lock_free
    .thumb
    .thumb_func
___atomic_is_lock_free:
    /* r0 = size_t size, r1 = void *ptr (ignored)
       Returns int: 1 if size <= 4 (lock-free via LDREX/STREX), 0 otherwise */
    CMP     r0, #4
    BHI     .Lno
    MOV     r0, #1
    BX      lr
.Lno:
    MOV     r0, #0
    BX      lr

#endif /* __arm__ && !__arm64__ */
