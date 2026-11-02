#ifndef ffplayer_h
#define ffplayer_h

/* ffplayer — the AVPlayer replacement POC: FFmpeg demux + software decode, AudioQueue
   output, atempo for pitch-preserving speed. Everything AVPlayer decides for us on its own
   (which formats, which rates, which TLS) becomes ours, on every iOS this app runs on.

   One player plays one URL: a local file path, or an http://127.0.0.1 StreamProxy URL
   (progressive MP4 or the transmuxed HLS playlist — the same URLs AVPlayer is handed).
   All calls are from the main thread except where noted. */

#include <CoreGraphics/CoreGraphics.h>

typedef struct ffp_player ffp_player;

enum {
    FFP_OPENING = 0,   /* probing the input */
    FFP_READY   = 1,   /* open, first frame decoded or on its way, not playing */
    FFP_PLAYING = 2,
    FFP_PAUSED  = 3,
    FFP_ENDED   = 4,
    FFP_FAILED  = 5
};

/* One log file for the whole engine (FFmpeg's own warnings included). Optional. */
void        ffp_set_log_file(const char *path);
void        ffp_log_line(const char *line);

ffp_player *ffp_create(void);
/* Starts opening on a background thread; poll ffp_state. Returns 0, or -1 if the thread
   could not be started. */
int         ffp_open(ffp_player *p, const char *url);
/* Raw s16le stereo of exactly what goes to the speaker, after atempo. Call before ffp_open. */
void        ffp_set_dump_file(ffp_player *p, const char *path);
/* Ignore the audio stream (the clock runs on the wall). Call before ffp_open. */
void        ffp_set_video_only(ffp_player *p, int on);
/* Stretch with FFmpeg's atempo (float FFT) instead of the built-in integer WSOLA. Call
   before ffp_open. */
void        ffp_set_atempo(ffp_player *p, int on);
/* 0...1, the AudioQueue's own gain. */
void        ffp_set_volume(ffp_player *p, float volume);

void        ffp_play(ffp_player *p);
void        ffp_pause(ffp_player *p);
/* 0.5 ... 4.0; takes effect in the clock at once and in the sound within ~0.5s. */
void        ffp_set_speed(ffp_player *p, double speed);
double      ffp_speed(ffp_player *p);
/* Seconds from the start of the media; lands exactly on `seconds` (decodes up from the
   keyframe before it). */
void        ffp_seek(ffp_player *p, double seconds);

int         ffp_state(ffp_player *p);
double      ffp_position(ffp_player *p);
double      ffp_duration(ffp_player *p);
const char *ffp_error(ffp_player *p);
/* Coded size of the video stream, 0x0 until open (or for audio only). */
void        ffp_video_size(ffp_player *p, int *w, int *h);

/* The frame due now, or NULL if the one on screen is still current. Call once per screen
   refresh. The image owns its pixels until released, so a layer may hold on to it. */
CGImageRef  ffp_copy_frame(ffp_player *p) CF_RETURNS_RETAINED;

/* One line of counters for the POC log: decode cost, drops, clock source, buffers. */
void        ffp_stats_line(ffp_player *p, char *buf, int len);

/* Stops everything and frees the player once the last frame handed out is released. */
void        ffp_destroy(ffp_player *p);

#endif
