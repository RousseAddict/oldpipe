/*
 * ios5_start.S — ARM assembly, armv7 only (preprocessed with cpp)
 *
 * LC_MAIN did not exist before iOS 6, so a binary that has to launch on iOS 5
 * must carry LC_UNIXTHREAD instead, and dyld then jumps straight to a `start`
 * symbol rather than calling main itself. That symbol normally comes from
 * crt1.o, which modern iOS SDKs no longer ship — so we provide it.
 *
 * ld selects the LC_UNIXTHREAD form automatically when linked with
 * -ios_version_min 5.0, and resolves its default entry symbol `start` here.
 *
 * dyld hands control over with the stack laid out as:
 *     sp -> argc, argv[0..argc-1], NULL, envp[...], NULL, apple[...], NULL
 * so main is called as main(argc, argv, envp, apple) and its result is passed
 * to exit. This is the same sequence Apple's Csu start.s emits for ARM.
 *
 * The whole file is compiled out unless IOS5_TARGET is defined, so every other
 * target links exactly as it did before (LC_MAIN, entry at main).
 */

#if defined(IOS5_TARGET) && defined(__arm__) && !defined(__arm64__)

    .syntax unified
    .text
    .align  2
    .arm
    .globl  start
start:
    ldr     r0, [sp]            /* argc                                    */
    add     r1, sp, #4          /* argv                                    */
    add     r4, r0, #1
    add     r2, r1, r4, lsl #2  /* envp = argv + argc + 1 (past the NULL)  */
    bic     sp, sp, #7          /* AAPCS wants an 8-byte aligned stack     */
    mov     r3, r2
.Lscan:
    ldr     r4, [r3], #4        /* walk past envp; r3 then points at apple */
    cmp     r4, #0
    bne     .Lscan
    bl      _main
    b       _exit

#endif /* IOS5_TARGET && __arm__ && !__arm64__ */
