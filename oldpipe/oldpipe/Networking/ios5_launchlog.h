/*
 * ios5_launchlog.h — the launch trace's C core, shared by libS5 and the app.
 *
 * WHY C, AND WHY A HEADER
 * The thing being diagnosed is a crash that happens before any Swift runs, so the
 * recorder cannot itself be Swift. It also cannot allocate: it has to work from a
 * signal handler on a process whose heap may already be corrupt, where a malloc
 * would deadlock and record nothing. Everything here is therefore raw syscalls on
 * preallocated storage.
 *
 * It is a header because two separate Mach-O images need the same logic, and they
 * cannot share a symbol: libS5 is loaded as a dependency of libswiftCore, long
 * before the app image is initialised. Each image gets its own static copy, each
 * calls resolve() for itself, and they append to one file.
 *
 * ORDERING, WHICH IS THE WHOLE POINT
 * dyld loads every image and binds every non-lazy symbol, THEN runs initialisers
 * bottom-up (dependencies first), THEN jumps to the entry point. So:
 *
 *   libS5's constructor      first code of ours that can possibly run
 *   app image's constructor  every dylib initialiser, incl. the Swift runtime's, is done
 *   AppDelegate.init         UIApplicationMain got as far as building the delegate
 *   CrashLog.install()       first statement of didFinishLaunchingWithOptions
 *
 * Each missing marker names the interval that killed us. Nothing can be recorded
 * from inside the process if dyld fails to load or bind an image, because then no
 * initialiser runs at all — that case is only visible in dyld's stderr or the OS
 * crash report, and an empty log file is itself the signal that we are in it.
 *
 * iOS 6+ has no libS5, so there the app image's constructor is the first marker and
 * does the rotation itself. Every target gets the fatal-signal report below: on an
 * iPhone nobody can plug in, it is the only record a crash leaves.
 */
#ifndef IOS5_LAUNCHLOG_H
#define IOS5_LAUNCHLOG_H

#include <fcntl.h>
#include <unistd.h>
#include <stdlib.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <signal.h>
#include <pthread.h>
#include <sys/ucontext.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <dispatch/dispatch.h>

#define IOS5_LOG_REL      "/Documents/oldpipe-launch.log"
#define IOS5_LOG_REL_PREV "/Documents/oldpipe-launch-previous.log"

static char ios5_log_path[1024];
static int  ios5_log_ready;
static int  ios5_log_stderr_captured;   /* fd 2 IS the log: don't mirror into it */

/* a + b into out, by hand rather than strlcpy/strlcat: the iOS 6+ builds keep
   _FORTIFY_SOURCE, which turns those into ___strlcpy_chk / ___strlcat_chk, and
   neither iOS 5's libSystem nor iOS 6's exports them. 0 if it does not fit. */
static int ios5_join(char *out, size_t size, const char *a, const char *b) {
    size_t i = 0;
    for (; *a; a++) { if (i + 1 >= size) return 0; out[i++] = *a; }
    for (; *b; b++) { if (i + 1 >= size) return 0; out[i++] = *b; }
    out[i] = 0;
    return 1;
}

/* Probes a candidate path by actually opening it. O_CREAT creates the FILE but
   never the DIRECTORY, so a missing Documents/ fails here silently — which is
   precisely how an earlier build managed to produce no log at all. */
static int ios5_log_try(const char *base, const char *rel) {
    int fd;
    if (!ios5_join(ios5_log_path, sizeof(ios5_log_path), base, rel)) return 0;
    fd = open(ios5_log_path, O_WRONLY | O_APPEND | O_CREAT, 0644);
    if (fd < 0) return 0;
    close(fd);
    return 1;
}

__attribute__((unused))
static void ios5_log_resolve(void) {
    /* HOME is the sandbox container; dyld has the environment set up by the time
       any initialiser runs, so this is safe at the earliest possible moment. */
    const char *home = getenv("HOME");
    ios5_log_ready = 0;
    if (!home) return;
    /* Documents/ first (visible over USB file sharing), container root second —
       that one always exists, including when running as root from a shell. */
    if (ios5_log_try(home, IOS5_LOG_REL))      { ios5_log_ready = 1; return; }
    if (ios5_log_try(home, "/oldpipe-launch.log")) { ios5_log_ready = 1; return; }
}

__attribute__((unused))
static void ios5_log_write(const char *msg, size_t n) {
    int fd;
    /* Mirror to stderr unconditionally. Launching the binary from an SSH shell is
       how this bug is actually being chased, and there stderr is the whole point:
       it needs no container, no sandbox and no file browser. On device it costs
       nothing and may be picked up by the console log. */
    if (!ios5_log_stderr_captured) (void)write(2, msg, n);
    if (!ios5_log_ready) return;
    fd = open(ios5_log_path, O_WRONLY | O_APPEND | O_CREAT, 0644);
    if (fd < 0) return;
    (void)write(fd, msg, n);
    fsync(fd);          /* unflushed is lost when the process dies, and the last
                           line written is exactly the answer we are after */
    close(fd);
}

__attribute__((unused))
static void ios5_log(const char *msg) { ios5_log_write(msg, strlen(msg)); }

/* Moves the previous run aside. Called once, by the earliest constructor, because
   by the time anyone reads the log the user has necessarily relaunched and this
   run would otherwise have overwritten the crashing one. */
__attribute__((unused))
static void ios5_log_rotate(void) {
    const char *home = getenv("HOME");
    char prev[1024];
    if (!home || !ios5_log_ready) return;
    if (!ios5_join(prev, sizeof(prev), home, IOS5_LOG_REL_PREV)) return;
    unlink(prev);
    rename(ios5_log_path, prev);   /* harmless no-op on the very first launch */
}

/* Points stderr at the log, so what the Swift runtime prints just before it traps
   ("Fatal error: Index out of range") lands under our own markers. Only when stderr
   is not a terminal: launched from an SSH shell it is the screen, where it belongs. */
__attribute__((unused))
static void ios5_log_capture_stderr(void) {
    int fd;
    if (!ios5_log_ready || isatty(2)) return;
    fd = open(ios5_log_path, O_WRONLY | O_APPEND | O_CREAT, 0644);
    if (fd < 0) return;
    if (dup2(fd, 2) >= 0) ios5_log_stderr_captured = 1;
    close(fd);
}

/* ---- Fatal-signal report ----------------------------------------------------
   Async-signal-safe: open/write/fsync/close are on the safe list, every line is
   built by hand in a stack buffer rather than with snprintf, and the rest is plain
   reads of memory that stays mapped for the life of the process — dyld's image
   list, the Mach-O headers, the main executable's symbol table, the stack. */

typedef struct { char b[512]; size_t n; } ios5_line;

static void ios5_put(ios5_line *l, const char *s) {
    while (*s && l->n < sizeof(l->b) - 1) l->b[l->n++] = *s++;
}

static void ios5_put_hex(ios5_line *l, uintptr_t v) {
    static const char d[] = "0123456789abcdef";
    char t[2 * sizeof(uintptr_t)];
    int k = 0;
    do { t[k++] = d[v & 15]; v >>= 4; } while (v && k < (int)sizeof(t));
    ios5_put(l, "0x");
    while (k > 0 && l->n < sizeof(l->b) - 1) l->b[l->n++] = t[--k];
}

static void ios5_put_dec(ios5_line *l, long v) {
    char t[24];
    int k = 0;
    unsigned long u = v < 0 ? (unsigned long)-v : (unsigned long)v;
    if (v < 0) ios5_put(l, "-");
    do { t[k++] = (char)('0' + u % 10); u /= 10; } while (u && k < (int)sizeof(t));
    while (k > 0 && l->n < sizeof(l->b) - 1) l->b[l->n++] = t[--k];
}

static void ios5_emit(int fd, ios5_line *l) {
    l->b[l->n++] = '\n';
    if (!ios5_log_stderr_captured) (void)write(2, l->b, l->n);
    if (fd >= 0) (void)write(fd, l->b, l->n);
    l->n = 0;
}

/* The segment named seg, found by walking the load commands in place. */
static int ios5_segment(const struct mach_header *mh, const char *seg,
                        uintptr_t *vmaddr, uintptr_t *vmsize, uintptr_t *fileoff) {
    const struct load_command *lc;
    uint32_t i;
    if (mh->magic == MH_MAGIC_64) lc = (const struct load_command *)((const char *)mh + sizeof(struct mach_header_64));
    else if (mh->magic == MH_MAGIC) lc = (const struct load_command *)((const char *)mh + sizeof(struct mach_header));
    else return 0;
    for (i = 0; i < mh->ncmds; i++) {
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *s = (const struct segment_command_64 *)lc;
            if (memcmp(s->segname, seg, strlen(seg) + 1) == 0) {
                *vmaddr = (uintptr_t)s->vmaddr; *vmsize = (uintptr_t)s->vmsize; *fileoff = (uintptr_t)s->fileoff;
                return 1;
            }
        } else if (lc->cmd == LC_SEGMENT) {
            const struct segment_command *s = (const struct segment_command *)lc;
            if (memcmp(s->segname, seg, strlen(seg) + 1) == 0) {
                *vmaddr = s->vmaddr; *vmsize = s->vmsize; *fileoff = s->fileoff;
                return 1;
            }
        }
        lc = (const struct load_command *)((const char *)lc + lc->cmdsize);
    }
    return 0;
}

/* Nearest symbol at or below addr, from the executable's own symbol table: the
   shipped binary keeps its local symbols, so a frame of ours names its function
   here and the report needs no matching binary to be read. System images are not
   looked up — the shared cache carries no local symbols — and get image + offset. */
static const char *ios5_symbol(const struct mach_header *mh, intptr_t slide, uintptr_t addr, uintptr_t *at) {
    const struct load_command *lc;
    const struct symtab_command *st = 0;
    uintptr_t le_addr, le_size, le_off, base, best = 0;
    const char *strs, *name = 0;
    uint32_t i;
    if (!ios5_segment(mh, "__LINKEDIT", &le_addr, &le_size, &le_off)) return 0;
    lc = (const struct load_command *)((const char *)mh +
         (mh->magic == MH_MAGIC_64 ? sizeof(struct mach_header_64) : sizeof(struct mach_header)));
    for (i = 0; i < mh->ncmds && !st; i++) {
        if (lc->cmd == LC_SYMTAB) st = (const struct symtab_command *)lc;
        lc = (const struct load_command *)((const char *)lc + lc->cmdsize);
    }
    if (!st) return 0;
    base = (uintptr_t)slide + le_addr - le_off;   /* file offset -> memory */
    strs = (const char *)(base + st->stroff);
    for (i = 0; i < st->nsyms; i++) {
        uint8_t type; uint32_t strx; uintptr_t value;
        if (mh->magic == MH_MAGIC_64) {
            const struct nlist_64 *s = (const struct nlist_64 *)(base + st->symoff) + i;
            type = s->n_type; strx = s->n_un.n_strx; value = (uintptr_t)s->n_value;
        } else {
            const struct nlist *s = (const struct nlist *)(base + st->symoff) + i;
            type = s->n_type; strx = s->n_un.n_strx; value = s->n_value;
        }
        if ((type & N_STAB) || (type & N_TYPE) != N_SECT || strx >= st->strsize) continue;
        value += (uintptr_t)slide;
        if (value <= addr && value > best) { best = value; name = strs + strx; }
    }
    *at = best;
    return name;
}

/* "0x0009a3c1  oldpipe +0x96c1  _$s7oldpipe11StreamProxy... +0x3c" */
static void ios5_put_frame(ios5_line *l, uintptr_t addr) {
    uint32_t i, n = _dyld_image_count();
    ios5_put_hex(l, addr);
    for (i = 0; i < n; i++) {
        const struct mach_header *mh = _dyld_get_image_header(i);
        uintptr_t vmaddr, vmsize, fileoff, start = (uintptr_t)mh;
        if (!mh || !ios5_segment(mh, "__TEXT", &vmaddr, &vmsize, &fileoff)) continue;
        if (addr >= start && addr - start < vmsize) {
            const char *p = _dyld_get_image_name(i), *base = p;
            if (p) for (; *p; p++) if (*p == '/') base = p + 1;
            ios5_put(l, "  ");
            ios5_put(l, base ? base : "?");
            ios5_put(l, " +");
            ios5_put_hex(l, addr - start);
            if (mh->filetype == MH_EXECUTE) {
                uintptr_t at = 0;
                const char *sym = ios5_symbol(mh, _dyld_get_image_vmaddr_slide(i), addr, &at);
                /* No function of ours is 64 KB long (the widest gap between two is ~28 KB):
                   a farther "nearest" symbol means the table was stripped — the iOS 5
                   build's is — and naming it would only mislead. */
                if (sym && addr - at < 0x10000) {
                    ios5_put(l, "  "); ios5_put(l, sym); ios5_put(l, " +"); ios5_put_hex(l, addr - at);
                }
            }
            return;
        }
    }
    ios5_put(l, "  ?");
}

static const char *ios5_signame(int sig) {
    switch (sig) {
    case SIGSEGV: return "SIGSEGV (bad memory access)";
    case SIGBUS:  return "SIGBUS (bad memory access)";
    case SIGILL:  return "SIGILL (bad instruction)";
    case SIGTRAP: return "SIGTRAP (Swift runtime trap: nil unwrap, bad index, failed cast...)";
    case SIGABRT: return "SIGABRT (abort)";
    case SIGFPE:  return "SIGFPE";
    default:      return "?";
    }
}

/* The thread's saved frame-pointer chain: each frame stores {caller's fp, return
   address} at fp, on armv7 (r7) and arm64 (x29) alike. Every fp is checked against
   the thread's stack bounds before it is read, so a corrupt chain ends the walk
   instead of faulting inside the handler. */
static void ios5_walk(int fd, uintptr_t fp) {
    pthread_t self = pthread_self();
    uintptr_t hi = (uintptr_t)pthread_get_stackaddr_np(self);
    uintptr_t size = (uintptr_t)pthread_get_stacksize_np(self);
    ios5_line l;
    int i;
    /* The main thread's reported size can be short of the 1 MB it really has. */
    if (pthread_main_np() && size < 1024 * 1024) size = 1024 * 1024;
    l.n = 0;
    for (i = 1; i <= 40; i++) {
        uintptr_t next, ret;
        if (fp < hi - size || fp + 2 * sizeof(uintptr_t) > hi || (fp & (sizeof(uintptr_t) - 1))) break;
        next = ((const uintptr_t *)fp)[0];
        ret  = ((const uintptr_t *)fp)[1];
        if (!ret) break;
        ios5_put(&l, "  #"); ios5_put_dec(&l, i); ios5_put(&l, " ");
        ios5_put_frame(&l, ret);
        ios5_emit(fd, &l);
        if (next <= fp) break;
        fp = next;
    }
}

__attribute__((unused))
static void ios5_log_signal(int sig, siginfo_t *info, void *ctx) {
    ucontext_t *uc = (ucontext_t *)ctx;
    uintptr_t pc = 0, lr = 0, fp = 0;
    int fd = ios5_log_ready ? open(ios5_log_path, O_WRONLY | O_APPEND | O_CREAT, 0644) : -1;
    ios5_line l;

    /* Default first: a second fault inside this handler then ends the process
       instead of recursing, and the lines already written stay written. */
    signal(sig, SIG_DFL);

#if defined(__arm64__)
    if (uc && uc->uc_mcontext) {
        pc = (uintptr_t)__darwin_arm_thread_state64_get_pc(uc->uc_mcontext->__ss);
        lr = (uintptr_t)__darwin_arm_thread_state64_get_lr(uc->uc_mcontext->__ss);
        fp = (uintptr_t)__darwin_arm_thread_state64_get_fp(uc->uc_mcontext->__ss);
    }
#elif defined(__arm__)
    if (uc && uc->uc_mcontext) {
        pc = uc->uc_mcontext->__ss.__pc;
        lr = uc->uc_mcontext->__ss.__lr;
        fp = uc->uc_mcontext->__ss.__r[7];
    }
#endif

    l.n = 0;
    ios5_put(&l, "\n*** FATAL SIGNAL ");
    ios5_put_dec(&l, sig);
    ios5_put(&l, " ***  ");
    ios5_put(&l, ios5_signame(sig));
    ios5_put(&l, pthread_main_np() ? ", main thread" : ", background thread");
    ios5_emit(fd, &l);
    if (info) {
        ios5_put(&l, "code "); ios5_put_dec(&l, info->si_code);
        ios5_put(&l, "  fault address "); ios5_put_hex(&l, (uintptr_t)info->si_addr);
        if (info->si_pid) { ios5_put(&l, "  sent by pid "); ios5_put_dec(&l, info->si_pid); }
        ios5_emit(fd, &l);
    }
    ios5_put(&l, "pc "); ios5_put_frame(&l, pc); ios5_emit(fd, &l);
    ios5_put(&l, "lr "); ios5_put_frame(&l, lr); ios5_emit(fd, &l);
    if (fd >= 0) fsync(fd);

    ios5_walk(fd, fp);
    if (fd >= 0) fsync(fd);

    /* Last, as the one read that trusts the crashing thread's own state: which
       queue it was serving names the subsystem when the frames alone do not. */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    {
        const char *q = dispatch_queue_get_label(dispatch_get_current_queue());
        ios5_put(&l, "queue: ");
        ios5_put(&l, q ? q : "?");
        ios5_emit(fd, &l);
    }
#pragma clang diagnostic pop
    if (fd >= 0) { fsync(fd); close(fd); }

    /* Always re-raised, never just returned from. Returning would let a real fault
       re-run its instruction and die at the true site, but iOS 5 gives a kill -SEGV
       a stale fault code and no sender pid, so a kill cannot be told from a fault —
       and returning from a kill left the process running. The true site is already
       in the lines above. Blocked while we are in here, the signal is delivered
       with the default action the moment this handler returns. */
    raise(sig);
}

__attribute__((unused))
static void ios5_log_arm(void) {
    int sigs[] = { SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGABRT, SIGTRAP };
    struct sigaction sa;
    unsigned i;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = ios5_log_signal;
    sa.sa_flags = SA_SIGINFO;
    sigemptyset(&sa.sa_mask);
    (void)_dyld_image_count();   /* bind dyld's entry points now, not inside a crash */
    for (i = 0; i < sizeof(sigs) / sizeof(sigs[0]); i++) sigaction(sigs[i], &sa, 0);
}

#endif /* IOS5_LAUNCHLOG_H */
