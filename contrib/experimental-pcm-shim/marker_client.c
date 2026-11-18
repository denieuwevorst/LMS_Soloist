#include <pulse/pulseaudio.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <pthread.h>
#include <unistd.h>

static pa_threaded_mainloop *ml;
static pa_stream *stream;
static long frames_left;
static uint64_t frame_index;
static int finished;

static void *flush_later(void *userdata)
{
    long delay_ms = (long) (intptr_t) userdata;
    pa_operation *operation;
    usleep((useconds_t) delay_ms * 1000);
    pa_threaded_mainloop_lock(ml);
    operation = pa_stream_flush(stream, NULL, NULL);
    if (operation) pa_operation_unref(operation);
    pa_threaded_mainloop_unlock(ml);
    return NULL;
}

static void signal_mainloop(pa_context *c, void *userdata)
{
    (void) c;
    (void) userdata;
    pa_threaded_mainloop_signal(ml, 0);
}

static void signal_stream(pa_stream *s, void *userdata)
{
    (void) s;
    (void) userdata;
    pa_threaded_mainloop_signal(ml, 0);
}

static void drained(pa_stream *s, int success, void *userdata)
{
    (void) s;
    (void) success;
    (void) userdata;
    finished = 1;
    pa_threaded_mainloop_signal(ml, 0);
}

static void write_markers(pa_stream *s, size_t nbytes, void *userdata)
{
    size_t frames = nbytes / 4;
    int16_t *buffer;
    (void) userdata;
    if ((long) frames > frames_left) frames = (size_t) frames_left;
    if (!frames) return;
    buffer = malloc(frames * 4);
    for (size_t i = 0; i < frames; i++) {
        int16_t marker = (int16_t) ((frame_index / 441) % 30000);
        buffer[i * 2] = marker;
        buffer[i * 2 + 1] = marker;
        frame_index++;
    }
    pa_stream_write(s, buffer, frames * 4, free, 0, PA_SEEK_RELATIVE);
    frames_left -= (long) frames;
    pa_threaded_mainloop_signal(ml, 0);
}

int main(int argc, char **argv)
{
    pa_sample_spec sample = { PA_SAMPLE_S16LE, 44100, 2 };
    pa_context *context;
    pa_operation *operation;
    pthread_t flush_thread;
    int flush_thread_started = 0;
    int seconds = argc > 1 ? atoi(argv[1]) : 3;
    long flush_after_ms = getenv("MARKER_PULSE_FLUSH_AFTER_MS")
        ? atol(getenv("MARKER_PULSE_FLUSH_AFTER_MS")) : 0;

    frames_left = 44100L * seconds;
    ml = pa_threaded_mainloop_new();
    context = pa_context_new(pa_threaded_mainloop_get_api(ml), "marker-test");
    pa_context_set_state_callback(context, signal_mainloop, NULL);
    pa_threaded_mainloop_lock(ml);
    pa_threaded_mainloop_start(ml);
    pa_context_connect(context, NULL, 0, NULL);
    while (pa_context_get_state(context) != PA_CONTEXT_READY)
        pa_threaded_mainloop_wait(ml);

    stream = pa_stream_new(context, "markers", &sample, NULL);
    pa_stream_set_state_callback(stream, signal_stream, NULL);
    pa_stream_set_write_callback(stream, write_markers, NULL);
    pa_stream_connect_playback(stream, NULL, NULL, 0, NULL, NULL);
    while (pa_stream_get_state(stream) != PA_STREAM_READY)
        pa_threaded_mainloop_wait(ml);
    if (flush_after_ms > 0) {
        flush_thread_started =
            pthread_create(&flush_thread, NULL, flush_later,
                           (void *) (intptr_t) flush_after_ms) == 0;
    }
    while (frames_left > 0)
        pa_threaded_mainloop_wait(ml);
    if (flush_thread_started) {
        pa_threaded_mainloop_unlock(ml);
        pthread_join(flush_thread, NULL);
        pa_threaded_mainloop_lock(ml);
    }

    operation = pa_stream_drain(stream, drained, NULL);
    while (!finished)
        pa_threaded_mainloop_wait(ml);
    pa_operation_unref(operation);
    pa_stream_disconnect(stream);
    pa_stream_unref(stream);
    pa_context_disconnect(context);
    pa_context_unref(context);
    pa_threaded_mainloop_unlock(ml);
    pa_threaded_mainloop_stop(ml);
    pa_threaded_mainloop_free(ml);
    return 0;
}
