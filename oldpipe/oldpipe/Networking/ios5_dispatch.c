/* ios5_dispatch.c — see ios5_dispatch.h for why this exists. */
#include "ios5_dispatch.h"

#ifdef IOS5_TARGET

#include <dispatch/dispatch.h>

void *ios5_q_create(const char *label, int concurrent) {
    /* DISPATCH_QUEUE_CONCURRENT is iOS 5.0, so both kinds are available. The
       attr argument is the only part of DispatchQueue.init that Swift's overlay
       would have reached for a newer API with (qos and autoreleaseFrequency are
       iOS 8 and iOS 10), and we simply never pass those. */
    return dispatch_queue_create(label, concurrent ? DISPATCH_QUEUE_CONCURRENT
                                                   : DISPATCH_QUEUE_SERIAL);
}

void *ios5_q_main(void) { return dispatch_get_main_queue(); }

void ios5_q_async(void *queue, void (*fn)(void *), void *ctx) {
    dispatch_async_f((dispatch_queue_t)queue, ctx, fn);
}

void ios5_q_sync(void *queue, void (*fn)(void *), void *ctx) {
    dispatch_sync_f((dispatch_queue_t)queue, ctx, fn);
}

void *ios5_sem_create(long value) { return dispatch_semaphore_create(value); }
void  ios5_sem_wait(void *sem) { dispatch_semaphore_wait((dispatch_semaphore_t)sem, DISPATCH_TIME_FOREVER); }
void  ios5_sem_signal(void *sem) { dispatch_semaphore_signal((dispatch_semaphore_t)sem); }

int ios5_sem_wait_timeout(void *sem, double seconds) {
    dispatch_time_t t = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC));
    return dispatch_semaphore_wait((dispatch_semaphore_t)sem, t) == 0 ? 1 : 0;
}

#endif /* IOS5_TARGET */
