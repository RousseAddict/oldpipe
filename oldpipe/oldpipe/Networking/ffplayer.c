/*
 * ffplayer.c — see ffplayer.h.
 *
 * Four threads and one lock:
 *   read   demuxes into two packet queues (compressed, so seconds of either stream are cheap,
 *          and an MP4's audio/video interleave can never starve one decoder behind the other)
 *   video  decodes, drops what is already late, converts the rest to BGRA into a few slots
 *   audio  decodes, runs atempo (speed without the chipmunk pitch), writes s16 PCM to a ring
 *   AudioQueue's own thread pulls the ring; the main thread pulls a frame per screen refresh.
 *
 * The audio that is actually coming out of the speaker is the master clock. Every buffer
 * handed to the AudioQueue carries the media time of its first sample and how much media
 * time each output sample stands for (speed / rate), so mapping the queue's sample clock back
 * to a media position stays exact across speed changes. With no usable audio output the
 * clock falls back to the wall clock, scaled by the speed.
 *
 * Rules that keep it deadlock-free: no AudioQueue call is ever made while holding p->lock
 * (the queue's callback takes it), and every wait re-checks abort_req and the seek serial.
 */
/* No _FORTIFY_SOURCE in this file, whatever the target's flags: the iOS 6/7/8 builds keep it,
   and its ___*_chk wrappers are not all exported by iOS 5/6 (___strlcpy_chk once crashed iOS 6
   at launch). FFmpeg's own libraries are built with it off for the same reason. */
#undef _FORTIFY_SOURCE
#define _FORTIFY_SOURCE 0

#include "ffplayer.h"

#include <pthread.h>
#include <stdio.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <time.h>
#include <sys/time.h>
#include <sys/resource.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <AudioToolbox/AudioToolbox.h>

#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavfilter/avfilter.h>
#include <libavfilter/buffersrc.h>
#include <libavfilter/buffersink.h>
#include <libavutil/channel_layout.h>
#include <libavutil/pixdesc.h>
#include <libavutil/samplefmt.h>
#include <libavutil/time.h>
#include <libswscale/swscale.h>

#define VSLOTS        5      /* BGRA frames: one on screen, the rest decoded ahead */
#define AQ_BUFS       3
#define AQ_FRAMES     2048   /* 46 ms per AudioQueue buffer at 44.1 kHz */
#define RING_SECONDS  0.5    /* post-atempo PCM; also bounds how late a speed change is heard */
#define CHUNKS        256
#define METAS         8
#define LATE          0.06   /* a frame this far behind the clock is dropped before conversion */
#define MAX_OUT_W     640    /* the iPhone 4 screen is 640 px wide; nothing wider is ever shown */
#define PKT_BYTES_MAX (8 * 1024 * 1024)
#define PKT_SECONDS   3.0

/* ---------- time + log ---------- */

static double now_s(void) {
    static mach_timebase_info_data_t tb;
    if (tb.denom == 0) mach_timebase_info(&tb);
    return (double)mach_absolute_time() * tb.numer / tb.denom / 1e9;
}

/* CPU time of the calling thread. Wall time would be meaningless here: on a single-core
   iPhone every thread's wall time includes everyone else's. */
static double thread_cpu_s(void) {
    mach_port_t th = mach_thread_self();
    thread_basic_info_data_t info;
    mach_msg_type_number_t n = THREAD_BASIC_INFO_COUNT;
    kern_return_t kr = thread_info(th, THREAD_BASIC_INFO, (thread_info_t)&info, &n);
    mach_port_deallocate(mach_task_self(), th);
    if (kr != KERN_SUCCESS) return 0;
    return info.user_time.seconds + info.user_time.microseconds / 1e6
         + info.system_time.seconds + info.system_time.microseconds / 1e6;
}

static pthread_mutex_t log_lock = PTHREAD_MUTEX_INITIALIZER;
static FILE *log_file;

void ffp_set_log_file(const char *path) {
    pthread_mutex_lock(&log_lock);
    if (log_file) fclose(log_file);
    log_file = path ? fopen(path, "a") : NULL;
    pthread_mutex_unlock(&log_lock);
}

static void flogv(const char *fmt, va_list ap) {
    char line[1024];
    vsnprintf(line, sizeof line, fmt, ap);
    struct timeval tv; gettimeofday(&tv, NULL);
    struct tm tm; localtime_r(&tv.tv_sec, &tm);
    pthread_mutex_lock(&log_lock);
    if (log_file) {
        fprintf(log_file, "%02d:%02d:%02d.%03d %s\n", tm.tm_hour, tm.tm_min, tm.tm_sec,
                (int)(tv.tv_usec / 1000), line);
        fflush(log_file);
    }
    pthread_mutex_unlock(&log_lock);
}

static void flog(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt); flogv(fmt, ap); va_end(ap);
}

void ffp_log_line(const char *line) { flog("%s", line); }

static void av_log_cb(void *avcl, int level, const char *fmt, va_list vl) {
    (void)avcl;
    if (level > AV_LOG_WARNING) return;
    char buf[512];
    vsnprintf(buf, sizeof buf, fmt, vl);
    size_t n = strlen(buf);
    while (n && buf[n - 1] == '\n') buf[--n] = 0;
    if (n) flog("av: %s", buf);
}

#if defined(__arm__)
/* swscale's half-float readers call compiler-rt's __extendhfsf2, which iOS 5's libSystem
   predates — the same story as __mulodi4 in atomic_stubs.c. Defining it here resolves the
   call inside the app instead of leaving a strong import that fails to bind at launch.
   Plain C convention on purpose: compiler-rt builds its helpers that way on Darwin (its
   aapcs override is EABI-only), and armv7 iOS passes and returns floats in core registers. */
float ffp_extendhfsf2(uint16_t h) __asm__("___extendhfsf2");
float ffp_extendhfsf2(uint16_t h) {
    uint32_t sign = (uint32_t)(h & 0x8000u) << 16, exp = (h >> 10) & 0x1f, mant = h & 0x3ffu, bits;
    if (exp == 0) {
        if (mant == 0) {
            bits = sign;
        } else {                                /* subnormal half: normalise it */
            exp = 113;
            while (!(mant & 0x400u)) { mant <<= 1; exp--; }
            bits = sign | (exp << 23) | ((mant & 0x3ffu) << 13);
        }
    } else if (exp == 31) {
        bits = sign | 0x7f800000u | (mant << 13);
    } else {
        bits = sign | ((exp + 112) << 23) | (mant << 13);
    }
    union { uint32_t u; float f; } v = { bits };
    return v.f;
}
#endif

/* libavutil's timestamp helpers use fpclassify(), which the 15.2 SDK expands to
   __fpclassifyd; iOS 5.1.1's libm only exports the older __fpclassify. Every arch: it is an
   ordinary C call, and which iOS first exports it is not known. */
int ffp_fpclassifyd(double x) __asm__("___fpclassifyd");
int ffp_fpclassifyd(double x) {
    return __builtin_fpclassify(FP_NAN, FP_INFINITE, FP_NORMAL, FP_SUBNORMAL, FP_ZERO, x);
}

/* ---------- time stretch: WSOLA, integer ---------- */
/* atempo correlates with float FFTs, and FFmpeg 7 has no NEON FFT for 32-bit ARM: on the
   emulated iPhone 4 it took ~20% CPU to produce less than half of real time, and an A4's
   VFP is not much kinder. This is the SoundTouch-style time-domain alternative: 40 ms
   sequences joined by a 10 ms crossfade, each slid by up to 15 ms to where it best matches
   the tail of the one before. Integer-only, coarse-to-fine search, and at 1.0x it copies
   straight through. Input and output are interleaved s16 stereo. */

typedef struct {
    int seq, ovl, seek;             /* frames */
    int16_t *in, *tail, *out;
    int in_n, in_cap, out_cap, have_tail;
    double frac;                    /* fractional input advance carried between sequences */
} Stretch;

static void st_init(Stretch *s, int rate) {
    s->seq = rate * 40 / 1000;
    s->ovl = rate * 10 / 1000;
    s->seek = rate * 15 / 1000;
    s->tail = av_malloc((size_t)s->ovl * 4);
}

static void st_reset(Stretch *s) { s->in_n = 0; s->have_tail = 0; s->frac = 0; }

static void st_free(Stretch *s) { av_freep(&s->in); av_freep(&s->tail); av_freep(&s->out); }

static int st_reserve(int16_t **buf, int *cap, int frames) {
    if (frames <= *cap) return 0;
    int16_t *b = av_realloc(*buf, (size_t)frames * 2 * 4);
    if (!b) return -1;
    *buf = b; *cap = frames * 2;
    return 0;
}

/* How well `cand` continues `tail`, on the mono mix: correlation over the candidate's energy. */
static double st_score(const int16_t *tail, const int16_t *cand, int n) {
    int64_t c = 0, e = 1;
    for (int i = 0; i < n; i++) {
        int x = (tail[2 * i] + tail[2 * i + 1]) >> 1, y = (cand[2 * i] + cand[2 * i + 1]) >> 1;
        c += x * y;
        e += y * y;
    }
    return c / sqrt((double)e);
}

static int st_best_offset(const Stretch *s, const int16_t *in) {
    double best = -1e300;
    int bo = 0;
    for (int o = 0; o < s->seek; o += 4) {
        double sc = st_score(s->tail, in + o * 2, s->ovl);
        if (sc > best) { best = sc; bo = o; }
    }
    int lo = bo > 3 ? bo - 3 : 0, hi = bo + 3 < s->seek ? bo + 3 : s->seek - 1;
    for (int o = lo; o <= hi; o++) {
        double sc = st_score(s->tail, in + o * 2, s->ovl);
        if (sc > best) { best = sc; bo = o; }
    }
    return bo;
}

/* Feeds n frames in; returns how many frames of output are now in s->out. */
static int st_process(Stretch *s, const int16_t *src, int n, double tempo) {
    if (tempo == 1.0 && !s->have_tail && s->in_n == 0) {
        if (st_reserve(&s->out, &s->out_cap, n) < 0) return 0;
        memcpy(s->out, src, (size_t)n * 4);
        return n;
    }
    if (n > 0) {
        if (st_reserve(&s->in, &s->in_cap, s->in_n + n) < 0) return 0;
        memcpy(s->in + s->in_n * 2, src, (size_t)n * 4);
        s->in_n += n;
    }
    int produced = 0, consumed = 0;
    for (;;) {
        int avail = s->in_n - consumed;
        const int16_t *in = s->in + consumed * 2;
        if (tempo == 1.0) {
            /* back to normal speed: fade the last tail in, then pass the rest through */
            if (s->have_tail && avail < s->ovl) break;
            if (st_reserve(&s->out, &s->out_cap, produced + avail) < 0) break;
            int16_t *o = s->out + produced * 2;
            int k = 0;
            if (s->have_tail) {
                for (int i = 0; i < s->ovl * 2; i++)
                    o[i] = (int16_t)((s->tail[i] * (s->ovl - i / 2) + in[i] * (i / 2)) / s->ovl);
                k = s->ovl;
                s->have_tail = 0;
            }
            memcpy(o + k * 2, in + k * 2, (size_t)(avail - k) * 4);
            produced += avail;
            consumed += avail;
            break;
        }
        /* enough for the search window AND for the advance: above ~1.8x the advance
           (tempo x 30 ms) outruns the 55 ms the search needs */
        double adv = tempo * (s->seq - s->ovl) + s->frac;
        if (avail < s->seek + s->seq || avail < (int)adv) break;
        int off = s->have_tail ? st_best_offset(s, in) : 0;
        if (st_reserve(&s->out, &s->out_cap, produced + s->seq - s->ovl) < 0) break;
        int16_t *o = s->out + produced * 2;
        const int16_t *seg = in + off * 2;
        if (s->have_tail) {
            for (int i = 0; i < s->ovl * 2; i++)
                o[i] = (int16_t)((s->tail[i] * (s->ovl - i / 2) + seg[i] * (i / 2)) / s->ovl);
        } else {
            memcpy(o, seg, (size_t)s->ovl * 4);
        }
        memcpy(o + s->ovl * 2, seg + s->ovl * 2, (size_t)(s->seq - 2 * s->ovl) * 4);
        memcpy(s->tail, seg + (s->seq - s->ovl) * 2, (size_t)s->ovl * 4);
        s->have_tail = 1;
        produced += s->seq - s->ovl;
        consumed += (int)adv;
        s->frac = adv - (int)adv;
    }
    if (consumed > 0) {
        memmove(s->in, s->in + consumed * 2, (size_t)(s->in_n - consumed) * 4);
        s->in_n -= consumed;
    }
    return produced;
}

/* ---------- player state ---------- */

typedef struct PktNode {
    AVPacket *pkt;
    int serial, eof;
    double dur;
    struct PktNode *next;
} PktNode;

typedef struct {
    PktNode *first, *last;
    int count;
    int64_t bytes;
    double dur;
} PktQueue;

enum { SLOT_FREE, SLOT_BUSY, SLOT_READY, SLOT_SHOWN };

typedef struct {
    struct ffp_player *owner;
    uint8_t *data;
    int size, w, h, stride, state;
    double pts;
} VSlot;

typedef struct { int64_t start; int frames; double pts, mpf; } Chunk;   /* ring run, mpf = media s per frame */
typedef struct { double start; int frames; double pts, mpf; } AQMeta;   /* one enqueued AudioQueue buffer */

struct ffp_player {
    pthread_mutex_t lock;
    pthread_cond_t cond;
    int refs;                       /* the player itself + every frame image still out */
    volatile int abort_req;

    char *url;
    int state, want_play, paused;
    char error[256];
    FILE *dump;
    float volume;

    pthread_t read_tid, video_tid, audio_tid;
    int have_read, have_video, have_audio;

    AVFormatContext *fmt;
    int vidx, aidx;
    AVCodecContext *vdec, *adec;
    AVRational vtb, atb;
    double start_time, duration;    /* stream time; positions handed out are relative to start_time */

    PktQueue vpq, apq;
    int serial, eof, read_errors;
    int seek_req;
    double seek_to, skip_until;

    VSlot slots[VSLOTS];
    int fifo[VSLOTS], fifo_n;
    int shown_since_seek;
    struct SwsContext *sws;
    int sws_w, sws_h, sws_f, out_w, out_h;
    CGColorSpaceRef rgb;
    int skip_lf, key_only, late_run, ok_run;
    double last_conv;               /* when the video thread last converted a frame */

    AudioQueueRef aq;
    AudioQueueBufferRef aqbuf[AQ_BUFS];
    int aq_ok, aq_started, use_wall, rate;
    int16_t *ring;
    int ring_cap;
    int64_t ring_w, ring_r;
    Chunk chunks[CHUNKS];
    int chunk_head, chunk_n;
    AQMeta metas[METAS];
    int meta_n;
    double aq_enq, seek_floor, seek_floor_pts, silence_pts;
    double last_aq_t, last_aq_wall;
    double wall_pts, wall_at, last_clock;

    AVFilterGraph *graph;
    AVFilterContext *fsrc, *fsink;
    double speed, applied_speed;
    int use_atempo;                 /* FFmpeg's atempo instead of the Stretch above */
    Stretch st;

    int64_t st_decoded, st_drop_decode, st_drop_display, st_shown, st_seek_skipped, st_underruns, st_keyskip;
    double st_dec_cpu, st_conv_cpu, st_audio_cpu, st_adec_cpu;
    int64_t pv_decoded, pv_shown;
    double pv_dec_cpu, pv_conv_cpu, pv_audio_cpu, pv_adec_cpu, pv_wall, pv_cpu, pv_pos;
    double opened_at, first_frame_ms;   /* time to first frame, from ffp_open */
    int video_only;
};

#define LOCK(p)   pthread_mutex_lock(&(p)->lock)
#define UNLOCK(p) pthread_mutex_unlock(&(p)->lock)
#define WAKE(p)   pthread_cond_broadcast(&(p)->cond)

static void ffp_release(ffp_player *p) {
    if (__sync_sub_and_fetch(&p->refs, 1) != 0) return;
    for (int i = 0; i < VSLOTS; i++) av_free(p->slots[i].data);
    CGColorSpaceRelease(p->rgb);
    pthread_cond_destroy(&p->cond);
    pthread_mutex_destroy(&p->lock);
    free(p);
}

static void set_priority(int delta) {
    struct sched_param sp; int pol;
    if (pthread_getschedparam(pthread_self(), &pol, &sp) != 0) return;
    sp.sched_priority += delta;
    pthread_setschedparam(pthread_self(), pol, &sp);
}

/* ---------- packet queues (all under p->lock) ---------- */

static void node_free(PktNode *n) {
    av_packet_free(&n->pkt);
    free(n);
}

static void pq_push(PktQueue *q, PktNode *n) {
    n->next = NULL;
    if (q->last) q->last->next = n; else q->first = n;
    q->last = n;
    q->count++;
    q->bytes += n->pkt ? n->pkt->size : 0;
    q->dur += n->dur;
}

static PktNode *pq_pop(PktQueue *q) {
    PktNode *n = q->first;
    if (!n) return NULL;
    q->first = n->next;
    if (!q->first) q->last = NULL;
    q->count--;
    q->bytes -= n->pkt ? n->pkt->size : 0;
    q->dur -= n->dur;
    return n;
}

static void pq_flush(PktQueue *q) {
    PktNode *n;
    while ((n = pq_pop(q))) node_free(n);
    q->bytes = 0; q->dur = 0;
}

static PktNode *pq_wait_pop(ffp_player *p, PktQueue *q) {
    LOCK(p);
    while (!p->abort_req && !q->first) pthread_cond_wait(&p->cond, &p->lock);
    PktNode *n = p->abort_req ? NULL : pq_pop(q);
    WAKE(p);                        /* the read thread may be waiting for room */
    UNLOCK(p);
    return n;
}

static int pq_enough(PktQueue *q, int present) {
    return !present || q->dur > PKT_SECONDS || q->count > 150;
}

static int queues_full(ffp_player *p) {
    return p->vpq.bytes + p->apq.bytes > PKT_BYTES_MAX
        || (pq_enough(&p->vpq, p->vidx >= 0) && pq_enough(&p->apq, p->aidx >= 0));
}

/* ---------- clock ---------- */

static double map_aq_time(ffp_player *p, double t) {      /* under lock */
    if (t < p->seek_floor) return p->seek_floor_pts;      /* pre-seek audio still draining */
    if (p->meta_n == 0) return p->silence_pts;
    int lo = p->meta_n > METAS ? p->meta_n - METAS : 0;
    for (int i = p->meta_n - 1; i >= lo; i--) {
        AQMeta *m = &p->metas[i % METAS];
        if (t >= m->start) {
            double off = t - m->start;
            if (off > m->frames) off = m->frames;
            return m->pts + off * m->mpf;
        }
    }
    return p->metas[lo % METAS].pts;
}

static void fall_back_to_wall(ffp_player *p, double clock, const char *why) {   /* under lock */
    p->use_wall = 1;
    p->wall_pts = clock;
    p->wall_at = now_s();
    flog("clock: %s — falling back to the wall clock at %.2f", why, clock - p->start_time);
    WAKE(p);
}

static double get_clock(ffp_player *p) {
    double wall = now_s();
    LOCK(p);
    int audio = p->aq_ok && p->aq_started && !p->use_wall;
    UNLOCK(p);
    if (audio) {
        AudioTimeStamp ts;
        memset(&ts, 0, sizeof ts);
        OSStatus st = AudioQueueGetCurrentTime(p->aq, NULL, &ts, NULL);
        LOCK(p);
        if (!p->use_wall) {
            double c = p->last_clock;
            if (st == noErr && (ts.mFlags & kAudioTimeStampSampleTimeValid)) {
                if (ts.mSampleTime != p->last_aq_t) { p->last_aq_t = ts.mSampleTime; p->last_aq_wall = wall; }
                c = map_aq_time(p, ts.mSampleTime);
            }
            /* A queue that is "running" but whose clock never moves has no hardware behind it
               (or lost it): without this the picture would freeze on the first frame. */
            if (!p->paused && p->state == FFP_PLAYING && wall - p->last_aq_wall > 1.0) {
                fall_back_to_wall(p, c, st == noErr ? "audio clock stopped" : "audio clock unreadable");
            } else {
                p->last_clock = c;
                UNLOCK(p);
                return c;
            }
        }
        UNLOCK(p);
    }
    LOCK(p);
    double c;
    if (p->use_wall || !p->aq_ok) {
        c = (p->paused || p->state != FFP_PLAYING) ? p->wall_pts : p->wall_pts + (wall - p->wall_at) * p->speed;
        p->last_clock = c;
    } else {
        c = p->last_clock;          /* audio not started yet: hold where we are */
    }
    UNLOCK(p);
    return c;
}

/* ---------- audio output ---------- */

static void aq_callback(void *ud, AudioQueueRef aq, AudioQueueBufferRef buf) {
    ffp_player *p = ud;
    int16_t *out = buf->mAudioData;
    LOCK(p);
    if (p->abort_req) { UNLOCK(p); return; }
    while (p->chunk_n && p->chunks[p->chunk_head].start + p->chunks[p->chunk_head].frames <= p->ring_r) {
        p->chunk_head = (p->chunk_head + 1) % CHUNKS;
        p->chunk_n--;
    }
    AQMeta m;
    m.start = p->aq_enq;
    m.frames = AQ_FRAMES;
    int64_t avail = p->ring_w - p->ring_r;
    int n = avail < AQ_FRAMES ? (int)avail : AQ_FRAMES;
    if (n > 0) {
        Chunk *c = p->chunk_n ? &p->chunks[p->chunk_head] : NULL;
        m.pts = c ? c->pts + (p->ring_r - c->start) * c->mpf : p->silence_pts;
        double mpf = c ? c->mpf : 0;
        int64_t r = p->ring_r % p->ring_cap;
        int first = (int)(p->ring_cap - r) < n ? (int)(p->ring_cap - r) : n;
        memcpy(out, p->ring + r * 2, (size_t)first * 4);
        if (n > first) memcpy(out + first * 2, p->ring, (size_t)(n - first) * 4);
        p->ring_r += n;
        if (n < AQ_FRAMES) {
            memset(out + n * 2, 0, (size_t)(AQ_FRAMES - n) * 4);
            p->st_underruns++;
        }
        /* a short buffer still spans AQ_FRAMES of output: spread its media time across it */
        m.mpf = mpf * n / AQ_FRAMES;
        p->silence_pts = m.pts + n * mpf;
    } else {
        memset(out, 0, AQ_FRAMES * 4);
        m.pts = p->silence_pts;
        m.mpf = 0;
        if (p->aq_started && !p->paused && !p->eof) p->st_underruns++;
    }
    p->metas[p->meta_n % METAS] = m;
    p->meta_n++;
    p->aq_enq += AQ_FRAMES;
    WAKE(p);
    UNLOCK(p);
    buf->mAudioDataByteSize = AQ_FRAMES * 4;
    AudioQueueEnqueueBuffer(aq, buf, 0, NULL);
}

static int setup_audio_output(ffp_player *p) {
    p->rate = p->adec->sample_rate > 0 ? p->adec->sample_rate : 44100;
    p->ring_cap = (int)(p->rate * RING_SECONDS);
    p->ring = av_malloc((size_t)p->ring_cap * 4);
    AudioStreamBasicDescription f;
    memset(&f, 0, sizeof f);
    f.mSampleRate = p->rate;
    f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked;
    f.mBytesPerPacket = 4;
    f.mFramesPerPacket = 1;
    f.mBytesPerFrame = 4;
    f.mChannelsPerFrame = 2;
    f.mBitsPerChannel = 16;
    OSStatus st = AudioQueueNewOutput(&f, aq_callback, p, NULL, NULL, 0, &p->aq);
    if (st != noErr) {
        flog("audio: AudioQueueNewOutput failed (%d) — playing on the wall clock, silent", (int)st);
        p->aq = NULL;
        return -1;
    }
    for (int i = 0; i < AQ_BUFS; i++) {
        if (AudioQueueAllocateBuffer(p->aq, AQ_FRAMES * 4, &p->aqbuf[i]) != noErr) {
            flog("audio: AudioQueueAllocateBuffer failed");
            AudioQueueDispose(p->aq, true);
            p->aq = NULL;
            return -1;
        }
    }
    if (p->volume < 1.0f) AudioQueueSetParameter(p->aq, kAudioQueueParam_Volume, p->volume);
    p->aq_ok = 1;
    return 0;
}

/* Called without the lock. The first start primes the queue from the ring, which the audio
   thread has been filling since open, so the first buffer out is already real sound. */
static void start_playback(ffp_player *p) {
    LOCK(p);
    p->paused = 0;
    p->state = FFP_PLAYING;
    p->wall_at = now_s();
    p->last_aq_wall = p->wall_at;
    int use_aq = p->aq_ok && !p->use_wall;
    int prime = use_aq && !p->aq_started;
    UNLOCK(p);
    if (!use_aq) return;
    if (prime) for (int i = 0; i < AQ_BUFS; i++) aq_callback(p, p->aq, p->aqbuf[i]);
    OSStatus st = AudioQueueStart(p->aq, NULL);
    LOCK(p);
    if (st != noErr) {
        char why[64]; snprintf(why, sizeof why, "AudioQueueStart failed (%d)", (int)st);
        fall_back_to_wall(p, p->last_clock, why);
    } else {
        p->aq_started = 1;
        p->last_aq_wall = now_s();
    }
    UNLOCK(p);
}

/* ---------- audio decode + atempo ---------- */

static int build_graph(ffp_player *p, const AVFrame *f) {
    avfilter_graph_free(&p->graph);
    p->fsrc = p->fsink = NULL;
    p->graph = avfilter_graph_alloc();
    if (!p->graph) return -1;

    AVChannelLayout layout;
    if (f->ch_layout.order != AV_CHANNEL_ORDER_UNSPEC) av_channel_layout_copy(&layout, &f->ch_layout);
    else av_channel_layout_default(&layout, f->ch_layout.nb_channels);
    char lname[64];
    av_channel_layout_describe(&layout, lname, sizeof lname);
    av_channel_layout_uninit(&layout);

    char a_src[256], a_tempo[32], a_fmt[128];
    snprintf(a_src, sizeof a_src, "time_base=%d/%d:sample_rate=%d:sample_fmt=%s:channel_layout=%s",
             p->atb.num, p->atb.den, f->sample_rate, av_get_sample_fmt_name(f->format), lname);
    snprintf(a_tempo, sizeof a_tempo, "tempo=%.4f", p->speed);
    snprintf(a_fmt, sizeof a_fmt, "sample_fmts=s16:channel_layouts=stereo:sample_rates=%d", p->rate);

    AVFilterContext *tempo = NULL, *format = NULL;
    int r;
    if ((r = avfilter_graph_create_filter(&p->fsrc, avfilter_get_by_name("abuffer"), "src", a_src, NULL, p->graph)) < 0 ||
        (p->use_atempo &&
         (r = avfilter_graph_create_filter(&tempo, avfilter_get_by_name("atempo"), "tempo", a_tempo, NULL, p->graph)) < 0) ||
        (r = avfilter_graph_create_filter(&format, avfilter_get_by_name("aformat"), "format", a_fmt, NULL, p->graph)) < 0 ||
        (r = avfilter_graph_create_filter(&p->fsink, avfilter_get_by_name("abuffersink"), "sink", NULL, NULL, p->graph)) < 0 ||
        (r = avfilter_link(p->fsrc, 0, tempo ? tempo : format, 0)) < 0 ||
        (tempo && (r = avfilter_link(tempo, 0, format, 0)) < 0) ||
        (r = avfilter_link(format, 0, p->fsink, 0)) < 0 ||
        (r = avfilter_graph_config(p->graph, NULL)) < 0) {
        flog("audio: filter graph failed: %s (src %s)", av_err2str(r), a_src);
        avfilter_graph_free(&p->graph);
        p->fsrc = p->fsink = NULL;
        return -1;
    }
    p->applied_speed = p->speed;
    return 0;
}

static void apply_speed(ffp_player *p, double sp) {
    char arg[32], res[64] = "";
    snprintf(arg, sizeof arg, "%.4f", sp);
    int r = avfilter_graph_send_command(p->graph, "tempo", "tempo", arg, res, sizeof res, 0);
    if (r < 0) flog("audio: atempo refused tempo %s: %s", arg, av_err2str(r));
    else p->applied_speed = sp;
}

static void ring_write(ffp_player *p, const int16_t *src, int n, double pts, double mpf, int serial) {
    LOCK(p);
    while (!p->abort_req && serial == p->serial && p->aq_ok && !p->use_wall
           && p->ring_cap - (p->ring_w - p->ring_r) < n)
        pthread_cond_wait(&p->cond, &p->lock);
    if (p->abort_req || serial != p->serial) { UNLOCK(p); return; }
    if (n > p->ring_cap) { src += (size_t)(n - p->ring_cap) * 2; n = p->ring_cap; }
    int64_t room = p->ring_cap - (p->ring_w - p->ring_r);
    if (room < n) p->ring_r += n - room;    /* nobody is consuming: keep the newest */
    if (p->chunk_n == CHUNKS) { p->chunk_head = (p->chunk_head + 1) % CHUNKS; p->chunk_n--; }
    Chunk *c = &p->chunks[(p->chunk_head + p->chunk_n) % CHUNKS];
    c->start = p->ring_w; c->frames = n; c->pts = pts; c->mpf = mpf;
    p->chunk_n++;
    int64_t w = p->ring_w % p->ring_cap;
    int first = (int)(p->ring_cap - w) < n ? (int)(p->ring_cap - w) : n;
    memcpy(p->ring + w * 2, src, (size_t)first * 4);
    if (n > first) memcpy(p->ring, src + first * 2, (size_t)(n - first) * 4);
    p->ring_w += n;
    WAKE(p);
    UNLOCK(p);
}

static void emit_pcm(ffp_player *p, const int16_t *pcm, int n, int serial, double *cursor, double in_end) {
    if (n <= 0) return;
    double mpf = p->applied_speed / p->rate;
    ring_write(p, pcm, n, *cursor, mpf, serial);
    if (p->dump) fwrite(pcm, 4, (size_t)n, p->dump);
    *cursor += n * mpf;
    if (*cursor > in_end) *cursor = in_end;
}

static void drain_sink(ffp_player *p, AVFrame *o, int serial, double *cursor, double in_end) {
    while (p->fsink && av_buffersink_get_frame(p->fsink, o) >= 0) {
        if (p->use_atempo) {
            emit_pcm(p, (const int16_t *)o->data[0], o->nb_samples, serial, cursor, in_end);
        } else {
            int n = st_process(&p->st, (const int16_t *)o->data[0], o->nb_samples, p->applied_speed);
            emit_pcm(p, p->st.out, n, serial, cursor, in_end);
        }
        av_frame_unref(o);
    }
}

static void *audio_thread(void *arg) {
    ffp_player *p = arg;
    pthread_setname_np("ffp.audio");
    set_priority(+8);   /* above video decode: on one core a starved audio thread is an audible gap */
    AVFrame *f = av_frame_alloc(), *o = av_frame_alloc();
    int serial = -1, cursor_ok = 0;
    double skip_until = -1e9, cursor = 0, in_end = 0;
    for (;;) {
        PktNode *n = pq_wait_pop(p, &p->apq);
        if (!n) break;
        double c0 = thread_cpu_s();
        if (n->serial != serial) {
            serial = n->serial;
            avcodec_flush_buffers(p->adec);
            avfilter_graph_free(&p->graph);
            p->fsrc = p->fsink = NULL;
            st_reset(&p->st);
            LOCK(p); skip_until = p->skip_until; UNLOCK(p);
            cursor_ok = 0;
        }
        int eof = n->eof;
        /* send_packet is where FFmpeg actually decodes, so it counts as decode time too */
        double d0 = thread_cpu_s();
        avcodec_send_packet(p->adec, eof ? NULL : n->pkt);
        p->st_adec_cpu += thread_cpu_s() - d0;
        node_free(n);
        for (;;) {
            d0 = thread_cpu_s();
            int got = avcodec_receive_frame(p->adec, f) >= 0;
            p->st_adec_cpu += thread_cpu_s() - d0;
            if (!got) break;
            double pts = f->best_effort_timestamp != AV_NOPTS_VALUE
                       ? f->best_effort_timestamp * av_q2d(p->atb) : in_end;
            double dur = f->sample_rate > 0 ? (double)f->nb_samples / f->sample_rate : 0;
            if (pts + dur <= skip_until || (!p->graph && build_graph(p, f) < 0)) {
                av_frame_unref(f);
                continue;
            }
            LOCK(p); double sp = p->speed; UNLOCK(p);
            if (sp != p->applied_speed) {
                if (p->use_atempo) apply_speed(p, sp);
                else p->applied_speed = sp;
            }
            if (!cursor_ok) { cursor = pts; cursor_ok = 1; }
            in_end = pts + dur;
            if (av_buffersrc_add_frame(p->fsrc, f) < 0) av_frame_unref(f);
            drain_sink(p, o, serial, &cursor, in_end);
        }
        if (eof && p->fsrc) {
            (void)av_buffersrc_add_frame(p->fsrc, NULL);
            drain_sink(p, o, serial, &cursor, 1e12);
            if (!p->use_atempo) emit_pcm(p, p->st.out, st_process(&p->st, NULL, 0, 1.0), serial, &cursor, 1e12);
        }
        p->st_audio_cpu += thread_cpu_s() - c0;
    }
    av_frame_free(&f);
    av_frame_free(&o);
    return NULL;
}

/* ---------- video decode ---------- */

/* Waits for a free slot. A queued frame the clock has already passed by a quarter second is
   taken back: nobody is pulling frames (the app is in the background, where the display link
   stops), and without this the video thread would block, the read thread would stop at its
   byte cap, and the audio would run dry behind it. */
static int acquire_slot(ffp_player *p, int serial) {
    LOCK(p);
    for (;;) {
        if (p->abort_req || serial != p->serial) { UNLOCK(p); return -1; }
        for (int i = 0; i < VSLOTS; i++) {
            if (p->slots[i].state == SLOT_FREE) {
                p->slots[i].state = SLOT_BUSY;
                UNLOCK(p);
                return i;
            }
        }
        if (p->fifo_n > 0 && p->slots[p->fifo[0]].pts < p->last_clock - 0.25) {
            int i = p->fifo[0];
            memmove(p->fifo, p->fifo + 1, (size_t)(--p->fifo_n) * sizeof p->fifo[0]);
            p->slots[i].state = SLOT_BUSY;
            p->st_drop_display++;
            UNLOCK(p);
            return i;
        }
        /* timed: the clock moves without anyone signalling when audio is off */
        struct timeval tv; gettimeofday(&tv, NULL);
        struct timespec ts = { tv.tv_sec, (long)tv.tv_usec * 1000 + 50000000L };
        if (ts.tv_nsec >= 1000000000L) { ts.tv_sec++; ts.tv_nsec -= 1000000000L; }
        pthread_cond_timedwait(&p->cond, &p->lock, &ts);
    }
}

static int convert(ffp_player *p, const AVFrame *f, VSlot *s) {
    int ow = f->width, oh = f->height;
    if (ow > MAX_OUT_W) { oh = (int)((int64_t)oh * MAX_OUT_W / ow) & ~1; ow = MAX_OUT_W; }
    if (!p->sws || p->sws_w != f->width || p->sws_h != f->height || p->sws_f != f->format
        || p->out_w != ow || p->out_h != oh) {
        sws_freeContext(p->sws);
        p->sws = sws_getContext(f->width, f->height, f->format, ow, oh, AV_PIX_FMT_BGRA,
                                SWS_FAST_BILINEAR, NULL, NULL, NULL);
        p->sws_w = f->width; p->sws_h = f->height; p->sws_f = f->format;
        p->out_w = ow; p->out_h = oh;
        flog("video: %dx%d %s -> %dx%d BGRA", f->width, f->height,
             av_get_pix_fmt_name(f->format), ow, oh);
        if (!p->sws) return -1;
    }
    int stride = FFALIGN(ow * 4, 64);
    int size = stride * oh;
    if (s->size < size) {
        av_free(s->data);
        s->data = av_malloc(size);
        s->size = s->data ? size : 0;
        if (!s->data) return -1;
    }
    uint8_t *dst[4] = { s->data, NULL, NULL, NULL };
    int dls[4] = { stride, 0, 0, 0 };
    sws_scale(p->sws, (const uint8_t * const *)f->data, f->linesize, 0, f->height, dst, dls);
    s->w = ow; s->h = oh; s->stride = stride;
    return 0;
}

/* Falling behind: first stop deblocking (cheap, mostly invisible at phone size), and if
   still a second behind, decode keyframes only until one lands on time again. Without the
   second step a decoder that cannot keep up never recovers — every frame arrives late. */
static void video_late(ffp_player *p, double behind) {
    p->ok_run = 0;
    if (++p->late_run >= 5 && !p->skip_lf) {
        p->vdec->skip_loop_filter = AVDISCARD_ALL;
        p->skip_lf = 1;
        flog("video: %.2fs behind, skipping the loop filter", behind);
    }
    if (behind > 1.0 && !p->key_only) {
        p->vdec->skip_frame = AVDISCARD_NONKEY;
        p->key_only = 1;
        p->st_keyskip++;
        flog("video: %.2fs behind, keyframes only until caught up", behind);
    }
}

static void video_on_time(ffp_player *p) {
    p->late_run = 0;
    if (p->key_only) {
        p->vdec->skip_frame = AVDISCARD_DEFAULT;
        p->key_only = 0;
        flog("video: caught up");
    }
    if (p->skip_lf && ++p->ok_run > 150) {
        p->vdec->skip_loop_filter = AVDISCARD_DEFAULT;
        p->skip_lf = 0;
        flog("video: on time for 150 frames, loop filter back on");
    }
}

static void *video_thread(void *arg) {
    ffp_player *p = arg;
    pthread_setname_np("ffp.video");
    set_priority(-4);   /* below the main thread, so decoding never makes the UI stutter */
    AVFrame *f = av_frame_alloc();
    int serial = -1;
    double skip_until = -1e9;
    for (;;) {
        PktNode *n = pq_wait_pop(p, &p->vpq);
        if (!n) break;
        if (n->serial != serial) {
            serial = n->serial;
            avcodec_flush_buffers(p->vdec);
            LOCK(p); skip_until = p->skip_until; UNLOCK(p);
            if (p->key_only) { p->vdec->skip_frame = AVDISCARD_DEFAULT; p->key_only = 0; }
            p->late_run = 0;
        }
        double c0 = thread_cpu_s();
        avcodec_send_packet(p->vdec, n->eof ? NULL : n->pkt);
        node_free(n);
        for (;;) {
            int r = avcodec_receive_frame(p->vdec, f);
            double c1 = thread_cpu_s();
            if (r < 0) break;
            p->st_dec_cpu += c1 - c0;
            p->st_decoded++;
            int64_t ts = f->best_effort_timestamp != AV_NOPTS_VALUE ? f->best_effort_timestamp : f->pts;
            double pts = ts * av_q2d(p->vtb);
            if (pts < skip_until - 0.001) {
                p->st_seek_skipped++;
                av_frame_unref(f);
                c0 = thread_cpu_s();
                continue;
            }
            double behind = get_clock(p) - pts;
            LOCK(p); int shown = p->shown_since_seek; UNLOCK(p);
            /* Late frames are dropped before the costly conversion — but not all of them: a
               decoder running just behind the clock would otherwise drop every frame and the
               picture would freeze. At least ~8 frames a second still get through. */
            if (shown && behind > LATE && now_s() - p->last_conv < 0.125) {
                p->st_drop_decode++;
                video_late(p, behind);
                av_frame_unref(f);
                c0 = thread_cpu_s();
                continue;
            }
            video_on_time(p);
            int si = acquire_slot(p, serial);
            if (si < 0) { av_frame_unref(f); break; }
            double k0 = thread_cpu_s();
            p->last_conv = now_s();
            int ok = convert(p, f, &p->slots[si]) == 0;
            p->st_conv_cpu += thread_cpu_s() - k0;
            LOCK(p);
            if (ok && serial == p->serial) {
                p->slots[si].pts = pts;
                p->slots[si].state = SLOT_READY;
                p->fifo[p->fifo_n++] = si;
            } else {
                p->slots[si].state = SLOT_FREE;
            }
            WAKE(p);
            UNLOCK(p);
            av_frame_unref(f);
            c0 = thread_cpu_s();
        }
    }
    av_frame_free(&f);
    return NULL;
}

/* ---------- read thread ---------- */

static int interrupt_cb(void *ud) { return ((ffp_player *)ud)->abort_req; }

static void fail(ffp_player *p, const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    LOCK(p);
    vsnprintf(p->error, sizeof p->error, fmt, ap);
    p->state = FFP_FAILED;
    UNLOCK(p);
    va_end(ap);
    flog("FAILED: %s", p->error);
}

static int open_decoder(ffp_player *p, int idx, AVCodecContext **out) {
    AVStream *st = p->fmt->streams[idx];
    const AVCodec *codec = avcodec_find_decoder(st->codecpar->codec_id);
    if (!codec) return AVERROR_DECODER_NOT_FOUND;
    AVCodecContext *c = avcodec_alloc_context3(codec);
    if (!c) return AVERROR(ENOMEM);
    avcodec_parameters_to_context(c, st->codecpar);
    c->pkt_timebase = st->time_base;
    c->thread_count = 0;            /* one per core: 1 on every iOS 5 iPhone, 2 on the 4S */
    int r = avcodec_open2(c, codec, NULL);
    if (r < 0) { avcodec_free_context(&c); return r; }
    *out = c;
    return 0;
}

static int open_input(ffp_player *p) {
    double t0 = now_s();
    AVDictionary *o = NULL;
    av_dict_set(&o, "rw_timeout", "20000000", 0);          /* us: a dead proxy must not hang us forever */
    av_dict_set(&o, "probesize", "1000000", 0);
    av_dict_set(&o, "analyzeduration", "2000000", 0);
    p->fmt = avformat_alloc_context();
    p->fmt->interrupt_callback.callback = interrupt_cb;
    p->fmt->interrupt_callback.opaque = p;
    int r = avformat_open_input(&p->fmt, p->url, NULL, &o);
    av_dict_free(&o);
    if (r < 0) { fail(p, "open %s: %s", p->url, av_err2str(r)); return -1; }
    double t1 = now_s();
    if ((r = avformat_find_stream_info(p->fmt, NULL)) < 0) { fail(p, "stream info: %s", av_err2str(r)); return -1; }
    double t2 = now_s();

    p->vidx = av_find_best_stream(p->fmt, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    p->aidx = p->video_only ? -1 : av_find_best_stream(p->fmt, AVMEDIA_TYPE_AUDIO, -1, p->vidx, NULL, 0);
    for (unsigned i = 0; i < p->fmt->nb_streams; i++)
        if ((int)i != p->vidx && (int)i != p->aidx) p->fmt->streams[i]->discard = AVDISCARD_ALL;
    if (p->vidx < 0 && p->aidx < 0) { fail(p, "no audio or video stream"); return -1; }
    if (p->vidx >= 0) {
        if ((r = open_decoder(p, p->vidx, &p->vdec)) < 0) { fail(p, "video decoder: %s", av_err2str(r)); return -1; }
        p->vtb = p->fmt->streams[p->vidx]->time_base;
    }
    if (p->aidx >= 0) {
        if ((r = open_decoder(p, p->aidx, &p->adec)) < 0) {
            flog("audio decoder: %s — video only", av_err2str(r));
            p->aidx = -1;
        } else {
            p->atb = p->fmt->streams[p->aidx]->time_base;
        }
    }
    p->start_time = p->fmt->start_time != AV_NOPTS_VALUE ? p->fmt->start_time / (double)AV_TIME_BASE : 0;
    p->duration = p->fmt->duration > 0 ? p->fmt->duration / (double)AV_TIME_BASE : 0;

    flog("open: %s in %.0f ms (+%.0f ms stream info): %s, %.1fs, start %.3f | video %s %dx%d | audio %s %d Hz %d ch",
         p->fmt->iformat->name, (t1 - t0) * 1000, (t2 - t1) * 1000, p->url, p->duration, p->start_time,
         p->vdec ? p->vdec->codec->name : "-", p->vdec ? p->vdec->width : 0, p->vdec ? p->vdec->height : 0,
         p->adec ? p->adec->codec->name : "-", p->adec ? p->adec->sample_rate : 0,
         p->adec ? p->adec->ch_layout.nb_channels : 0);

    if (p->adec) {
        setup_audio_output(p);
        st_init(&p->st, p->rate);
        flog("audio: time stretch by %s", p->use_atempo ? "atempo (FFmpeg)" : "WSOLA (integer)");
    }

    LOCK(p);
    p->wall_pts = p->last_clock = p->silence_pts = p->seek_floor_pts = p->start_time;
    UNLOCK(p);

    if (p->vdec && pthread_create(&p->video_tid, NULL, video_thread, p) == 0) p->have_video = 1;
    if (p->adec && pthread_create(&p->audio_tid, NULL, audio_thread, p) == 0) p->have_audio = 1;

    LOCK(p);
    p->state = p->paused ? FFP_PAUSED : FFP_READY;
    int play = p->want_play;
    UNLOCK(p);
    if (play) start_playback(p);
    return 0;
}

static void do_seek(ffp_player *p) {
    LOCK(p);
    double target = p->seek_to;
    UNLOCK(p);
    double t0 = now_s();
    int64_t ts = (int64_t)(target * AV_TIME_BASE);
    int r = avformat_seek_file(p->fmt, -1, INT64_MIN, ts, ts, 0);
    if (r < 0) flog("seek to %.2f failed: %s", target - p->start_time, av_err2str(r));
    LOCK(p);
    if (p->seek_to == target) p->seek_req = 0;  /* a newer request keeps the flag up */
    pq_flush(&p->vpq);
    pq_flush(&p->apq);
    p->serial++;
    p->eof = 0;
    for (int i = 0; i < VSLOTS; i++) if (p->slots[i].state == SLOT_READY) p->slots[i].state = SLOT_FREE;
    p->fifo_n = 0;
    p->shown_since_seek = 0;
    p->ring_r = p->ring_w;
    p->chunk_n = 0;
    p->silence_pts = p->seek_floor_pts = p->skip_until = p->wall_pts = p->last_clock = target;
    p->seek_floor = p->aq_enq;
    p->wall_at = now_s();
    WAKE(p);
    UNLOCK(p);
    flog("seek: %.2f in %.0f ms", target - p->start_time, (now_s() - t0) * 1000);
}

static void push_eof(ffp_player *p, PktQueue *q, int present) {
    if (!present) return;
    PktNode *n = calloc(1, sizeof *n);
    n->eof = 1;
    n->serial = p->serial;
    pq_push(q, n);
}

static void *read_thread(void *arg) {
    ffp_player *p = arg;
    pthread_setname_np("ffp.read");
    if (open_input(p) < 0) return NULL;
    AVPacket *pkt = av_packet_alloc();
    for (;;) {
        LOCK(p);
        while (!p->abort_req && !p->seek_req && (p->eof || queues_full(p)))
            pthread_cond_wait(&p->cond, &p->lock);
        int abort = p->abort_req, seek = p->seek_req;
        UNLOCK(p);
        if (abort) break;
        if (seek) { do_seek(p); continue; }

        int r = av_read_frame(p->fmt, pkt);
        if (r < 0) {
            if (p->abort_req) break;
            if (r == AVERROR_EOF || (p->fmt->pb && avio_feof(p->fmt->pb))) {
                LOCK(p);
                push_eof(p, &p->vpq, p->vidx >= 0);
                push_eof(p, &p->apq, p->aidx >= 0);
                p->eof = 1;
                WAKE(p);
                UNLOCK(p);
                flog("read: end of input");
                continue;
            }
            flog("read: %s", av_err2str(r));
            if (++p->read_errors > 30) { fail(p, "read: %s", av_err2str(r)); break; }
            av_usleep(100000);
            continue;
        }
        p->read_errors = 0;
        PktNode *n = calloc(1, sizeof *n);
        n->pkt = av_packet_alloc();
        av_packet_move_ref(n->pkt, pkt);
        LOCK(p);
        n->serial = p->serial;
        if (n->pkt->stream_index == p->vidx) {
            n->dur = n->pkt->duration * av_q2d(p->vtb);
            pq_push(&p->vpq, n);
        } else if (n->pkt->stream_index == p->aidx) {
            n->dur = n->pkt->duration * av_q2d(p->atb);
            pq_push(&p->apq, n);
        } else {
            node_free(n);
        }
        WAKE(p);
        UNLOCK(p);
    }
    av_packet_free(&pkt);
    return NULL;
}

/* ---------- public API ---------- */

ffp_player *ffp_create(void) {
    static int once;
    if (!once) {
        once = 1;
        av_log_set_level(AV_LOG_WARNING);
        av_log_set_callback(av_log_cb);
        avformat_network_init();
    }
    ffp_player *p = calloc(1, sizeof *p);
    pthread_mutex_init(&p->lock, NULL);
    pthread_cond_init(&p->cond, NULL);
    p->refs = 1;
    p->vidx = p->aidx = -1;
    p->speed = p->applied_speed = 1.0;
    p->volume = 1.0f;
    p->skip_until = -1e9;
    p->rgb = CGColorSpaceCreateDeviceRGB();
    for (int i = 0; i < VSLOTS; i++) p->slots[i].owner = p;
    p->pv_wall = now_s();
    return p;
}

void ffp_set_dump_file(ffp_player *p, const char *path) {
    p->dump = path ? fopen(path, "wb") : NULL;
}

void ffp_set_video_only(ffp_player *p, int on) { p->video_only = on; }

void ffp_set_atempo(ffp_player *p, int on) { p->use_atempo = on; }

void ffp_set_volume(ffp_player *p, float v) {
    p->volume = v;
    if (p->aq) AudioQueueSetParameter(p->aq, kAudioQueueParam_Volume, v);
}

int ffp_open(ffp_player *p, const char *url) {
    p->url = strdup(url);
    p->opened_at = now_s();
    LOCK(p); p->state = FFP_OPENING; UNLOCK(p);
    if (pthread_create(&p->read_tid, NULL, read_thread, p) != 0) {
        fail(p, "could not start the read thread");
        return -1;
    }
    p->have_read = 1;
    return 0;
}

void ffp_play(ffp_player *p) {
    LOCK(p);
    p->want_play = 1;
    int s = p->state;
    UNLOCK(p);
    if (s == FFP_READY || s == FFP_PAUSED || s == FFP_ENDED) start_playback(p);
}

void ffp_pause(ffp_player *p) {
    double c = get_clock(p);
    LOCK(p);
    p->want_play = 0;
    if (p->state != FFP_PLAYING) { UNLOCK(p); return; }
    p->paused = 1;
    p->state = FFP_PAUSED;
    p->wall_pts = p->last_clock = c;
    int aq = p->aq_ok && p->aq_started && !p->use_wall;
    UNLOCK(p);
    if (aq) AudioQueuePause(p->aq);
}

void ffp_set_speed(ffp_player *p, double speed) {
    if (speed < 0.5) speed = 0.5;   /* atempo's single-instance range */
    if (speed > 4.0) speed = 4.0;
    double c = get_clock(p);
    LOCK(p);
    p->speed = speed;
    p->wall_pts = c;
    p->wall_at = now_s();
    WAKE(p);
    UNLOCK(p);
    flog("speed: %.2fx at %.2f", speed, c - p->start_time);
}

double ffp_speed(ffp_player *p) {
    LOCK(p); double s = p->speed; UNLOCK(p);
    return s;
}

void ffp_seek(ffp_player *p, double seconds) {
    LOCK(p);
    if (seconds < 0) seconds = 0;
    if (p->duration > 0 && seconds > p->duration - 0.5) seconds = p->duration - 0.5;
    p->seek_to = seconds + p->start_time;
    p->seek_req = 1;
    WAKE(p);
    UNLOCK(p);
}

double ffp_position(ffp_player *p) {
    double c = get_clock(p) - p->start_time;
    return c < 0 ? 0 : c;
}

double ffp_duration(ffp_player *p) {
    LOCK(p); double d = p->duration; UNLOCK(p);
    return d;
}

int ffp_state(ffp_player *p) {
    double pos = ffp_position(p);
    LOCK(p);
    int s = p->state;
    if (s == FFP_PLAYING && p->eof && !p->vpq.first && !p->apq.first && p->fifo_n == 0
        && (p->duration <= 0 || pos >= p->duration - 0.3)) {
        p->state = s = FFP_ENDED;
        UNLOCK(p);
        flog("ended at %.2f", pos);
        if (p->aq_started && !p->use_wall) AudioQueuePause(p->aq);
        return s;
    }
    UNLOCK(p);
    return s;
}

const char *ffp_error(ffp_player *p) { return p->error; }

void ffp_video_size(ffp_player *p, int *w, int *h) {
    LOCK(p);
    *w = p->vdec ? p->vdec->width : 0;
    *h = p->vdec ? p->vdec->height : 0;
    UNLOCK(p);
}

static void slot_release(void *info, const void *data, size_t size) {
    (void)data; (void)size;
    VSlot *s = info;
    ffp_player *p = s->owner;
    LOCK(p);
    if (s->state == SLOT_SHOWN) s->state = SLOT_FREE;
    WAKE(p);
    UNLOCK(p);
    ffp_release(p);
}

CGImageRef ffp_copy_frame(ffp_player *p) {
    double clk = get_clock(p);
    LOCK(p);
    int pick = -1;
    while (p->fifo_n > 0) {
        VSlot *s = &p->slots[p->fifo[0]];
        int first = !p->shown_since_seek;           /* after open/seek: show at once, even paused */
        if (!first && s->pts > clk + 0.010) break;
        if (pick >= 0) { p->slots[pick].state = SLOT_FREE; p->st_drop_display++; }
        pick = p->fifo[0];
        memmove(p->fifo, p->fifo + 1, (size_t)(--p->fifo_n) * sizeof p->fifo[0]);
        if (first) break;
    }
    if (pick < 0) { UNLOCK(p); return NULL; }
    VSlot *s = &p->slots[pick];
    s->state = SLOT_SHOWN;
    p->shown_since_seek = 1;
    p->st_shown++;
    int first = p->first_frame_ms == 0;
    if (first) p->first_frame_ms = (now_s() - p->opened_at) * 1000;
    __sync_add_and_fetch(&p->refs, 1);
    WAKE(p);
    UNLOCK(p);
    CGDataProviderRef dp = CGDataProviderCreateWithData(s, s->data, (size_t)s->stride * s->h, slot_release);
    CGImageRef img = CGImageCreate(s->w, s->h, 8, 32, s->stride, p->rgb,
                                   (CGBitmapInfo)(kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst),
                                   dp, NULL, false, kCGRenderingIntentDefault);
    CGDataProviderRelease(dp);
    if (first) flog("first frame on screen %.0f ms after open", p->first_frame_ms);
    return img;
}

void ffp_stats_line(ffp_player *p, char *buf, int len) {
    double pos = ffp_position(p);
    double wall = now_s();
    struct rusage ru;
    getrusage(RUSAGE_SELF, &ru);
    double cpu = ru.ru_utime.tv_sec + ru.ru_utime.tv_usec / 1e6 + ru.ru_stime.tv_sec + ru.ru_stime.tv_usec / 1e6;
    LOCK(p);
    double dt = wall - p->pv_wall;
    if (dt <= 0) dt = 1;
    int64_t dd = p->st_decoded - p->pv_decoded, ds = p->st_shown - p->pv_shown;
    snprintf(buf, len,
             "pos=%.2f/%.0f spd=%.2f eff=%.2fx clk=%s ttff=%.0fms | shown %.1f/s decoded %.1f/s | cpu %.0f%% "
             "(dec %.1f ms/f, bgra %.1f ms/f, audio %.0f%% = aac %.0f%% + tempo %.0f%%) | drops dec=%lld disp=%lld keyskip=%lld%s | "
             "q v=%d a=%d pkts ring=%.2fs under=%lld aq=%.0f/%.0f",
             pos, p->duration, p->speed,
             p->state == FFP_PLAYING ? (pos - p->pv_pos) / dt : 0,
             p->use_wall || !p->aq_ok ? "wall" : (p->aq_started ? "audio" : "held"),
             p->first_frame_ms,
             ds / dt, dd / dt, (cpu - p->pv_cpu) / dt * 100,
             dd ? (p->st_dec_cpu - p->pv_dec_cpu) * 1000 / dd : 0,
             ds ? (p->st_conv_cpu - p->pv_conv_cpu) * 1000 / ds : 0,
             (p->st_audio_cpu - p->pv_audio_cpu) / dt * 100,
             (p->st_adec_cpu - p->pv_adec_cpu) / dt * 100,
             (p->st_audio_cpu - p->pv_audio_cpu - (p->st_adec_cpu - p->pv_adec_cpu)) / dt * 100,
             (long long)p->st_drop_decode, (long long)p->st_drop_display, (long long)p->st_keyskip,
             p->skip_lf ? " nolf" : "",
             p->vpq.count, p->apq.count,
             p->rate ? (double)(p->ring_w - p->ring_r) / p->rate : 0,
             (long long)p->st_underruns, p->last_aq_t, p->aq_enq);
    p->pv_decoded = p->st_decoded; p->pv_shown = p->st_shown;
    p->pv_dec_cpu = p->st_dec_cpu; p->pv_conv_cpu = p->st_conv_cpu; p->pv_audio_cpu = p->st_audio_cpu; p->pv_adec_cpu = p->st_adec_cpu;
    p->pv_wall = wall; p->pv_cpu = cpu; p->pv_pos = pos;
    UNLOCK(p);
}

void ffp_destroy(ffp_player *p) {
    if (!p) return;
    LOCK(p);
    p->abort_req = 1;
    WAKE(p);
    UNLOCK(p);
    if (p->aq) AudioQueueStop(p->aq, true);
    if (p->have_read) pthread_join(p->read_tid, NULL);
    if (p->have_video) pthread_join(p->video_tid, NULL);
    if (p->have_audio) pthread_join(p->audio_tid, NULL);
    if (p->aq) AudioQueueDispose(p->aq, true);
    avcodec_free_context(&p->vdec);
    avcodec_free_context(&p->adec);
    avformat_close_input(&p->fmt);
    avfilter_graph_free(&p->graph);
    sws_freeContext(p->sws);
    pq_flush(&p->vpq);
    pq_flush(&p->apq);
    av_free(p->ring);
    st_free(&p->st);
    if (p->dump) fclose(p->dump);
    free(p->url);
    flog("destroyed");
    ffp_release(p);
}
