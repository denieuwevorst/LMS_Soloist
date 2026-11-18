/*
 * soloist-lms-shim: a minimal libpulse.so.0 stand-in.
 *
 * Applications that only speak PulseAudio (Spotify Soloist) load this instead
 * of the real library. Everything a stream plays is converted to one fixed
 * PCM format/rate and written to a FIFO, a unix socket or a plain file, so a
 * Lyrion Music Server (LMS) player can read it.
 *
 * Environment:
 *   SOLOIST_SHIM_OUT     path to FIFO / unix socket / file   (/tmp/soloist-pcm.fifo)
 *   SOLOIST_SHIM_FORMAT  s16 | s24 | s32 (interleaved stereo LE)   (s24, packed)
 *   SOLOIST_SHIM_RATE    output rate in Hz, 0 = pass through       (44100)
 *   SOLOIST_SHIM_LOG     0 quiet, 1 info, 2 trace API calls         (0)
 *   SOLOIST_SHIM_RING_MS bounded live-edge ring depth               (200)
 *   SOLOIST_SHIM_MODE    live-ring | compat                    (live-ring)
 *   SOLOIST_SHIM_CONTROL generation/flush command file              (unset)
 *   SOLOIST_SHIM_ACK     generation acknowledgement file            (unset)
 *   SOLOIST_SHIM_MAX_TLENGTH_MS  clamp requested tlength/prebuf/minreq
 *                     to this many ms to keep Soloist's virtual playback
 *                     clock close to real drained audio              (0=off)
 *
 * Playback is paced against the wall clock, so the reader sees real-time PCM
 * no matter how fast the application writes. Live-ring mode preserves the
 * application's normal Pulse buffering contract, but discards PCM whose
 * scheduled presentation time is older than the configured live-edge budget.
 */
#define _GNU_SOURCE
#include <pulse/pulseaudio.h>
#include <pulse/rtclock.h>

#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

/* ------------------------------------------------------------------ config */

static struct {
    char out[512], control[512], ack[512];
    int bytes, rate, log, max_tlength_ms, ring_ms, compat;
    uint64_t counter_base_frames;
} cfg;
static pthread_once_t cfg_once = PTHREAD_ONCE_INIT;

static void cfg_init(void)
{
    const char *e;
    snprintf(cfg.out, sizeof cfg.out, "%s",
             (e = getenv("SOLOIST_SHIM_OUT")) && *e ? e : "/tmp/soloist-pcm.fifo");
    cfg.bytes = 3;
    if ((e = getenv("SOLOIST_SHIM_FORMAT"))) {
        if (!strcmp(e, "s16")) cfg.bytes = 2;
        else if (!strcmp(e, "s32")) cfg.bytes = 4;
    }
    cfg.rate = 44100;
    if ((e = getenv("SOLOIST_SHIM_RATE"))) cfg.rate = atoi(e);
    cfg.log = (e = getenv("SOLOIST_SHIM_LOG")) ? atoi(e) : 0;
    cfg.max_tlength_ms = (e = getenv("SOLOIST_SHIM_MAX_TLENGTH_MS")) ? atoi(e) : 0;
    cfg.ring_ms = (e = getenv("SOLOIST_SHIM_RING_MS")) ? atoi(e) : 200;
    if (cfg.ring_ms < 20) cfg.ring_ms = 20;
    if (cfg.ring_ms > 1000) cfg.ring_ms = 1000;
    snprintf(cfg.control, sizeof cfg.control, "%s",
             (e = getenv("SOLOIST_SHIM_CONTROL")) && *e ? e : "");
    snprintf(cfg.ack, sizeof cfg.ack, "%s",
             (e = getenv("SOLOIST_SHIM_ACK")) && *e ? e : "");
    cfg.compat = (e = getenv("SOLOIST_SHIM_MODE")) &&
                 (!strcmp(e, "compat") || !strcmp(e, "legacy"));
    cfg.counter_base_frames = (e = getenv("SOLOIST_SHIM_TEST_COUNTER_BASE_FRAMES"))
        ? strtoull(e, NULL, 10) : 0;
}
#define CFG() pthread_once(&cfg_once, cfg_init)
#define LOG(l, ...) do { CFG(); if (cfg.log >= (l)) { \
    fprintf(stderr, "[soloist-shim] " __VA_ARGS__); fputc('\n', stderr); } } while (0)

__attribute__((constructor))
static void shim_loaded(void)
{
    CFG();
    fprintf(stderr, "[soloist-shim] loaded build 2026-11-18.6-frameunits: mode=%s out=%s format=%dB rate=%d ring_ms=%d max_tlength_ms=%d control=%s\n",
        cfg.compat ? "compat" : "live-ring",
        cfg.out, cfg.bytes, cfg.rate, cfg.ring_ms, cfg.max_tlength_ms,
        cfg.control[0] ? cfg.control : "off");
}

static uint64_t now_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t) ts.tv_sec * 1000000000ull + (uint64_t) ts.tv_nsec;
}

#define REF(p)   __atomic_add_fetch(&(p)->refcnt, 1, __ATOMIC_SEQ_CST)
#define UNREF(p) __atomic_sub_fetch(&(p)->refcnt, 1, __ATOMIC_SEQ_CST)

/* -------------------------------------------------------------- output sink */

static struct {
    pthread_mutex_t lk;
    int fd, is_sock;
    uint64_t next_try_ns, dropped, last_drop_log_ns, last_pressure_log_ns;
    uint64_t eagain_count, partial_count, max_wait_ns, max_queued_usec;
    unsigned char pending[8];
    size_t pending_len;
} out = {
    .lk = PTHREAD_MUTEX_INITIALIZER,
    .fd = -1
};

static int out_open_locked(void)
{
    struct stat st;
    uint64_t t = now_ns();
    int fd;

    if (out.fd >= 0) return 0;
    if (t < out.next_try_ns) return -1;
    out.next_try_ns = t + 250000000ull;

    if (stat(cfg.out, &st) < 0) {
        if (errno != ENOENT || mkfifo(cfg.out, 0660) < 0 || stat(cfg.out, &st) < 0)
            return -1;
    }
    if (S_ISSOCK(st.st_mode)) {
        struct sockaddr_un a;
        size_t path_len = strlen(cfg.out);
        if (path_len >= sizeof a.sun_path) {
            errno = ENAMETOOLONG;
            return -1;
        }
        memset(&a, 0, sizeof a);
        a.sun_family = AF_UNIX;
        memcpy(a.sun_path, cfg.out, path_len + 1);
        fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
        if (fd < 0) return -1;
        if (connect(fd, (struct sockaddr *) &a, sizeof a) < 0) { close(fd); return -1; }
        out.is_sock = 1;
    } else if (S_ISFIFO(st.st_mode)) {
        int pipe_size;
        /* ENXIO while no reader has the FIFO open: stay silent and retry. */
        fd = open(cfg.out, O_WRONLY | O_NONBLOCK | O_CLOEXEC);
        if (fd < 0) return -1;
        /*
         * Keep the kernel queue below 100 ms at the plugin's 44.1 kHz s16
         * stereo format. The userspace ring owns the deliberate buffering;
         * a large FIFO would preserve stale audio that cannot be dropped
         * from the head by the writer.
         */
        fcntl(fd, F_SETPIPE_SZ, 16384);
        pipe_size = fcntl(fd, F_GETPIPE_SZ);
        if (pipe_size > 0) {
            int output_rate = cfg.rate > 0 ? cfg.rate : 44100;
            LOG(1, "FIFO kernel queue: %d bytes (%.1f ms at configured output)",
                pipe_size, 1000.0 * pipe_size / (output_rate * cfg.bytes * 2));
        }
        out.is_sock = 0;
    } else {
        fd = open(cfg.out, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
        if (fd < 0) return -1;
        out.is_sock = 0;
    }
    out.fd = fd;
    LOG(1, "output connected: %s", cfg.out);
    return 0;
}

static void out_log_activity_locked(void)
{
    uint64_t t = now_ns();
    if (out.dropped && t - out.last_drop_log_ns >= 1000000000ull) {
        LOG(1, "output live-edge drop: %llu bytes while FIFO unavailable/slow",
            (unsigned long long) out.dropped);
        out.dropped = 0;
        out.last_drop_log_ns = t;
    }
    if ((out.eagain_count || out.partial_count) &&
        t - out.last_pressure_log_ns >= 1000000000ull) {
        LOG(1, "output pressure: eagain=%llu partial=%llu max_wait=%.1f ms max_queued=%.1f ms",
            (unsigned long long) out.eagain_count,
            (unsigned long long) out.partial_count,
            out.max_wait_ns / 1000000.0,
            out.max_queued_usec / 1000.0);
        out.eagain_count = 0;
        out.partial_count = 0;
        out.max_wait_ns = 0;
        out.max_queued_usec = 0;
        out.last_pressure_log_ns = t;
    }
}

static void control_check_locked(pa_stream *s);
static int chunk_is_current(pa_stream *s, unsigned long generation,
                            uint64_t overflow_serial);
static uint64_t stream_queued_usec(pa_stream *s);

static void out_write(pa_stream *s, const unsigned char *b, size_t len,
                      size_t frame_size, unsigned long generation,
                      uint64_t overflow_serial)
{
    size_t off = 0;
    uint64_t wait_started = 0;
    uint64_t wait_limit_ns = (uint64_t) cfg.ring_ms * 1000000ull;
    if (cfg.compat) wait_limit_ns = 200000000ull;

    pthread_mutex_lock(&out.lk);
    if (out_open_locked() < 0) {
        out.dropped += len;
        out_log_activity_locked();
        pthread_mutex_unlock(&out.lk);
        return;
    }
    while (out.pending_len) {
        ssize_t n = out.is_sock
            ? send(out.fd, out.pending, out.pending_len, MSG_NOSIGNAL)
            : write(out.fd, out.pending, out.pending_len);
        if (n > 0) {
            if ((size_t) n < out.pending_len) out.partial_count++;
            out.pending_len -= (size_t) n;
            if (out.pending_len)
                memmove(out.pending, out.pending + n, out.pending_len);
            continue;
        }
        if (n < 0 && errno == EINTR) continue;
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            struct pollfd p = { out.fd, POLLOUT, 0 };
            uint64_t t = now_ns();
            if (!wait_started) wait_started = t;
            out.eagain_count++;
            {
                uint64_t queued = stream_queued_usec(s);
                if (queued > out.max_queued_usec) out.max_queued_usec = queued;
            }
            if (!chunk_is_current(s, generation, overflow_serial) ||
                t - wait_started >= wait_limit_ns) {
                out.dropped += len;
                close(out.fd);
                out.fd = -1;
                out.pending_len = 0;
                out_log_activity_locked();
                pthread_mutex_unlock(&out.lk);
                return;
            }
            poll(&p, 1, 5);
            continue;
        }
        LOG(1, "output closed while completing a partial frame: %s", strerror(errno));
        close(out.fd);
        out.fd = -1;
        out.pending_len = 0;
        out.dropped += len;
        pthread_mutex_unlock(&out.lk);
        return;
    }
    while (off < len) {
        size_t chunk = len - off;
        ssize_t n;
        if (!out.is_sock && chunk > 4096) chunk = 4096;
        chunk -= chunk % frame_size;
        if (!chunk) chunk = frame_size;
        n = out.is_sock ? send(out.fd, b + off, chunk, MSG_NOSIGNAL)
                        : write(out.fd, b + off, chunk);
        if (n > 0) {
            if ((size_t) n < chunk) out.partial_count++;
            off += (size_t) n;
            if ((size_t) n % frame_size) {
                size_t needed = frame_size - (size_t) n % frame_size;
                memcpy(out.pending, b + off, needed);
                out.pending_len = needed;
                off += needed;
                while (out.pending_len) {
                    n = out.is_sock
                        ? send(out.fd, out.pending, out.pending_len, MSG_NOSIGNAL)
                        : write(out.fd, out.pending, out.pending_len);
                    if (n > 0) {
                        out.pending_len -= (size_t) n;
                        if (out.pending_len)
                            memmove(out.pending, out.pending + n, out.pending_len);
                        continue;
                    }
                    if (n < 0 && errno == EINTR) continue;
                    if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
                        struct pollfd p = { out.fd, POLLOUT, 0 };
                        uint64_t t = now_ns();
                        if (!wait_started) wait_started = t;
                        out.eagain_count++;
                        {
                            uint64_t queued = stream_queued_usec(s);
                            if (queued > out.max_queued_usec) out.max_queued_usec = queued;
                        }
                        if (!chunk_is_current(s, generation, overflow_serial) ||
                            t - wait_started >= wait_limit_ns) {
                            out.dropped += len - off;
                            close(out.fd);
                            out.fd = -1;
                            out.pending_len = 0;
                            off = len;
                            break;
                        }
                        poll(&p, 1, 5);
                        continue;
                    }
                    LOG(1, "output closed during partial frame: %s", strerror(errno));
                    close(out.fd);
                    out.fd = -1;
                    out.pending_len = 0;
                    out.dropped += len - off;
                    off = len;
                    break;
                }
            }
            continue;
        }
        if (n < 0 && errno == EINTR) continue;
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            struct pollfd p = { out.fd, POLLOUT, 0 };
            uint64_t t = now_ns();
            if (!wait_started) wait_started = t;
            out.eagain_count++;
            {
                uint64_t queued = stream_queued_usec(s);
                if (queued > out.max_queued_usec) out.max_queued_usec = queued;
            }
            if (!chunk_is_current(s, generation, overflow_serial) ||
                t - wait_started >= wait_limit_ns) {
                out.dropped += len - off;
                break;
            }
            poll(&p, 1, 5);
            continue;
        }
        /* EPIPE (reader went away) or a hard error: close, reopen later */
        {
            sigset_t ss;
            struct timespec z = { 0, 0 };
            sigemptyset(&ss);
            sigaddset(&ss, SIGPIPE);
            sigtimedwait(&ss, NULL, &z);          /* swallow the pending SIGPIPE */
        }
        LOG(1, "output closed (%s)", strerror(errno));
        close(out.fd);
        out.fd = -1;
        out.dropped += len - off;
        out_log_activity_locked();
        break;
    }
    if (wait_started) {
        uint64_t waited = now_ns() - wait_started;
        if (waited > out.max_wait_ns) out.max_wait_ns = waited;
    }
    out_log_activity_locked();
    pthread_mutex_unlock(&out.lk);
}

/* ---------------------------------------------------------------- mainloop */

typedef struct ev { struct ev *next; void (*fn)(void *); void *arg; } ev_t;

struct pa_threaded_mainloop {
    pa_mainloop_api api;                 /* api.userdata points back at us */
    pthread_mutex_t m;                   /* the user-visible main lock (recursive) */
    pthread_mutex_t q;                   /* protects the event queue */
    pthread_cond_t ev_cond, wait_cond, accept_cond;
    ev_t *head, *tail;
    pthread_t th;
    int started, quit, n_waiting, n_waiting_accept;
};

struct pa_mainloop {
    struct pa_threaded_mainloop tm;
    int quit_flag, retval;
};

static void ml_init(struct pa_threaded_mainloop *m)
{
    pthread_mutexattr_t a;
    memset(m, 0, sizeof *m);
    pthread_mutexattr_init(&a);
    pthread_mutexattr_settype(&a, PTHREAD_MUTEX_RECURSIVE);
    pthread_mutex_init(&m->m, &a);
    pthread_mutexattr_destroy(&a);
    pthread_mutex_init(&m->q, NULL);
    pthread_cond_init(&m->ev_cond, NULL);
    pthread_cond_init(&m->wait_cond, NULL);
    pthread_cond_init(&m->accept_cond, NULL);
    m->api.userdata = m;
}

static void ml_destroy(struct pa_threaded_mainloop *m)
{
    ev_t *e;
    while ((e = m->head)) { m->head = e->next; free(e); }
    pthread_mutex_destroy(&m->m);
    pthread_mutex_destroy(&m->q);
    pthread_cond_destroy(&m->ev_cond);
    pthread_cond_destroy(&m->wait_cond);
    pthread_cond_destroy(&m->accept_cond);
}

static void ml_post(pa_threaded_mainloop *m, void (*fn)(void *), void *arg)
{
    ev_t *e = calloc(1, sizeof *e);
    e->fn = fn;
    e->arg = arg;
    pthread_mutex_lock(&m->q);
    if (m->tail) m->tail->next = e; else m->head = e;
    m->tail = e;
    pthread_cond_signal(&m->ev_cond);
    pthread_mutex_unlock(&m->q);
}

static void *ml_thread(void *arg)
{
    pa_threaded_mainloop *m = arg;
    for (;;) {
        ev_t *e;
        pthread_mutex_lock(&m->q);
        while (!m->head && !m->quit) pthread_cond_wait(&m->ev_cond, &m->q);
        if (m->quit) { pthread_mutex_unlock(&m->q); break; }
        e = m->head;
        m->head = e->next;
        if (!m->head) m->tail = NULL;
        pthread_mutex_unlock(&m->q);
        pthread_mutex_lock(&m->m);
        e->fn(e->arg);
        pthread_mutex_unlock(&m->m);
        free(e);
    }
    return NULL;
}

pa_threaded_mainloop *pa_threaded_mainloop_new(void)
{
    pa_threaded_mainloop *m = malloc(sizeof *m);
    ml_init(m);
    LOG(2, "threaded_mainloop_new");
    return m;
}
int pa_threaded_mainloop_start(pa_threaded_mainloop *m)
{
    if (m->started) return -1;
    m->started = 1;
    return pthread_create(&m->th, NULL, ml_thread, m) ? -1 : 0;
}
void pa_threaded_mainloop_stop(pa_threaded_mainloop *m)
{
    if (!m->started) return;
    pthread_mutex_lock(&m->q);
    m->quit = 1;
    pthread_cond_broadcast(&m->ev_cond);
    pthread_mutex_unlock(&m->q);
    pthread_join(m->th, NULL);
    m->started = 0;
    m->quit = 0;
}
void pa_threaded_mainloop_free(pa_threaded_mainloop *m)
{
    if (!m) return;
    pa_threaded_mainloop_stop(m);
    ml_destroy(m);
    free(m);
}
void pa_threaded_mainloop_lock(pa_threaded_mainloop *m)   { pthread_mutex_lock(&m->m); }
void pa_threaded_mainloop_unlock(pa_threaded_mainloop *m) { pthread_mutex_unlock(&m->m); }
void pa_threaded_mainloop_wait(pa_threaded_mainloop *m)
{
    m->n_waiting++;
    pthread_cond_wait(&m->wait_cond, &m->m);
    m->n_waiting--;
}
void pa_threaded_mainloop_signal(pa_threaded_mainloop *m, int wait_for_accept)
{
    if (m->n_waiting <= 0) return;
    pthread_cond_broadcast(&m->wait_cond);
    if (wait_for_accept) {
        m->n_waiting_accept++;
        while (m->n_waiting_accept > 0) pthread_cond_wait(&m->accept_cond, &m->m);
    }
}
void pa_threaded_mainloop_accept(pa_threaded_mainloop *m)
{
    if (m->n_waiting_accept <= 0) return;
    m->n_waiting_accept--;
    pthread_cond_signal(&m->accept_cond);
}
int pa_threaded_mainloop_get_retval(const pa_threaded_mainloop *m) { (void) m; return 0; }
pa_mainloop_api *pa_threaded_mainloop_get_api(pa_threaded_mainloop *m) { return &m->api; }
int pa_threaded_mainloop_in_thread(pa_threaded_mainloop *m)
{
    return m->started && pthread_equal(pthread_self(), m->th);
}
void pa_threaded_mainloop_set_name(pa_threaded_mainloop *m, const char *name) { (void) m; (void) name; }

/* plain (non-threaded) mainloop built on the same event queue */
pa_mainloop *pa_mainloop_new(void)
{
    pa_mainloop *m = calloc(1, sizeof *m);
    ml_init(&m->tm);
    return m;
}
void pa_mainloop_free(pa_mainloop *m)
{
    if (!m) return;
    ml_destroy(&m->tm);
    free(m);
}
pa_mainloop_api *pa_mainloop_get_api(pa_mainloop *m) { return &m->tm.api; }
int pa_mainloop_prepare(pa_mainloop *m, int timeout) { (void) m; (void) timeout; return 0; }
int pa_mainloop_poll(pa_mainloop *m) { (void) m; return 0; }
int pa_mainloop_dispatch(pa_mainloop *m) { (void) m; return 0; }
int pa_mainloop_get_retval(const pa_mainloop *m) { return m->retval; }
void pa_mainloop_wakeup(pa_mainloop *m)
{
    pthread_mutex_lock(&m->tm.q);
    pthread_cond_broadcast(&m->tm.ev_cond);
    pthread_mutex_unlock(&m->tm.q);
}
void pa_mainloop_quit(pa_mainloop *m, int retval)
{
    m->retval = retval;
    m->quit_flag = 1;
    pa_mainloop_wakeup(m);
}
int pa_mainloop_iterate(pa_mainloop *m, int block, int *retval)
{
    ev_t *list, *e;
    int n = 0;

    pthread_mutex_lock(&m->tm.q);
    while (!m->tm.head && block && !m->quit_flag) pthread_cond_wait(&m->tm.ev_cond, &m->tm.q);
    list = m->tm.head;
    m->tm.head = m->tm.tail = NULL;
    pthread_mutex_unlock(&m->tm.q);
    while ((e = list)) {
        list = e->next;
        pthread_mutex_lock(&m->tm.m);
        e->fn(e->arg);
        pthread_mutex_unlock(&m->tm.m);
        free(e);
        n++;
    }
    if (m->quit_flag) { if (retval) *retval = m->retval; return -2; }
    return n;
}
int pa_mainloop_run(pa_mainloop *m, int *retval)
{
    int r;
    while ((r = pa_mainloop_iterate(m, 1, retval)) >= 0) ;
    return r == -2 ? 0 : -1;
}

/* ------------------------------------------------------- small utility API */

void *pa_xmalloc(size_t l)  { return malloc(l ? l : 1); }
void *pa_xmalloc0(size_t l) { return calloc(1, l ? l : 1); }
void *pa_xrealloc(void *p, size_t l) { return realloc(p, l ? l : 1); }
void *pa_xmemdup(const void *p, size_t l) { void *r = malloc(l ? l : 1); memcpy(r, p, l); return r; }
char *pa_xstrdup(const char *s) { return s ? strdup(s) : NULL; }
char *pa_xstrndup(const char *s, size_t l) { return s ? strndup(s, l) : NULL; }
void pa_xfree(void *p) { free(p); }

const char *pa_get_library_version(void) { return "16.1-soloist-lms-shim"; }
pa_usec_t pa_rtclock_now(void) { return now_ns() / 1000; }
struct timeval *pa_gettimeofday(struct timeval *tv)
{
    gettimeofday(tv, NULL);
    return tv;
}
pa_usec_t pa_timeval_diff(const struct timeval *a, const struct timeval *b)
{
    int64_t usec = ((int64_t) a->tv_sec - (int64_t) b->tv_sec) * 1000000ll
                 + ((int64_t) a->tv_usec - (int64_t) b->tv_usec);
    return usec > 0 ? (pa_usec_t) usec : 0;
}

const char *pa_strerror(int error)
{
    switch (error) {
    case PA_OK: return "OK";
    case PA_ERR_ACCESS: return "Access denied";
    case PA_ERR_INVALID: return "Invalid argument";
    case PA_ERR_NOTIMPLEMENTED: return "Not implemented in soloist-lms-shim";
    case PA_ERR_CONNECTIONREFUSED: return "Connection refused";
    case PA_ERR_BADSTATE: return "Bad state";
    default: return "Error in soloist-lms-shim";
    }
}

size_t pa_sample_size_of_format(pa_sample_format_t f)
{
    switch (f) {
    case PA_SAMPLE_U8: case PA_SAMPLE_ALAW: case PA_SAMPLE_ULAW: return 1;
    case PA_SAMPLE_S16LE: case PA_SAMPLE_S16BE: return 2;
    case PA_SAMPLE_S24LE: case PA_SAMPLE_S24BE: return 3;
    case PA_SAMPLE_S32LE: case PA_SAMPLE_S32BE: case PA_SAMPLE_FLOAT32LE:
    case PA_SAMPLE_FLOAT32BE: case PA_SAMPLE_S24_32LE: case PA_SAMPLE_S24_32BE: return 4;
    default: return 0;
    }
}
size_t pa_sample_size(const pa_sample_spec *s) { return pa_sample_size_of_format(s->format); }
size_t pa_frame_size(const pa_sample_spec *s) { return pa_sample_size(s) * s->channels; }
size_t pa_bytes_per_second(const pa_sample_spec *s) { return pa_frame_size(s) * s->rate; }
pa_usec_t pa_bytes_to_usec(uint64_t l, const pa_sample_spec *s)
{
    size_t fs = pa_frame_size(s);
    return fs && s->rate ? (pa_usec_t) (((l / fs) * 1000000ull) / s->rate) : 0;
}
size_t pa_usec_to_bytes(pa_usec_t t, const pa_sample_spec *s)
{
    return (size_t) (((t * s->rate) / 1000000ull) * pa_frame_size(s));
}
int pa_sample_format_valid(unsigned f) { return f < PA_SAMPLE_MAX; }
int pa_sample_spec_valid(const pa_sample_spec *s)
{
    return s && s->rate > 0 && s->channels > 0 && s->channels <= PA_CHANNELS_MAX
        && pa_sample_format_valid(s->format);
}
int pa_sample_spec_equal(const pa_sample_spec *a, const pa_sample_spec *b)
{
    return a->format == b->format && a->rate == b->rate && a->channels == b->channels;
}
pa_sample_spec *pa_sample_spec_init(pa_sample_spec *s)
{
    s->format = PA_SAMPLE_S16LE; s->rate = 44100; s->channels = 2;
    return s;
}

pa_channel_map *pa_channel_map_init(pa_channel_map *m)
{
    m->channels = 0;
    for (unsigned i = 0; i < PA_CHANNELS_MAX; i++) m->map[i] = PA_CHANNEL_POSITION_INVALID;
    return m;
}
pa_channel_map *pa_channel_map_init_mono(pa_channel_map *m)
{
    pa_channel_map_init(m);
    m->channels = 1;
    m->map[0] = PA_CHANNEL_POSITION_MONO;
    return m;
}
pa_channel_map *pa_channel_map_init_stereo(pa_channel_map *m)
{
    pa_channel_map_init(m);
    m->channels = 2;
    m->map[0] = PA_CHANNEL_POSITION_FRONT_LEFT;
    m->map[1] = PA_CHANNEL_POSITION_FRONT_RIGHT;
    return m;
}
pa_channel_map *pa_channel_map_init_auto(pa_channel_map *m, unsigned c, pa_channel_map_def_t def)
{
    (void) def;
    if (c == 1) return pa_channel_map_init_mono(m);
    pa_channel_map_init_stereo(m);
    return c == 2 ? m : NULL;
}
pa_channel_map *pa_channel_map_init_extend(pa_channel_map *m, unsigned c, pa_channel_map_def_t def)
{
    return pa_channel_map_init_auto(m, c, def);
}
int pa_channel_map_valid(const pa_channel_map *m) { return m && m->channels > 0; }

pa_cvolume *pa_cvolume_init(pa_cvolume *a)
{
    a->channels = 0;
    for (unsigned i = 0; i < PA_CHANNELS_MAX; i++) a->values[i] = PA_VOLUME_INVALID;
    return a;
}
pa_cvolume *pa_cvolume_set(pa_cvolume *a, unsigned channels, pa_volume_t v)
{
    a->channels = (uint8_t) channels;
    for (unsigned i = 0; i < channels && i < PA_CHANNELS_MAX; i++) a->values[i] = v;
    return a;
}
pa_volume_t pa_cvolume_avg(const pa_cvolume *a)
{
    uint64_t sum = 0;
    if (!a->channels) return PA_VOLUME_MUTED;
    for (unsigned i = 0; i < a->channels; i++) sum += a->values[i];
    return (pa_volume_t) (sum / a->channels);
}
pa_volume_t pa_cvolume_max(const pa_cvolume *a)
{
    pa_volume_t m = PA_VOLUME_MUTED;
    for (unsigned i = 0; i < a->channels; i++) if (a->values[i] > m) m = a->values[i];
    return m;
}
int pa_cvolume_valid(const pa_cvolume *v) { return v && v->channels > 0 && v->channels <= PA_CHANNELS_MAX; }
double pa_sw_volume_to_linear(pa_volume_t v)
{
    double f = (double) v / (double) PA_VOLUME_NORM;
    return f * f * f;
}
pa_volume_t pa_sw_volume_from_linear(double v)
{
    return v <= 0.0 ? PA_VOLUME_MUTED : (pa_volume_t) (cbrt(v) * PA_VOLUME_NORM + 0.5);
}

/* proplists carry nothing here; accept and ignore them */
struct pa_proplist { int dummy; };
pa_proplist *pa_proplist_new(void) { return calloc(1, sizeof(pa_proplist)); }
void pa_proplist_free(pa_proplist *p) { free(p); }
int pa_proplist_sets(pa_proplist *p, const char *k, const char *v) { (void) p; (void) k; (void) v; return 0; }
int pa_proplist_setf(pa_proplist *p, const char *k, const char *fmt, ...) { (void) p; (void) k; (void) fmt; return 0; }
const char *pa_proplist_gets(const pa_proplist *p, const char *k) { (void) p; (void) k; return NULL; }
int pa_proplist_contains(const pa_proplist *p, const char *k) { (void) p; (void) k; return 0; }
pa_proplist *pa_proplist_copy(const pa_proplist *p) { (void) p; return pa_proplist_new(); }
int pa_proplist_unset(pa_proplist *p, const char *k) { (void) p; (void) k; return 0; }

/* -------------------------------------------------------- context & operations */

struct pa_context {
    int refcnt;
    pa_threaded_mainloop *ml;
    pa_context_state_t state;
    pa_context_notify_cb_t state_cb; void *state_ud;
    int err;
};

enum { OP_STREAM_OK, OP_CTX_OK, OP_SERVER_INFO, OP_SINK_INFO, OP_SINK_INPUT_INFO };

struct pa_operation {
    int refcnt;
    pa_operation_state_t state;
    pa_context *c;
    pa_stream *s;
    int kind;
    void *cb, *ud;
    int success;
};

static void ctx_free(pa_context *c) { free(c); }

pa_context *pa_context_ref(pa_context *c) { REF(c); return c; }
void pa_context_unref(pa_context *c) { if (c && UNREF(c) == 0) ctx_free(c); }

static pa_context *ctx_new(pa_mainloop_api *api, const char *name)
{
    pa_context *c;
    (void) name;
    if (!api || !api->userdata) return NULL;
    c = calloc(1, sizeof *c);
    c->refcnt = 1;
    c->ml = api->userdata;
    c->state = PA_CONTEXT_UNCONNECTED;
    LOG(2, "context_new(%s)", name ? name : "?");
    return c;
}
pa_context *pa_context_new(pa_mainloop_api *api, const char *name) { return ctx_new(api, name); }
pa_context *pa_context_new_with_proplist(pa_mainloop_api *api, const char *name, const pa_proplist *p)
{
    (void) p;
    return ctx_new(api, name);
}

struct ev_ctx_state { pa_context *c; pa_context_state_t st; int quiet; };
static void ev_ctx_state_fn(void *a)
{
    struct ev_ctx_state *e = a;
    pa_context *c = e->c;
    c->state = e->st;
    if (c->state_cb) c->state_cb(c, c->state_ud);
    pa_context_unref(c);
    free(e);
}
static void ctx_post_state(pa_context *c, pa_context_state_t st)
{
    struct ev_ctx_state *e = calloc(1, sizeof *e);
    e->c = pa_context_ref(c);
    e->st = st;
    ml_post(c->ml, ev_ctx_state_fn, e);
}

void pa_context_set_state_callback(pa_context *c, pa_context_notify_cb_t cb, void *ud) { c->state_cb = cb; c->state_ud = ud; }
void pa_context_set_event_callback(pa_context *c, pa_context_event_cb_t cb, void *ud) { (void) c; (void) cb; (void) ud; }
void pa_context_set_subscribe_callback(pa_context *c, pa_context_subscribe_cb_t cb, void *ud) { (void) c; (void) cb; (void) ud; }
pa_context_state_t pa_context_get_state(const pa_context *c) { return c->state; }
int pa_context_errno(const pa_context *c) { return c ? c->err : PA_ERR_INVALID; }
int pa_context_is_pending(const pa_context *c) { (void) c; return 0; }
int pa_context_is_local(const pa_context *c) { (void) c; return 1; }
const char *pa_context_get_server(const pa_context *c) { (void) c; return "soloist-lms-shim"; }
uint32_t pa_context_get_protocol_version(const pa_context *c) { (void) c; return PA_PROTOCOL_VERSION; }
uint32_t pa_context_get_server_protocol_version(const pa_context *c) { (void) c; return PA_PROTOCOL_VERSION; }

int pa_context_connect(pa_context *c, const char *server, pa_context_flags_t flags, const pa_spawn_api *api)
{
    (void) server; (void) flags; (void) api;
    LOG(1, "context_connect");
    CFG();
    c->state = PA_CONTEXT_CONNECTING;
    ctx_post_state(c, PA_CONTEXT_CONNECTING);
    ctx_post_state(c, PA_CONTEXT_READY);
    return 0;
}
void pa_context_disconnect(pa_context *c)
{
    LOG(2, "context_disconnect");
    c->state = PA_CONTEXT_TERMINATED;
    ctx_post_state(c, PA_CONTEXT_TERMINATED);
}

static void op_fire(void *a)
{
    pa_operation *o = a;
    if (o->state == PA_OPERATION_RUNNING) {
        o->state = PA_OPERATION_DONE;
        switch (o->kind) {
        case OP_STREAM_OK:
            if (o->cb) ((pa_stream_success_cb_t) o->cb)(o->s, o->success, o->ud);
            break;
        case OP_CTX_OK:
            if (o->cb) ((pa_context_success_cb_t) o->cb)(o->c, o->success, o->ud);
            break;
        case OP_SERVER_INFO:
            if (o->cb) {
                pa_server_info si;
                memset(&si, 0, sizeof si);
                si.user_name = "soloist";
                si.host_name = "localhost";
                si.server_version = "16.1";
                si.server_name = "soloist-lms-shim";
                si.sample_spec.format = PA_SAMPLE_S16LE;
                si.sample_spec.rate = 44100;
                si.sample_spec.channels = 2;
                si.default_sink_name = "soloist_lms";
                si.default_source_name = "soloist_lms.monitor";
                pa_channel_map_init_stereo(&si.channel_map);
                ((pa_server_info_cb_t) o->cb)(o->c, &si, o->ud);
            }
            break;
        case OP_SINK_INFO:
            if (o->cb) {
                pa_sink_info k;
                memset(&k, 0, sizeof k);
                k.name = "soloist_lms";
                k.description = "Soloist to LMS shim";
                k.sample_spec.format = PA_SAMPLE_S16LE;
                k.sample_spec.rate = 44100;
                k.sample_spec.channels = 2;
                pa_channel_map_init_stereo(&k.channel_map);
                pa_cvolume_set(&k.volume, 2, PA_VOLUME_NORM);
                k.state = PA_SINK_RUNNING;
                k.driver = "soloist-lms-shim";
                ((pa_sink_info_cb_t) o->cb)(o->c, &k, 0, o->ud);
                ((pa_sink_info_cb_t) o->cb)(o->c, NULL, 1, o->ud);
            }
            break;
        case OP_SINK_INPUT_INFO:
            if (o->cb) {
                pa_sink_input_info k;
                memset(&k, 0, sizeof k);
                k.index = 1;
                k.name = "Soloist";
                k.owner_module = PA_INVALID_INDEX;
                k.client = 1;
                k.sink = 0;
                k.sample_spec.format = PA_SAMPLE_S16LE;
                k.sample_spec.rate = 44100;
                k.sample_spec.channels = 2;
                pa_channel_map_init_stereo(&k.channel_map);
                pa_cvolume_set(&k.volume, 2, PA_VOLUME_NORM);
                k.driver = "soloist-lms-shim";
                k.has_volume = 1;
                k.volume_writable = 1;
                ((pa_sink_input_info_cb_t) o->cb)(o->c, &k, 0, o->ud);
                ((pa_sink_input_info_cb_t) o->cb)(o->c, NULL, 1, o->ud);
            }
            break;
        }
    }
    pa_operation_unref(o);
}

static pa_operation *op_post(pa_context *c, pa_stream *s, int kind, void *cb, void *ud)
{
    pa_operation *o = calloc(1, sizeof *o);
    o->refcnt = 2;                      /* one for the caller, one for the queued event */
    o->state = PA_OPERATION_RUNNING;
    o->c = c;
    o->s = s;
    o->kind = kind;
    o->cb = cb;
    o->ud = ud;
    o->success = 1;
    ml_post(c->ml, op_fire, o);
    return o;
}

pa_operation *pa_operation_ref(pa_operation *o) { REF(o); return o; }
void pa_operation_unref(pa_operation *o) { if (o && UNREF(o) == 0) free(o); }
void pa_operation_cancel(pa_operation *o) { if (o) o->state = PA_OPERATION_CANCELLED; }
pa_operation_state_t pa_operation_get_state(const pa_operation *o) { return o->state; }
void pa_operation_set_state_callback(pa_operation *o, pa_operation_notify_cb_t cb, void *ud) { (void) o; (void) cb; (void) ud; }

pa_operation *pa_context_get_server_info(pa_context *c, pa_server_info_cb_t cb, void *ud) { return op_post(c, NULL, OP_SERVER_INFO, cb, ud); }
pa_operation *pa_context_get_sink_info_by_name(pa_context *c, const char *n, pa_sink_info_cb_t cb, void *ud) { (void) n; return op_post(c, NULL, OP_SINK_INFO, cb, ud); }
pa_operation *pa_context_get_sink_info_by_index(pa_context *c, uint32_t i, pa_sink_info_cb_t cb, void *ud) { (void) i; return op_post(c, NULL, OP_SINK_INFO, cb, ud); }
pa_operation *pa_context_get_sink_info_list(pa_context *c, pa_sink_info_cb_t cb, void *ud) { return op_post(c, NULL, OP_SINK_INFO, cb, ud); }
pa_operation *pa_context_get_sink_input_info(pa_context *c, uint32_t i, pa_sink_input_info_cb_t cb, void *ud) { (void) i; return op_post(c, NULL, OP_SINK_INPUT_INFO, cb, ud); }
pa_operation *pa_context_subscribe(pa_context *c, pa_subscription_mask_t m, pa_context_success_cb_t cb, void *ud) { (void) m; return op_post(c, NULL, OP_CTX_OK, cb, ud); }
pa_operation *pa_context_set_sink_input_volume(pa_context *c, uint32_t i, const pa_cvolume *v, pa_context_success_cb_t cb, void *ud)
{
    (void) i; (void) v;   /* volume belongs to LMS; accept and ignore */
    LOG(2, "set_sink_input_volume ignored");
    return op_post(c, NULL, OP_CTX_OK, cb, ud);
}
pa_operation *pa_context_set_sink_input_mute(pa_context *c, uint32_t i, int m, pa_context_success_cb_t cb, void *ud) { (void) i; (void) m; return op_post(c, NULL, OP_CTX_OK, cb, ud); }
pa_operation *pa_context_set_sink_volume_by_name(pa_context *c, const char *n, const pa_cvolume *v, pa_context_success_cb_t cb, void *ud) { (void) n; (void) v; return op_post(c, NULL, OP_CTX_OK, cb, ud); }
pa_operation *pa_context_set_sink_mute_by_name(pa_context *c, const char *n, int m, pa_context_success_cb_t cb, void *ud) { (void) n; (void) m; return op_post(c, NULL, OP_CTX_OK, cb, ud); }
pa_operation *pa_context_drain(pa_context *c, pa_context_notify_cb_t cb, void *ud) { (void) c; (void) cb; (void) ud; return NULL; }

/* ---------------------------------------------------------------- streams */

struct pa_stream {
    int refcnt;
    pa_context *c;
    pa_sample_spec ss;
    pa_channel_map map;
    pa_stream_state_t state;
    pa_buffer_attr attr;
    pa_stream_flags_t flags;
    uint32_t index;

    pa_stream_notify_cb_t state_cb, underflow_cb, overflow_cb, started_cb, latency_cb, moved_cb, suspended_cb;
    pa_stream_request_cb_t write_cb;
    void *state_ud, *underflow_ud, *overflow_ud, *started_ud, *latency_ud, *moved_ud, *suspended_ud, *write_ud;

    pthread_mutex_t lk;
    unsigned char *ring;
    size_t cap, rd, fill;
    size_t requested, prebuf, minreq;
    uint64_t consumed_frames, written_frames, dropped_bytes, summary_dropped_bytes;
    int64_t underflow_index;
    uint64_t last_drop_log_ns;
    uint64_t overflow_serial, control_next_check_ns;
    uint64_t queue_start_ns;
    uint64_t write_calls, callback_calls, underflow_count, writer_iterations;
    uint64_t last_summary_ns, last_iteration_ns, max_iteration_gap_ns;
    unsigned long generation, control_seen;
    int corked, clock_on, force_start, started_once, write_pending, quit, thread_started;
    pa_operation *drain_op;
    pthread_t th;

    void *scratch; size_t scratch_len;
    pa_timing_info ti;

    /* resampler state, writer thread only */
    double rs_pos; int32_t rs_last[2];
};

static uint32_t next_index = 1;

static void stream_free(pa_stream *s)
{
    if (s->thread_started) {
        pthread_mutex_lock(&s->lk);
        s->quit = 1;
        pthread_mutex_unlock(&s->lk);
        pthread_join(s->th, NULL);
    }
    pthread_mutex_destroy(&s->lk);
    free(s->ring);
    free(s->scratch);
    if (s->c) pa_context_unref(s->c);
    free(s);
}

pa_stream *pa_stream_ref(pa_stream *s) { REF(s); return s; }
void pa_stream_unref(pa_stream *s) { if (s && UNREF(s) == 0) stream_free(s); }

pa_stream *pa_stream_new_with_proplist(pa_context *c, const char *name, const pa_sample_spec *ss,
                                       const pa_channel_map *map, pa_proplist *p)
{
    pa_stream *s;
    (void) p;
    if (!c || !pa_sample_spec_valid(ss)) return NULL;
    s = calloc(1, sizeof *s);
    s->refcnt = 1;
    s->c = pa_context_ref(c);
    s->ss = *ss;
    if (map && pa_channel_map_valid(map)) s->map = *map;
    else pa_channel_map_init_auto(&s->map, ss->channels, PA_CHANNEL_MAP_DEFAULT);
    s->state = PA_STREAM_UNCONNECTED;
    s->index = next_index++;
    pthread_mutex_init(&s->lk, NULL);
    LOG(1, "stream_new(%s): fmt=%d rate=%u ch=%u", name ? name : "?", ss->format, ss->rate, ss->channels);
    return s;
}
pa_stream *pa_stream_new(pa_context *c, const char *name, const pa_sample_spec *ss, const pa_channel_map *map)
{
    return pa_stream_new_with_proplist(c, name, ss, map, NULL);
}

/* Application-facing Pulse buffer (caller holds s->lk). */
#define COMPAT_RING_MAX (8u << 20)
static size_t ring_put(pa_stream *s, const unsigned char *d, size_t n)
{
    size_t fs = pa_frame_size(&s->ss), dropped = 0;
    n -= n % fs;
    if (s->fill + n > s->cap) {
        size_t want = s->cap ? s->cap : 65536;
        while (want < s->fill + n && want < COMPAT_RING_MAX) want *= 2;
        if (want > COMPAT_RING_MAX) want = COMPAT_RING_MAX;
        if (want > s->cap) {
            unsigned char *next = malloc(want);
            size_t first = s->cap - s->rd < s->fill ? s->cap - s->rd : s->fill;
            if (s->fill) {
                memcpy(next, s->ring + s->rd, first);
                memcpy(next + first, s->ring, s->fill - first);
            }
            free(s->ring);
            s->ring = next;
            s->cap = want;
            s->rd = 0;
        }
        if (cfg.compat && n > s->cap - s->fill) {
            dropped = n - (s->cap - s->fill);
            n = s->cap - s->fill;
        }
    }
    if (n > s->cap) {
        dropped += n - s->cap;
        d += n - s->cap;
        n = s->cap;
    }
    if (!cfg.compat && s->fill + n > s->cap) {
        size_t remove = s->fill + n - s->cap;
        remove += (fs - remove % fs) % fs;
        if (remove > s->fill) remove = s->fill;
        s->rd = (s->rd + remove) % s->cap;
        s->fill -= remove;
        dropped += remove;
    }
    if (!s->fill && n) s->queue_start_ns = now_ns();
    {
        size_t wr = (s->rd + s->fill) % s->cap, first = s->cap - wr < n ? s->cap - wr : n;
        memcpy(s->ring + wr, d, first);
        memcpy(s->ring, d + first, n - first);
    }
    s->fill += n;
    s->dropped_bytes += dropped;
    s->summary_dropped_bytes += dropped;
    if (dropped) {
        s->consumed_frames += dropped / fs;
        s->overflow_serial++;
    }
    return n;
}
static void ring_get(pa_stream *s, unsigned char *d, size_t n)
{
    size_t first = s->cap - s->rd < n ? s->cap - s->rd : n;
    memcpy(d, s->ring + s->rd, first);
    memcpy(d + first, s->ring, n - first);
    s->rd = (s->rd + n) % s->cap;
    s->fill -= n;
    if (s->fill) {
        s->queue_start_ns += pa_bytes_to_usec(n, &s->ss) * 1000ull;
    } else {
        s->queue_start_ns = 0;
    }
}

/* Keep Pulse's original producer contract, but discard audio whose scheduled
 * presentation time has fallen behind the configured live-edge budget. */
static void ring_trim_stale_locked(pa_stream *s, uint64_t now)
{
    uint64_t budget_ns, cutoff, stale_ns;
    size_t fs, remove;
    if (cfg.compat || !s->fill || !s->queue_start_ns) return;
    budget_ns = (uint64_t) cfg.ring_ms * 1000000ull;
    cutoff = now > budget_ns ? now - budget_ns : 0;
    if (s->queue_start_ns >= cutoff) return;
    stale_ns = cutoff - s->queue_start_ns;
    fs = pa_frame_size(&s->ss);
    remove = (size_t) ((long double) stale_ns * s->ss.rate / 1000000000.0L) * fs;
    remove -= remove % fs;
    if (remove > s->fill) remove = s->fill;
    if (!remove) return;
    s->rd = (s->rd + remove) % s->cap;
    s->fill -= remove;
    s->queue_start_ns += pa_bytes_to_usec(remove, &s->ss) * 1000ull;
    if (!s->fill) s->queue_start_ns = 0;
    s->dropped_bytes += remove;
    s->summary_dropped_bytes += remove;
    s->consumed_frames += remove / fs;
    s->overflow_serial++;
}

static void stream_log_drops_locked(pa_stream *s)
{
    uint64_t t = now_ns();
    if (s->dropped_bytes && t - s->last_drop_log_ns >= 1000000000ull) {
        LOG(1, "ring live-edge drop: %llu bytes (%.1f ms), queued=%.1f ms",
            (unsigned long long) s->dropped_bytes,
            pa_bytes_to_usec(s->dropped_bytes, &s->ss) / 1000.0,
            pa_bytes_to_usec(s->fill, &s->ss) / 1000.0);
        s->dropped_bytes = 0;
        s->last_drop_log_ns = t;
    }
}

static int chunk_is_current(pa_stream *s, unsigned long generation,
                            uint64_t overflow_serial)
{
    int current;
    pthread_mutex_lock(&s->lk);
    control_check_locked(s);
    current = !s->quit && s->generation == generation &&
              (cfg.compat || s->overflow_serial == overflow_serial);
    pthread_mutex_unlock(&s->lk);
    return current;
}

static uint64_t stream_queued_usec(pa_stream *s)
{
    uint64_t queued;
    pthread_mutex_lock(&s->lk);
    queued = pa_bytes_to_usec(s->fill, &s->ss);
    pthread_mutex_unlock(&s->lk);
    return queued;
}

static void stream_post_write(pa_stream *s);

static void control_ack(unsigned long request_id, unsigned long generation,
                        const char *reason)
{
    char tmp[560];
    FILE *f;
    if (!cfg.ack[0]) return;
    snprintf(tmp, sizeof tmp, "%s.tmp.%ld", cfg.ack, (long) getpid());
    f = fopen(tmp, "w");
    if (!f) return;
    fprintf(f, "%lu %lu %s\n", request_id, generation,
            reason ? reason : "unknown");
    if (fclose(f) == 0) rename(tmp, cfg.ack);
    else unlink(tmp);
}

/* caller holds s->lk */
static void stream_flush_locked(pa_stream *s, unsigned long generation, const char *reason)
{
    size_t discarded = s->fill;
    s->fill = 0;
    s->rd = 0;
    s->queue_start_ns = 0;
    s->clock_on = 0;
    s->force_start = 1;
    s->rs_pos = 0;
    s->rs_last[0] = s->rs_last[1] = 0;
    s->generation = generation;
    s->consumed_frames += discarded / pa_frame_size(&s->ss);
    s->requested = s->attr.tlength;
    stream_post_write(s);
    LOG(1, "generation flush: generation=%lu reason=%s discarded=%zu bytes (%.1f ms)",
        generation, reason ? reason : "unknown", discarded,
        pa_bytes_to_usec(discarded, &s->ss) / 1000.0);
}

/* caller holds s->lk */
static void control_check_locked(pa_stream *s)
{
    FILE *f;
    unsigned long request_id;
    char reason[96] = "external";
    if (!cfg.control[0]) return;
    if (now_ns() < s->control_next_check_ns) return;
    s->control_next_check_ns = now_ns() + 20000000ull;
    f = fopen(cfg.control, "r");
    if (!f) return;
    if (fscanf(f, "%lu %95s", &request_id, reason) < 1) {
        fclose(f);
        return;
    }
    fclose(f);
    if (request_id == s->control_seen) {
        control_ack(request_id, s->generation, reason);
        return;
    }
    s->control_seen = request_id;
    stream_flush_locked(s, s->generation + 1, reason);
    control_ack(request_id, s->generation, reason);
}

/* stream events */
struct ev_stream { pa_stream *s; pa_stream_state_t st; };

static void ev_stream_state_fn(void *a)
{
    struct ev_stream *e = a;
    pa_stream *s = e->s;
    s->state = e->st;
    if (s->state_cb) s->state_cb(s, s->state_ud);
    pa_stream_unref(s);
    free(e);
}
static void stream_post_state(pa_stream *s, pa_stream_state_t st)
{
    struct ev_stream *e = calloc(1, sizeof *e);
    e->s = pa_stream_ref(s);
    e->st = st;
    ml_post(s->c->ml, ev_stream_state_fn, e);
}

static void ev_stream_write_fn(void *a)
{
    pa_stream *s = a;
    size_t n;
    pthread_mutex_lock(&s->lk);
    s->write_pending = 0;
    s->callback_calls++;
    n = s->requested;
    pthread_mutex_unlock(&s->lk);
    if (s->write_cb && n > 0 && s->state == PA_STREAM_READY) s->write_cb(s, n, s->write_ud);
    pa_stream_unref(s);
}
static void stream_post_write(pa_stream *s)   /* caller holds s->lk */
{
    if (s->write_pending || s->requested == 0) return;
    if (s->requested < s->minreq && (s->clock_on || s->corked)) return;
    s->write_pending = 1;
    ml_post(s->c->ml, ev_stream_write_fn, pa_stream_ref(s));
}

static void ev_stream_underflow_fn(void *a)
{
    pa_stream *s = a;
    if (s->underflow_cb) s->underflow_cb(s, s->underflow_ud);
    pa_stream_unref(s);
}

/* ---- sample conversion ---- */

static inline int32_t clamp_d(double v)
{
    if (v >= 2147483647.0) return INT32_MAX;
    if (v <= -2147483648.0) return INT32_MIN;
    return (int32_t) v;
}
static inline int32_t dec_sample(pa_sample_format_t f, const unsigned char *p)
{
    switch (f) {
    case PA_SAMPLE_S16LE:
        return (int32_t) (((uint32_t) (uint16_t) (p[0] | (p[1] << 8))) << 16);
    case PA_SAMPLE_S24LE:
        return (int32_t) (((uint32_t) p[0] | ((uint32_t) p[1] << 8) | ((uint32_t) p[2] << 16)) << 8);
    case PA_SAMPLE_S24_32LE:
        return (int32_t) (((uint32_t) p[0] | ((uint32_t) p[1] << 8) | ((uint32_t) p[2] << 16)) << 8);
    case PA_SAMPLE_S32LE:
        return (int32_t) ((uint32_t) p[0] | ((uint32_t) p[1] << 8) | ((uint32_t) p[2] << 16) | ((uint32_t) p[3] << 24));
    case PA_SAMPLE_FLOAT32LE: {
        float x;
        memcpy(&x, p, 4);
        if (x != x) return 0;
        return clamp_d((double) x * 2147483648.0);
    }
    default:
        return 0;
    }
}
static inline void enc_sample(int bytes, double dv, unsigned char *o)
{
    int64_t v = (int64_t) llround(dv);
    if (bytes == 4) {
        if (v > INT32_MAX) v = INT32_MAX;
        if (v < INT32_MIN) v = INT32_MIN;
        o[0] = (unsigned char) v; o[1] = (unsigned char) (v >> 8);
        o[2] = (unsigned char) (v >> 16); o[3] = (unsigned char) (v >> 24);
    } else if (bytes == 3) {
        int64_t t = (v + 0x80) >> 8;
        if (t > 0x7FFFFF) t = 0x7FFFFF;
        if (t < -0x800000) t = -0x800000;
        o[0] = (unsigned char) t; o[1] = (unsigned char) (t >> 8); o[2] = (unsigned char) (t >> 16);
    } else {
        int64_t t = (v + 0x8000) >> 16;
        if (t > 32767) t = 32767;
        if (t < -32768) t = -32768;
        o[0] = (unsigned char) t; o[1] = (unsigned char) (t >> 8);
    }
}

/* Decode n frames to interleaved int32 stereo, resample, encode. Returns bytes written to o. */
static size_t convert_chunk(pa_stream *s, const unsigned char *in, size_t n, int32_t *dec,
                            unsigned char *o, int rout)
{
    size_t ssz = pa_sample_size(&s->ss), fs = pa_frame_size(&s->ss), m = 0;
    int ch = s->ss.channels, ob = cfg.bytes;

    for (size_t i = 0; i < n; i++) {
        const unsigned char *f = in + i * fs;
        int32_t l = dec_sample(s->ss.format, f);
        int32_t r = ch > 1 ? dec_sample(s->ss.format, f + ssz) : l;
        dec[i * 2] = l;
        dec[i * 2 + 1] = r;
    }
    if ((unsigned) rout == s->ss.rate) {
        for (size_t i = 0; i < n * 2; i++) enc_sample(ob, (double) dec[i], o + i * ob);
        return n * 2 * ob;
    }
    {
        double step = (double) s->ss.rate / (double) rout, p = s->rs_pos;
        while (n > 0 && p < (double) (n - 1)) {
            long i = (long) floor(p);
            double fr = p - (double) i;
            for (int c = 0; c < 2; c++) {
                double a = i < 0 ? (double) s->rs_last[c] : (double) dec[i * 2 + c];
                double b = (double) dec[(i + 1) * 2 + c];
                enc_sample(ob, a + (b - a) * fr, o + (m * 2 + c) * ob);
            }
            m++;
            p += step;
        }
        if (n > 0) {
            s->rs_pos = p - (double) n;
            s->rs_last[0] = dec[(n - 1) * 2];
            s->rs_last[1] = dec[(n - 1) * 2 + 1];
        }
        return m * 2 * ob;
    }
}

/* ---- the writer thread: wall-clock paced drain of the ring into the sink ---- */

static void *writer_main(void *arg)
{
    pa_stream *s = arg;
    sigset_t blk;
    size_t fs = pa_frame_size(&s->ss);
    size_t maxf = s->ss.rate / 5 + 16;
    int rout;
    unsigned char *raw, *obuf;
    int32_t *dec;
    uint64_t t0 = 0, base = 0;

    CFG();
    rout = cfg.rate > 0 ? cfg.rate : (int) s->ss.rate;
    sigemptyset(&blk);
    sigaddset(&blk, SIGPIPE);
    pthread_sigmask(SIG_BLOCK, &blk, NULL);

    raw = malloc(maxf * fs);
    dec = malloc(maxf * 2 * sizeof(int32_t));
    obuf = malloc((size_t) ((double) maxf * rout / s->ss.rate + 8) * 2 * 4);

    for (;;) {
        size_t n = 0, avail;
        int underflow = 0, drained = 0;
        unsigned long chunk_generation = 0;
        uint64_t chunk_overflow_serial = 0;
        struct timespec nap = { 0, 5000000 };
        uint64_t t;

        nanosleep(&nap, NULL);
        pthread_mutex_lock(&s->lk);
        if (s->quit) { pthread_mutex_unlock(&s->lk); break; }
        t = now_ns();
        s->writer_iterations++;
        if (s->last_iteration_ns && t - s->last_iteration_ns > s->max_iteration_gap_ns)
            s->max_iteration_gap_ns = t - s->last_iteration_ns;
        s->last_iteration_ns = t;
        control_check_locked(s);
        ring_trim_stale_locked(s, t);
        stream_log_drops_locked(s);
        avail = s->fill / fs;

        if (s->state != PA_STREAM_READY || s->corked) {
            s->clock_on = 0;
        } else {
            if (!s->clock_on) {
                if (avail > 0 && (s->fill >= s->prebuf || (s->force_start && s->fill >= s->minreq) || s->drain_op)) {
                    s->clock_on = 1;
                    s->force_start = 0;
                    s->started_once = 1;
                    t0 = t;
                    base = 0;
                } else if (s->drain_op && s->fill == 0) {
                    drained = 1;
                }
            }
            if (s->clock_on) {
                uint64_t due = (t - t0) * s->ss.rate / 1000000000ull;
                due = due > base ? due - base : 0;
                if (avail == 0) {
                    if (due > 0) {                    /* ran dry */
                        s->clock_on = 0;
                        underflow = s->drain_op ? 0 : 1;
                        if (underflow) {
                            s->underflow_count++;
                            size_t input_fs = pa_frame_size(&s->ss);
                            uint64_t consumed_bytes = s->consumed_frames * input_fs;
                            uint64_t written_bytes = s->written_frames * input_fs;
                            s->underflow_index = (int64_t) consumed_bytes;
                            LOG(1, "stream underflow: consumed=%llu written=%llu outstanding=%llu "
                                "app_buffer=%zu requested=%zu prebuf=%zu minreq=%zu corked=%d",
                                (unsigned long long) consumed_bytes,
                                (unsigned long long) written_bytes,
                                (unsigned long long) ((s->written_frames - s->consumed_frames) * input_fs),
                                s->fill,
                                s->requested, s->prebuf, s->minreq, s->corked);
                        }
                        stream_post_write(s);
                        if (s->drain_op) drained = 1;
                    }
                } else {
                    n = due < avail ? (size_t) due : avail;
                    if (n > maxf) n = maxf;
                    if (n) {
                        ring_get(s, raw, n * fs);
                        chunk_generation = s->generation;
                        chunk_overflow_serial = s->overflow_serial;
                        base += n;
                        s->consumed_frames += n;
                        s->requested += n * fs;
                        if (s->fill + s->requested > s->attr.tlength)
                            s->requested = s->attr.tlength > s->fill ? s->attr.tlength - s->fill : 0;
                        stream_post_write(s);
                    }
                }
            }
        }
        if (!s->last_summary_ns) s->last_summary_ns = t;
        if (t - s->last_summary_ns >= 5000000000ull) {
            double oldest_age_ms = s->queue_start_ns && t > s->queue_start_ns
                ? (t - s->queue_start_ns) / 1000000.0 : 0.0;
            LOG(1, "runtime summary: mode=%s queued=%.1f ms oldest_age=%.1f ms writes=%llu callbacks=%llu "
                "underflows=%llu drops=%.1f ms writer_gap_max=%.1f ms requested=%.1f ms",
                cfg.compat ? "compat" : "live-ring",
                pa_bytes_to_usec(s->fill, &s->ss) / 1000.0,
                oldest_age_ms,
                (unsigned long long) s->write_calls,
                (unsigned long long) s->callback_calls,
                (unsigned long long) s->underflow_count,
                pa_bytes_to_usec(s->summary_dropped_bytes, &s->ss) / 1000.0,
                s->max_iteration_gap_ns / 1000000.0,
                pa_bytes_to_usec(s->requested, &s->ss) / 1000.0);
            s->write_calls = s->callback_calls = s->underflow_count = 0;
            s->summary_dropped_bytes = 0;
            s->writer_iterations = 0;
            s->max_iteration_gap_ns = 0;
            s->last_summary_ns = t;
        }
        if (drained && s->drain_op) {
            pa_operation *o = s->drain_op;
            s->drain_op = NULL;
            s->force_start = 1;
            s->requested = s->attr.tlength;
            LOG(1, "stream drain complete: consumed=%llu written=%llu outstanding=%llu "
                "app_buffer=%zu requested=%zu",
                (unsigned long long) (s->consumed_frames * fs),
                (unsigned long long) (s->written_frames * fs),
                (unsigned long long) ((s->written_frames - s->consumed_frames) * fs),
                s->fill, s->requested);
            ml_post(s->c->ml, op_fire, o);            /* hands over our reference */
            stream_post_write(s);
        }
        pthread_mutex_unlock(&s->lk);

        if (underflow) ml_post(s->c->ml, ev_stream_underflow_fn, pa_stream_ref(s));
        if (n) {
            size_t bytes = convert_chunk(s, raw, n, dec, obuf, rout);
            int current;
            pthread_mutex_lock(&s->lk);
            control_check_locked(s);
            current = chunk_generation == s->generation;
            pthread_mutex_unlock(&s->lk);
            if (bytes && current) {
                out_write(s, obuf, bytes, (size_t) cfg.bytes * 2,
                          chunk_generation, chunk_overflow_serial);
            }
        }
    }
    free(raw);
    free(dec);
    free(obuf);
    return NULL;
}

int pa_stream_connect_playback(pa_stream *s, const char *dev, const pa_buffer_attr *attr,
                               pa_stream_flags_t flags, const pa_cvolume *vol, pa_stream *sync)
{
    size_t fs;
    pa_sample_format_t f;
    uint32_t max_tlength_bytes = 0;
    (void) dev; (void) vol; (void) sync;

    if (!s || s->state != PA_STREAM_UNCONNECTED) return -1;
    f = s->ss.format;
    if (f != PA_SAMPLE_S16LE && f != PA_SAMPLE_S24LE && f != PA_SAMPLE_S24_32LE &&
        f != PA_SAMPLE_S32LE && f != PA_SAMPLE_FLOAT32LE) {
        LOG(1, "unsupported sample format %d", f);
        s->c->err = PA_ERR_NOTSUPPORTED;
        return -1;
    }
    CFG();
    fs = pa_frame_size(&s->ss);
    s->cap = 65536;
    s->cap -= s->cap % fs;
    if (s->cap < fs) s->cap = fs;
    s->ring = malloc(s->cap);
    if (!s->ring) {
        s->c->err = PA_ERR_INTERNAL;
        return -1;
    }
    s->flags = flags;
    memset(&s->attr, 0, sizeof s->attr);
    s->attr.tlength = (attr && attr->tlength != (uint32_t) -1) ? attr->tlength
                                                                : (uint32_t) pa_usec_to_bytes(500000, &s->ss);
    s->attr.minreq = (attr && attr->minreq != (uint32_t) -1) ? attr->minreq
                                                              : (uint32_t) pa_usec_to_bytes(20000, &s->ss);
    s->attr.prebuf = (attr && attr->prebuf != (uint32_t) -1) ? attr->prebuf : s->attr.tlength;
    s->attr.maxlength = (attr && attr->maxlength != (uint32_t) -1) ? attr->maxlength : s->attr.tlength * 4;
    s->attr.fragsize = (uint32_t) -1;
    if (cfg.max_tlength_ms > 0) {
        max_tlength_bytes = (uint32_t) pa_usec_to_bytes((pa_usec_t) cfg.max_tlength_ms * 1000u, &s->ss);
        if (max_tlength_bytes > 0 && s->attr.tlength > max_tlength_bytes)
            s->attr.tlength = max_tlength_bytes;
        if (s->attr.prebuf > s->attr.tlength)
            s->attr.prebuf = s->attr.tlength;
        if (s->attr.minreq > s->attr.tlength)
            s->attr.minreq = s->attr.tlength;
        if (s->attr.maxlength != (uint32_t) -1 && s->attr.maxlength < s->attr.tlength)
            s->attr.maxlength = s->attr.tlength;
    }
    if (s->attr.maxlength != (uint32_t) -1 && s->attr.maxlength < s->attr.tlength)
        s->attr.maxlength = s->attr.tlength;
    s->prebuf = cfg.compat ? s->attr.prebuf : fs;
    s->minreq = s->attr.minreq ? s->attr.minreq : fs;
    s->requested = s->attr.tlength;
    s->consumed_frames = s->written_frames = cfg.counter_base_frames;
    s->corked = (flags & PA_STREAM_START_CORKED) ? 1 : 0;
    s->state = PA_STREAM_CREATING;

    s->thread_started = pthread_create(&s->th, NULL, writer_main, s) == 0;
    if (!s->thread_started) return -1;

    LOG(1, "connect_playback: mode=%s tlength=%u minreq=%u prebuf=%u initial_ring=%zu bytes live_edge_ms=%d max_tlength_ms=%d out=%s fmt=%dB rate=%d",
        cfg.compat ? "compat" : "live-ring",
        s->attr.tlength, s->attr.minreq, s->attr.prebuf, s->cap,
        cfg.ring_ms,
        cfg.max_tlength_ms, cfg.out, cfg.bytes, cfg.rate);
    stream_post_state(s, PA_STREAM_CREATING);
    stream_post_state(s, PA_STREAM_READY);
    pthread_mutex_lock(&s->lk);
    stream_post_write(s);
    pthread_mutex_unlock(&s->lk);
    return 0;
}
int pa_stream_connect_record(pa_stream *s, const char *dev, const pa_buffer_attr *attr, pa_stream_flags_t flags)
{
    (void) dev; (void) attr; (void) flags;
    s->c->err = PA_ERR_NOTIMPLEMENTED;
    return -1;
}
int pa_stream_disconnect(pa_stream *s)
{
    if (!s || s->state == PA_STREAM_UNCONNECTED) return -1;
    LOG(1, "stream_disconnect");
    pthread_mutex_lock(&s->lk);
    s->state = PA_STREAM_TERMINATED;
    s->fill = 0;
    if (s->drain_op) { pa_operation_cancel(s->drain_op); pa_operation_unref(s->drain_op); s->drain_op = NULL; }
    pthread_mutex_unlock(&s->lk);
    stream_post_state(s, PA_STREAM_TERMINATED);
    return 0;
}

pa_stream_state_t pa_stream_get_state(const pa_stream *s) { return s->state; }
pa_context *pa_stream_get_context(const pa_stream *s) { return s->c; }
uint32_t pa_stream_get_index(const pa_stream *s) { return s->index; }
uint32_t pa_stream_get_device_index(const pa_stream *s) { (void) s; return 0; }
const char *pa_stream_get_device_name(const pa_stream *s) { (void) s; return "soloist_lms"; }
int pa_stream_is_suspended(const pa_stream *s) { (void) s; return 0; }
int pa_stream_is_corked(const pa_stream *s) { return s->corked; }
const pa_sample_spec *pa_stream_get_sample_spec(pa_stream *s) { return &s->ss; }
const pa_channel_map *pa_stream_get_channel_map(pa_stream *s) { return &s->map; }
const pa_buffer_attr *pa_stream_get_buffer_attr(pa_stream *s) { return &s->attr; }

#define SETCB(name, type, field, ud) \
    void pa_stream_set_##name##_callback(pa_stream *s, type cb, void *u) { s->field = cb; s->ud = u; }
SETCB(state, pa_stream_notify_cb_t, state_cb, state_ud)
SETCB(write, pa_stream_request_cb_t, write_cb, write_ud)
SETCB(underflow, pa_stream_notify_cb_t, underflow_cb, underflow_ud)
SETCB(overflow, pa_stream_notify_cb_t, overflow_cb, overflow_ud)
SETCB(started, pa_stream_notify_cb_t, started_cb, started_ud)
SETCB(latency_update, pa_stream_notify_cb_t, latency_cb, latency_ud)
SETCB(moved, pa_stream_notify_cb_t, moved_cb, moved_ud)
SETCB(suspended, pa_stream_notify_cb_t, suspended_cb, suspended_ud)
void pa_stream_set_read_callback(pa_stream *s, pa_stream_request_cb_t cb, void *u) { (void) s; (void) cb; (void) u; }
void pa_stream_set_event_callback(pa_stream *s, pa_stream_event_cb_t cb, void *u) { (void) s; (void) cb; (void) u; }
void pa_stream_set_buffer_attr_callback(pa_stream *s, pa_stream_notify_cb_t cb, void *u) { (void) s; (void) cb; (void) u; }

size_t pa_stream_writable_size(const pa_stream *s)
{
    size_t r;
    pa_stream *m = (pa_stream *) s;
    if (s->state != PA_STREAM_READY) return (size_t) -1;
    pthread_mutex_lock(&m->lk);
    r = s->requested;
    pthread_mutex_unlock(&m->lk);
    return r;
}
size_t pa_stream_readable_size(const pa_stream *s) { (void) s; return (size_t) -1; }

int pa_stream_begin_write(pa_stream *s, void **data, size_t *nbytes)
{
    size_t want = (*nbytes == (size_t) -1 || *nbytes == 0) ? 65536 : *nbytes;
    if (want > s->scratch_len) {
        free(s->scratch);
        s->scratch = malloc(want);
        s->scratch_len = want;
    }
    *data = s->scratch;
    *nbytes = want;
    return 0;
}
int pa_stream_cancel_write(pa_stream *s) { (void) s; return 0; }

int pa_stream_write(pa_stream *s, const void *data, size_t nbytes, pa_free_cb_t free_cb,
                    int64_t offset, pa_seek_mode_t seek)
{
    size_t fs = pa_frame_size(&s->ss), took;
    (void) offset; (void) seek;

    if (s->state != PA_STREAM_READY || !data || nbytes % fs) {
        s->c->err = PA_ERR_BADSTATE;
        return -1;
    }
    pthread_mutex_lock(&s->lk);
    took = ring_put(s, data, nbytes);
    s->write_calls++;
    s->written_frames += nbytes / fs;
    s->requested = s->requested > nbytes ? s->requested - nbytes : 0;
    stream_post_write(s);
    pthread_mutex_unlock(&s->lk);
    if (free_cb && data != s->scratch) free_cb((void *) data);
    (void) took;
    return 0;
}

int pa_stream_get_latency(pa_stream *s, pa_usec_t *r, int *negative)
{
    if (negative) *negative = 0;
    pthread_mutex_lock(&s->lk);
    *r = pa_bytes_to_usec(s->fill, &s->ss);
    pthread_mutex_unlock(&s->lk);
    return 0;
}
int pa_stream_get_time(pa_stream *s, pa_usec_t *r)
{
    pthread_mutex_lock(&s->lk);
    *r = (pa_usec_t) ((long double) s->consumed_frames * PA_USEC_PER_SEC / s->ss.rate);
    pthread_mutex_unlock(&s->lk);
    return 0;
}
int64_t pa_stream_get_underflow_index(const pa_stream *s)
{
    int64_t index;
    pa_stream *m = (pa_stream *) s;
    pthread_mutex_lock(&m->lk);
    index = s->underflow_index;
    pthread_mutex_unlock(&m->lk);
    return index;
}
const pa_timing_info *pa_stream_get_timing_info(pa_stream *s)
{
    pthread_mutex_lock(&s->lk);
    memset(&s->ti, 0, sizeof s->ti);
    gettimeofday(&s->ti.timestamp, NULL);
    s->ti.synchronized_clocks = 1;
    s->ti.playing = !s->corked && s->clock_on;
    s->ti.write_index = (int64_t) (s->written_frames * pa_frame_size(&s->ss));
    s->ti.read_index = (int64_t) (s->consumed_frames * pa_frame_size(&s->ss));
    pthread_mutex_unlock(&s->lk);
    return &s->ti;
}
pa_operation *pa_stream_update_timing_info(pa_stream *s, pa_stream_success_cb_t cb, void *ud) { return op_post(s->c, s, OP_STREAM_OK, cb, ud); }

pa_operation *pa_stream_drain(pa_stream *s, pa_stream_success_cb_t cb, void *ud)
{
    pa_operation *o = calloc(1, sizeof *o);
    o->refcnt = 2;                       /* caller + the stream's pending slot */
    o->state = PA_OPERATION_RUNNING;
    o->c = s->c; o->s = s; o->kind = OP_STREAM_OK; o->cb = cb; o->ud = ud; o->success = 1;
    pthread_mutex_lock(&s->lk);
    if (s->drain_op) pa_operation_unref(s->drain_op);
    s->drain_op = o;
    LOG(1, "stream drain requested: consumed=%llu written=%llu outstanding=%llu "
        "app_buffer=%zu requested=%zu corked=%d",
        (unsigned long long) (s->consumed_frames * pa_frame_size(&s->ss)),
        (unsigned long long) (s->written_frames * pa_frame_size(&s->ss)),
        (unsigned long long) ((s->written_frames - s->consumed_frames) * pa_frame_size(&s->ss)),
        s->fill, s->requested, s->corked);
    pthread_mutex_unlock(&s->lk);
    return o;
}
pa_operation *pa_stream_flush(pa_stream *s, pa_stream_success_cb_t cb, void *ud)
{
    pthread_mutex_lock(&s->lk);
    stream_flush_locked(s, s->generation + 1, "pulse-flush");
    s->requested = s->attr.tlength;
    stream_post_write(s);
    pthread_mutex_unlock(&s->lk);
    return op_post(s->c, s, OP_STREAM_OK, cb, ud);
}
pa_operation *pa_stream_prebuf(pa_stream *s, pa_stream_success_cb_t cb, void *ud) { return op_post(s->c, s, OP_STREAM_OK, cb, ud); }
pa_operation *pa_stream_trigger(pa_stream *s, pa_stream_success_cb_t cb, void *ud)
{
    pthread_mutex_lock(&s->lk);
    s->force_start = 1;
    if (s->requested == 0) s->requested = s->attr.tlength;
    stream_post_write(s);
    pthread_mutex_unlock(&s->lk);
    return op_post(s->c, s, OP_STREAM_OK, cb, ud);
}
pa_operation *pa_stream_cork(pa_stream *s, int b, pa_stream_success_cb_t cb, void *ud)
{
    pthread_mutex_lock(&s->lk);
    s->corked = b;
    if (b) s->clock_on = 0;
    else if (s->started_once) s->force_start = 1;
    pthread_mutex_unlock(&s->lk);
    LOG(2, "cork(%d)", b);
    return op_post(s->c, s, OP_STREAM_OK, cb, ud);
}
pa_operation *pa_stream_set_name(pa_stream *s, const char *n, pa_stream_success_cb_t cb, void *ud) { (void) n; return op_post(s->c, s, OP_STREAM_OK, cb, ud); }
pa_operation *pa_stream_set_buffer_attr(pa_stream *s, const pa_buffer_attr *a, pa_stream_success_cb_t cb, void *ud) { (void) a; return op_post(s->c, s, OP_STREAM_OK, cb, ud); }
pa_operation *pa_stream_update_sample_rate(pa_stream *s, uint32_t rate, pa_stream_success_cb_t cb, void *ud)
{
    pthread_mutex_lock(&s->lk);
    s->ss.rate = rate;
    pthread_mutex_unlock(&s->lk);
    return op_post(s->c, s, OP_STREAM_OK, cb, ud);
}
pa_operation *pa_stream_proplist_update(pa_stream *s, pa_update_mode_t m, pa_proplist *p, pa_stream_success_cb_t cb, void *ud)
{
    (void) m; (void) p;
    return op_post(s->c, s, OP_STREAM_OK, cb, ud);
}
int pa_stream_peek(pa_stream *s, const void **d, size_t *n) { (void) s; (void) d; (void) n; return -1; }
int pa_stream_drop(pa_stream *s) { (void) s; return -1; }
