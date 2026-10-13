/* Plays a sine tone through the real PulseAudio client API (async + threaded
 * mainloop), so this shim can be smoke-tested end-to-end without the real
 * (closed-source) Soloist binary. Link against the real pulse headers so
 * struct layouts/prototypes are checked by the compiler, then run against
 * this shim's libpulse.so.0 via LD_LIBRARY_PATH.
 */
#include <pulse/pulseaudio.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

static pa_threaded_mainloop *ml;
static pa_context *ctx;
static pa_stream *st;
static double phase;
static long frames_left;
static int rate = 48000;
static int finished;

static void ctx_cb(pa_context *c, void *u) { (void) c; (void) u; pa_threaded_mainloop_signal(ml, 0); }
static void st_cb(pa_stream *s, void *u) { (void) s; (void) u; pa_threaded_mainloop_signal(ml, 0); }
static void ok_cb(pa_stream *s, int ok, void *u) { (void) s; (void) ok; (void) u; finished = 1; pa_threaded_mainloop_signal(ml, 0); }

static void write_cb(pa_stream *s, size_t nbytes, void *u)
{
    (void) u;
    size_t nf = nbytes / (2 * sizeof(float));
    if ((long) nf > frames_left) nf = (size_t) frames_left;
    if (!nf) return;
    float *buf = malloc(nf * 2 * sizeof(float));
    for (size_t i = 0; i < nf; i++) {
        float v = (float) (0.5 * sin(phase));
        phase += 2 * M_PI * 440.0 / rate;
        buf[i * 2] = buf[i * 2 + 1] = v;
    }
    pa_stream_write(s, buf, nf * 2 * sizeof(float), free, 0, PA_SEEK_RELATIVE);
    frames_left -= (long) nf;
    pa_threaded_mainloop_signal(ml, 0);
}

int main(int argc, char **argv)
{
    pa_sample_spec ss = { PA_SAMPLE_FLOAT32LE, 48000, 2 };
    int secs = argc > 1 ? atoi(argv[1]) : 2;
    struct timespec a, b;

    frames_left = (long) rate * secs;
    clock_gettime(CLOCK_MONOTONIC, &a);
    ml = pa_threaded_mainloop_new();
    ctx = pa_context_new(pa_threaded_mainloop_get_api(ml), "test");
    pa_context_set_state_callback(ctx, ctx_cb, NULL);
    pa_threaded_mainloop_lock(ml);
    pa_threaded_mainloop_start(ml);
    pa_context_connect(ctx, NULL, 0, NULL);
    while (pa_context_get_state(ctx) != PA_CONTEXT_READY) pa_threaded_mainloop_wait(ml);

    st = pa_stream_new(ctx, "tone", &ss, NULL);
    pa_stream_set_state_callback(st, st_cb, NULL);
    pa_stream_set_write_callback(st, write_cb, NULL);
    pa_stream_connect_playback(st, NULL, NULL, 0, NULL, NULL);
    while (pa_stream_get_state(st) != PA_STREAM_READY) pa_threaded_mainloop_wait(ml);

    while (frames_left > 0) pa_threaded_mainloop_wait(ml);   /* woken by the write callback */
    pa_operation *op = pa_stream_drain(st, ok_cb, NULL);
    while (!finished) pa_threaded_mainloop_wait(ml);
    pa_operation_unref(op);
    pa_stream_disconnect(st);
    pa_stream_unref(st);
    pa_context_disconnect(ctx);
    pa_context_unref(ctx);
    pa_threaded_mainloop_unlock(ml);
    pa_threaded_mainloop_stop(ml);
    pa_threaded_mainloop_free(ml);
    clock_gettime(CLOCK_MONOTONIC, &b);
    fprintf(stderr, "client done: %.2fs elapsed\n", (b.tv_sec - a.tv_sec) + (b.tv_nsec - a.tv_nsec) / 1e9);
    return 0;
}
