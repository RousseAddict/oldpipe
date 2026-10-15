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
 */
#ifndef IOS5_LAUNCHLOG_H
#define IOS5_LAUNCHLOG_H

#include <fcntl.h>
#include <unistd.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <signal.h>

#define IOS5_LOG_REL      "/Documents/oldpipe-launch.log"
#define IOS5_LOG_REL_PREV "/Documents/oldpipe-launch-previous.log"

static char ios5_log_path[1024];
static int  ios5_log_ready;

__attribute__((unused))
static void ios5_log_resolve(void) {
    /* HOME is the sandbox container; dyld has the environment set up by the time
       any initialiser runs, so this is safe at the earliest possible moment. */
    const char *home = getenv("HOME");
    if (!home) { ios5_log_ready = 0; return; }
    if (strlen(home) + sizeof(IOS5_LOG_REL) >= sizeof(ios5_log_path)) return;
    strlcpy(ios5_log_path, home, sizeof(ios5_log_path));
    strlcat(ios5_log_path, IOS5_LOG_REL, sizeof(ios5_log_path));
    ios5_log_ready = 1;
}

__attribute__((unused))
static void ios5_log_write(const char *msg, size_t n) {
    int fd;
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
    if (strlen(home) + sizeof(IOS5_LOG_REL_PREV) >= sizeof(prev)) return;
    strlcpy(prev, home, sizeof(prev));
    strlcat(prev, IOS5_LOG_REL_PREV, sizeof(prev));
    unlink(prev);
    rename(ios5_log_path, prev);   /* harmless no-op on the very first launch */
}

/* Async-signal-safe: open/write/fsync/close and raise are all on the safe list,
   and the integer is formatted by hand into a stack buffer rather than snprintf. */
__attribute__((unused))
static void ios5_log_signal(int sig) {
    static const char pre[]  = "\n*** FATAL SIGNAL ";
    static const char post[] = " ***\n";
    char digits[8];
    int i = 0;

    if (sig <= 0) {
        digits[i++] = '0';
    } else {
        char tmp[8];
        int k = 0, n = sig;
        while (n > 0 && k < (int)sizeof(tmp)) { tmp[k++] = (char)('0' + n % 10); n /= 10; }
        while (k > 0) digits[i++] = tmp[--k];
    }

    if (ios5_log_ready) {
        int fd = open(ios5_log_path, O_WRONLY | O_APPEND | O_CREAT, 0644);
        if (fd >= 0) {
            (void)write(fd, pre, sizeof(pre) - 1);
            (void)write(fd, digits, (size_t)i);
            (void)write(fd, post, sizeof(post) - 1);
            fsync(fd);
            close(fd);
        }
    }
    /* Restore the default disposition and re-raise, so the OS still writes its own
       crash report for anyone who can read /var/mobile/Library/Logs/CrashReporter. */
    signal(sig, SIG_DFL);
    raise(sig);
}

__attribute__((unused))
static void ios5_log_arm(void) {
    int sigs[] = { SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGABRT, SIGTRAP };
    unsigned i;
    for (i = 0; i < sizeof(sigs) / sizeof(sigs[0]); i++) signal(sigs[i], ios5_log_signal);
}

#endif /* IOS5_LAUNCHLOG_H */
