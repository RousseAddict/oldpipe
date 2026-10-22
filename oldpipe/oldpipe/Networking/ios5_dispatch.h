/*
 * ios5_dispatch.h — raw GCD for the iOS 5 build.
 *
 * GCD itself is fine on iOS 5; what is missing is Swift's Dispatch OVERLAY.
 * Swift's DispatchQueue is the imported Objective-C class OS_dispatch_queue,
 * and dispatch objects only became Objective-C objects in iOS 6
 * (OS_OBJECT_USE_OBJC). On 5.1.1 they are plain C structs: grepping the device's
 * own dyld shared cache finds dispatch_queue_create 58 times and
 * OS_dispatch_queue not once. So every use of Swift's Dispatch API — creating a
 * queue, or merely touching DispatchQueue.main — messages a class that does not
 * exist, and dies inside libobjc.
 *
 * These wrappers exist because Swift cannot call the C API directly either: the
 * overlay marks dispatch_queue_create and friends unavailable in favour of its
 * own types. Plain C function names it has never heard of go through fine.
 *
 * Queues made here are never released. They are process-lifetime singletons
 * held in `static let`s, which is also why none of this needs dispatch_retain.
 */
#ifndef IOS5_DISPATCH_H
#define IOS5_DISPATCH_H

void *ios5_q_create(const char *label, int concurrent);
void *ios5_q_main(void);
void  ios5_q_async(void *queue, void (*fn)(void *), void *ctx);
void  ios5_q_sync(void *queue, void (*fn)(void *), void *ctx);

void *ios5_sem_create(long value);
void  ios5_sem_wait(void *sem);
int   ios5_sem_wait_timeout(void *sem, double seconds);   /* 1 = signalled, 0 = timed out */
void  ios5_sem_signal(void *sem);

#endif /* IOS5_DISPATCH_H */
