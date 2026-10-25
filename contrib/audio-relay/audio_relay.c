#define _POSIX_C_SOURCE 200809L

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <netinet/in.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#define MAX_CLIENTS 64
#define REQUEST_SIZE 4096
#define AUDIO_CHUNK_SIZE 4096
#define CLIENT_BUFFER_SIZE (256 * AUDIO_CHUNK_SIZE)
#define PREFIX_SIZE 512

typedef struct {
	int fd;
	int streaming;
	char request[REQUEST_SIZE];
	size_t request_len;
	unsigned char prefix[PREFIX_SIZE];
	size_t prefix_len;
	size_t prefix_off;
	unsigned char *audio;
	size_t audio_head;
	size_t audio_len;
	char address[INET_ADDRSTRLEN];
} client_t;

typedef struct {
	const char *fifo_path;
	const char *bind_address;
	const char *content_type;
	const char *ready_path;
	const char *flush_path;
	int port;
	int wav_stream;
	uint32_t wav_sample_rate;
	uint16_t wav_channels;
	uint16_t wav_bits_per_sample;
} config_t;

static volatile sig_atomic_t running = 1;

static int64_t monotonic_ms(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (int64_t) ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static void handle_signal(int sig)
{
	(void) sig;
	running = 0;
}

static int set_nonblocking(int fd)
{
	int flags = fcntl(fd, F_GETFL, 0);
	return flags < 0 ? -1 : fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

static void put_le16(unsigned char *p, uint16_t value)
{
	p[0] = (unsigned char) value;
	p[1] = (unsigned char) (value >> 8);
}

static void put_le32(unsigned char *p, uint32_t value)
{
	p[0] = (unsigned char) value;
	p[1] = (unsigned char) (value >> 8);
	p[2] = (unsigned char) (value >> 16);
	p[3] = (unsigned char) (value >> 24);
}

static size_t make_wav_header(unsigned char *out, const config_t *cfg)
{
	uint16_t block_align =
		(uint16_t) (cfg->wav_channels * cfg->wav_bits_per_sample / 8);
	uint32_t byte_rate = cfg->wav_sample_rate * block_align;
	uint32_t data_size = UINT32_MAX;

	memcpy(out, "RIFF", 4);
	put_le32(out + 4, 36 + data_size);
	memcpy(out + 8, "WAVEfmt ", 8);
	put_le32(out + 16, 16);
	put_le16(out + 20, 1);
	put_le16(out + 22, cfg->wav_channels);
	put_le32(out + 24, cfg->wav_sample_rate);
	put_le32(out + 28, byte_rate);
	put_le16(out + 32, block_align);
	put_le16(out + 34, cfg->wav_bits_per_sample);
	memcpy(out + 36, "data", 4);
	put_le32(out + 40, data_size);
	return 44;
}

static void client_reset(client_t *client)
{
	if (client->fd >= 0)
		close(client->fd);
	free(client->audio);
	memset(client, 0, sizeof(*client));
	client->fd = -1;
}

static void client_queue_audio(client_t *client, const unsigned char *data, size_t size)
{
	size_t tail;
	size_t first;

	if (!client->streaming || !client->audio || size == 0)
		return;

	if (size >= CLIENT_BUFFER_SIZE) {
		data += size - CLIENT_BUFFER_SIZE;
		size = CLIENT_BUFFER_SIZE;
		client->audio_head = 0;
		client->audio_len = 0;
	}

	if (client->audio_len + size > CLIENT_BUFFER_SIZE) {
		size_t drop = client->audio_len + size - CLIENT_BUFFER_SIZE;
		client->audio_head = (client->audio_head + drop) % CLIENT_BUFFER_SIZE;
		client->audio_len -= drop;
	}

	tail = (client->audio_head + client->audio_len) % CLIENT_BUFFER_SIZE;
	first = CLIENT_BUFFER_SIZE - tail;
	if (first > size)
		first = size;
	memcpy(client->audio + tail, data, first);
	memcpy(client->audio, data + first, size - first);
	client->audio_len += size;
}

static int client_send_pending(client_t *client)
{
	ssize_t sent;

	while (client->prefix_off < client->prefix_len) {
		sent = send(
			client->fd,
			client->prefix + client->prefix_off,
			client->prefix_len - client->prefix_off,
			MSG_NOSIGNAL
		);
		if (sent > 0) {
			client->prefix_off += (size_t) sent;
			continue;
		}
		if (sent < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))
			return 0;
		return -1;
	}

	while (client->audio_len > 0) {
		size_t contiguous = CLIENT_BUFFER_SIZE - client->audio_head;
		if (contiguous > client->audio_len)
			contiguous = client->audio_len;
		sent = send(client->fd, client->audio + client->audio_head, contiguous, MSG_NOSIGNAL);
		if (sent > 0) {
			client->audio_head =
				(client->audio_head + (size_t) sent) % CLIENT_BUFFER_SIZE;
			client->audio_len -= (size_t) sent;
			continue;
		}
		if (sent < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))
			return 0;
		return -1;
	}

	return 0;
}

static int request_complete(const char *request, size_t size)
{
	size_t i;
	for (i = 3; i < size; ++i) {
		if (request[i - 3] == '\r' && request[i - 2] == '\n'
			&& request[i - 1] == '\r' && request[i] == '\n')
			return 1;
	}
	return 0;
}

static int start_streaming(client_t *client, const config_t *cfg)
{
	int written;

	if (strncmp(client->request, "GET ", 4) != 0)
		return -1;

	written = snprintf(
		(char *) client->prefix,
		sizeof(client->prefix),
		"HTTP/1.1 200 OK\r\n"
		"Server: soloist-audio-relay\r\n"
		"Content-Type: %s\r\n"
		"Cache-Control: no-cache\r\n"
		"Connection: close\r\n"
		"\r\n",
		cfg->content_type
	);
	if (written < 0 || (size_t) written >= sizeof(client->prefix))
		return -1;

	client->prefix_len = (size_t) written;
	if (cfg->wav_stream) {
		if (client->prefix_len + 44 > sizeof(client->prefix))
			return -1;
		client->prefix_len += make_wav_header(
			client->prefix + client->prefix_len,
			cfg
		);
	}

	client->streaming = 1;
	fprintf(stderr, "[relay] %s - \"GET\" 200\n", client->address);
	fflush(stderr);
	return 0;
}

static int client_read_request(client_t *client, const config_t *cfg)
{
	ssize_t count;

	while (client->request_len < sizeof(client->request) - 1) {
		count = recv(
			client->fd,
			client->request + client->request_len,
			sizeof(client->request) - 1 - client->request_len,
			0
		);
		if (count > 0) {
			client->request_len += (size_t) count;
			client->request[client->request_len] = '\0';
			if (request_complete(client->request, client->request_len))
				return start_streaming(client, cfg);
			continue;
		}
		if (count == 0)
			return -1;
		if (errno == EAGAIN || errno == EWOULDBLOCK)
			return 0;
		return -1;
	}

	return -1;
}

static int create_listener(const config_t *cfg)
{
	int fd;
	int reuse = 1;
	struct sockaddr_in address;

	fd = socket(AF_INET, SOCK_STREAM, 0);
	if (fd < 0)
		return -1;

	setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
	if (set_nonblocking(fd) < 0) {
		close(fd);
		return -1;
	}

	memset(&address, 0, sizeof(address));
	address.sin_family = AF_INET;
	address.sin_port = htons((uint16_t) cfg->port);
	if (inet_pton(AF_INET, cfg->bind_address, &address.sin_addr) != 1) {
		fprintf(stderr, "[relay] invalid IPv4 bind address: %s\n", cfg->bind_address);
		close(fd);
		return -1;
	}

	if (bind(fd, (struct sockaddr *) &address, sizeof(address)) < 0
		|| listen(fd, 16) < 0) {
		close(fd);
		return -1;
	}
	return fd;
}

static void accept_clients(int listener, client_t clients[MAX_CLIENTS])
{
	for (;;) {
		struct sockaddr_in peer;
		socklen_t peer_size = sizeof(peer);
		int fd = accept(listener, (struct sockaddr *) &peer, &peer_size);
		int i;

		if (fd < 0) {
			if (errno != EAGAIN && errno != EWOULDBLOCK)
				perror("[relay] accept");
			return;
		}

		if (set_nonblocking(fd) < 0) {
			close(fd);
			continue;
		}

		for (i = 0; i < MAX_CLIENTS; ++i) {
			if (clients[i].fd < 0)
				break;
		}
		if (i == MAX_CLIENTS) {
			close(fd);
			continue;
		}

		clients[i].fd = fd;
		clients[i].audio = malloc(CLIENT_BUFFER_SIZE);
		if (!clients[i].audio) {
			client_reset(&clients[i]);
			continue;
		}
		if (!inet_ntop(AF_INET, &peer.sin_addr, clients[i].address, sizeof(clients[i].address)))
			strcpy(clients[i].address, "unknown");
	}
}

static int timespec_newer(struct timespec current, struct timespec previous)
{
	return current.tv_sec > previous.tv_sec
		|| (current.tv_sec == previous.tv_sec && current.tv_nsec > previous.tv_nsec);
}

static void check_flush_file(
	const config_t *cfg,
	client_t clients[MAX_CLIENTS],
	struct timespec *last_flush
)
{
	struct stat st;
	size_t flushed = 0;
	int i;

	if (!cfg->flush_path || !*cfg->flush_path || stat(cfg->flush_path, &st) < 0)
		return;
	if (!timespec_newer(st.st_mtim, *last_flush))
		return;

	*last_flush = st.st_mtim;
	for (i = 0; i < MAX_CLIENTS; ++i) {
		if (clients[i].fd >= 0) {
			flushed += clients[i].audio_len / AUDIO_CHUNK_SIZE;
			clients[i].audio_head = 0;
			clients[i].audio_len = 0;
		}
	}
	if (flushed > 0) {
		fprintf(stderr, "[relay] flushed %zu queued chunk(s)\n", flushed);
		fflush(stderr);
	}
}

static void mark_ready(const config_t *cfg, int64_t *last_ready_ms)
{
	int fd;
	int64_t now;

	if (!cfg->ready_path || !*cfg->ready_path)
		return;
	now = monotonic_ms();
	if (*last_ready_ms && now - *last_ready_ms < 250)
		return;

	fd = open(cfg->ready_path, O_WRONLY | O_CREAT, 0666);
	if (fd >= 0) {
		close(fd);
		utimensat(AT_FDCWD, cfg->ready_path, NULL, 0);
		*last_ready_ms = now;
	}
}

static void broadcast_audio(
	client_t clients[MAX_CLIENTS],
	const unsigned char *data,
	size_t size
)
{
	int i;
	for (i = 0; i < MAX_CLIENTS; ++i)
		client_queue_audio(&clients[i], data, size);
}

static void usage(const char *program)
{
	fprintf(
		stderr,
		"usage: %s --fifo PATH --port PORT [--bind ADDRESS] "
		"[--content-type TYPE] [--ready-file PATH] [--flush-file PATH] "
		"[--wav-stream] [--wav-sample-rate N] [--wav-channels N] "
		"[--wav-bits-per-sample N]\n",
		program
	);
}

static int parse_int(const char *value, int min, int max, int *out)
{
	char *end;
	long parsed = strtol(value, &end, 10);
	if (!*value || *end || parsed < min || parsed > max)
		return -1;
	*out = (int) parsed;
	return 0;
}

static int parse_args(int argc, char **argv, config_t *cfg)
{
	int i;
	memset(cfg, 0, sizeof(*cfg));
	cfg->bind_address = "0.0.0.0";
	cfg->content_type = "audio/mpeg";
	cfg->wav_sample_rate = 44100;
	cfg->wav_channels = 2;
	cfg->wav_bits_per_sample = 16;

	for (i = 1; i < argc; ++i) {
#define VALUE_ARG(name, field) \
		if (strcmp(argv[i], name) == 0 && i + 1 < argc) { cfg->field = argv[++i]; continue; }
		VALUE_ARG("--fifo", fifo_path)
		VALUE_ARG("--bind", bind_address)
		VALUE_ARG("--content-type", content_type)
		VALUE_ARG("--ready-file", ready_path)
		VALUE_ARG("--flush-file", flush_path)
#undef VALUE_ARG
		if (strcmp(argv[i], "--wav-stream") == 0) {
			cfg->wav_stream = 1;
			continue;
		}
		if (i + 1 < argc && strcmp(argv[i], "--port") == 0) {
			if (parse_int(argv[++i], 1, 65535, &cfg->port) < 0)
				return -1;
			continue;
		}
		if (i + 1 < argc && strcmp(argv[i], "--wav-sample-rate") == 0) {
			int value;
			if (parse_int(argv[++i], 1, INT_MAX, &value) < 0)
				return -1;
			cfg->wav_sample_rate = (uint32_t) value;
			continue;
		}
		if (i + 1 < argc && strcmp(argv[i], "--wav-channels") == 0) {
			int value;
			if (parse_int(argv[++i], 1, UINT16_MAX, &value) < 0)
				return -1;
			cfg->wav_channels = (uint16_t) value;
			continue;
		}
		if (i + 1 < argc && strcmp(argv[i], "--wav-bits-per-sample") == 0) {
			int value;
			if (parse_int(argv[++i], 1, UINT16_MAX, &value) < 0)
				return -1;
			cfg->wav_bits_per_sample = (uint16_t) value;
			continue;
		}
		return -1;
	}

	return cfg->fifo_path && cfg->port ? 0 : -1;
}

int main(int argc, char **argv)
{
	config_t cfg;
	client_t clients[MAX_CLIENTS];
	struct pollfd pollfds[MAX_CLIENTS + 2];
	struct timespec last_flush = {0, 0};
	int listener;
	int fifo_fd = -1;
	int64_t fifo_retry_at = 0;
	int64_t last_flush_check = 0;
	int64_t last_ready_ms = 0;
	int i;

	if (parse_args(argc, argv, &cfg) < 0) {
		usage(argv[0]);
		return 2;
	}

	signal(SIGINT, handle_signal);
	signal(SIGTERM, handle_signal);
	signal(SIGPIPE, SIG_IGN);

	memset(clients, 0, sizeof(clients));
	for (i = 0; i < MAX_CLIENTS; ++i)
		clients[i].fd = -1;

	listener = create_listener(&cfg);
	if (listener < 0) {
		perror("[relay] listen");
		return 1;
	}

	fprintf(
		stderr,
		"[relay] listening on %s:%d, content-type=%s\n",
		cfg.bind_address,
		cfg.port,
		cfg.content_type
	);
	fflush(stderr);

	while (running) {
		int64_t now = monotonic_ms();
		int ready;

		if (fifo_fd < 0 && now >= fifo_retry_at) {
			fifo_fd = open(cfg.fifo_path, O_RDONLY | O_NONBLOCK);
			if (fifo_fd >= 0) {
				fprintf(stderr, "[relay] fifo opened for reading: %s\n", cfg.fifo_path);
				fflush(stderr);
			}
			else {
				fifo_retry_at = now + (errno == ENOENT ? 1000 : 500);
			}
		}

		pollfds[0].fd = listener;
		pollfds[0].events = POLLIN;
		pollfds[0].revents = 0;
		pollfds[1].fd = fifo_fd;
		pollfds[1].events = fifo_fd >= 0 ? POLLIN : 0;
		pollfds[1].revents = 0;
		for (i = 0; i < MAX_CLIENTS; ++i) {
			pollfds[i + 2].fd = clients[i].fd;
			pollfds[i + 2].events = clients[i].streaming ? 0 : POLLIN;
			if (clients[i].prefix_off < clients[i].prefix_len || clients[i].audio_len > 0)
				pollfds[i + 2].events |= POLLOUT;
			pollfds[i + 2].revents = 0;
		}

		ready = poll(pollfds, MAX_CLIENTS + 2, 100);
		if (ready < 0) {
			if (errno == EINTR)
				continue;
			perror("[relay] poll");
			break;
		}

		if (pollfds[0].revents & POLLIN)
			accept_clients(listener, clients);

		if (fifo_fd >= 0 && pollfds[1].revents & (POLLIN | POLLHUP | POLLERR)) {
			for (;;) {
				unsigned char chunk[AUDIO_CHUNK_SIZE];
				ssize_t count = read(fifo_fd, chunk, sizeof(chunk));
				if (count > 0) {
					mark_ready(&cfg, &last_ready_ms);
					broadcast_audio(clients, chunk, (size_t) count);
					continue;
				}
				if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))
					break;
				close(fifo_fd);
				fifo_fd = -1;
				fifo_retry_at = monotonic_ms() + 500;
				fprintf(stderr, "[relay] fifo writer went away, reopening...\n");
				fflush(stderr);
				break;
			}
		}

		for (i = 0; i < MAX_CLIENTS; ++i) {
			short events = pollfds[i + 2].revents;
			if (clients[i].fd < 0 || !events)
				continue;
			if (events & (POLLERR | POLLHUP | POLLNVAL)) {
				client_reset(&clients[i]);
				continue;
			}
			if ((events & POLLIN) && !clients[i].streaming
				&& client_read_request(&clients[i], &cfg) < 0) {
				client_reset(&clients[i]);
				continue;
			}
			if ((events & POLLOUT) && client_send_pending(&clients[i]) < 0)
				client_reset(&clients[i]);
		}

		now = monotonic_ms();
		if (now - last_flush_check >= 100) {
			check_flush_file(&cfg, clients, &last_flush);
			last_flush_check = now;
		}
	}

	if (fifo_fd >= 0)
		close(fifo_fd);
	close(listener);
	for (i = 0; i < MAX_CLIENTS; ++i)
		client_reset(&clients[i]);
	return 0;
}
