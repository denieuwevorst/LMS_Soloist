#!/usr/bin/env python3
"""
audio-relay.py -- tiny multi-client HTTP audio broadcaster.

Replaces Icecast for this bridge: ffmpeg writes its continuously-encoded
audio into a named pipe (FIFO); this script reads that FIFO and fans each
chunk out to every currently-connected HTTP client, the same broadcast
role Icecast (or ShairTunes2's own embedded C helper) plays.

Why a FIFO and not a plain `ffmpeg | audio-relay.py` shell pipe: if ffmpeg
restarts (a Pulse hiccup, etc.), a shell pipe closes for good along with
it, taking this process down too. A FIFO lets the reader thread just loop
back and reopen it -- ffmpeg's own restart loop can come and go without
this relay (or any already-connected HTTP client) needing to restart.
Connected clients experience a brief gap, not a dropped connection.

Usage:
  audio-relay.py --fifo /tmp/soloist-audio.fifo --port 9077 \
                  --bind 0.0.0.0 --content-type audio/mpeg
"""

import argparse
import os
import queue
import socket
import socketserver
import struct
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler


class Broadcaster:
    """Fans out chunks read from the FIFO to every registered client queue."""

    def __init__(self, fifo_path, chunk_size=4096, queue_maxsize=256, ready_path=None, ready_touch_interval=0.25, flush_path=None):
        self.fifo_path = fifo_path
        self.chunk_size = chunk_size
        self.queue_maxsize = queue_maxsize
        self.ready_path = ready_path
        self.ready_touch_interval = ready_touch_interval
        self.flush_path = flush_path
        self._last_ready_touch = 0.0
        self._last_flush_touch = 0.0
        self._clients = set()
        self._lock = threading.Lock()

    def register(self):
        q = queue.Queue(maxsize=self.queue_maxsize)
        with self._lock:
            self._clients.add(q)
        return q

    def unregister(self, q):
        with self._lock:
            self._clients.discard(q)

    def _broadcast(self, chunk):
        with self._lock:
            clients = list(self._clients)
        for q in clients:
            try:
                q.put_nowait(chunk)
            except queue.Full:
                # Slow/stuck client: drop it rather than let one bad
                # listener back up memory for everyone else.
                try:
                    q.get_nowait()
                    q.put_nowait(chunk)
                except queue.Empty:
                    pass

    def _mark_ready(self):
        if not self.ready_path:
            return

        now = time.time()
        if self._last_ready_touch and now - self._last_ready_touch < self.ready_touch_interval:
            return

        try:
            with open(self.ready_path, "ab"):
                pass
            os.utime(self.ready_path, None)
            self._last_ready_touch = now
        except OSError:
            pass

    def _flush_clients(self):
        flushed = 0
        with self._lock:
            clients = list(self._clients)
        for q in clients:
            while True:
                try:
                    q.get_nowait()
                    flushed += 1
                except queue.Empty:
                    break
        if flushed:
            print(f"[relay] flushed {flushed} queued chunk(s)", file=sys.stderr, flush=True)

    def _check_flush_request(self):
        if not self.flush_path:
            return

        try:
            stat = os.stat(self.flush_path)
        except OSError:
            return

        if stat.st_mtime <= self._last_flush_touch:
            return

        self._last_flush_touch = stat.st_mtime
        self._flush_clients()

    def watch_flush_requests(self):
        while True:
            self._check_flush_request()
            time.sleep(0.1)

    def run_forever(self):
        while True:
            try:
                with open(self.fifo_path, "rb") as fifo:
                    print(f"[relay] fifo opened for reading: {self.fifo_path}", file=sys.stderr, flush=True)
                    while True:
                        chunk = fifo.read(self.chunk_size)
                        if not chunk:
                            # Writer (ffmpeg) closed its end -- reopen and
                            # wait for the next one.
                            break
                        self._mark_ready()
                        self._broadcast(chunk)
            except FileNotFoundError:
                time.sleep(1)
                continue
            print("[relay] fifo writer went away, reopening...", file=sys.stderr, flush=True)
            time.sleep(0.5)


def make_handler(broadcaster, content_type):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def do_GET(self):
            q = broadcaster.register()
            try:
                self.send_response(200)
                self.send_header("Content-Type", content_type)
                self.send_header("Cache-Control", "no-cache")
                self.send_header("Connection", "close")
                self.end_headers()

                if broadcaster.wav_stream:
                    self.wfile.write(make_wav_header(
                        broadcaster.wav_sample_rate,
                        broadcaster.wav_channels,
                        broadcaster.wav_bits_per_sample,
                    ))

                while True:
                    chunk = q.get()
                    self.wfile.write(chunk)
            except (BrokenPipeError, ConnectionResetError, OSError):
                pass
            finally:
                broadcaster.unregister(q)

        def log_message(self, fmt, *args):
            print(f"[relay] {self.address_string()} - {fmt % args}", file=sys.stderr, flush=True)

    return Handler


class ThreadingHTTPServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True
    daemon_threads = True


def make_wav_header(sample_rate, channels, bits_per_sample):
    byte_rate = sample_rate * channels * bits_per_sample // 8
    block_align = channels * bits_per_sample // 8
    # Streaming WAV: use an "unknown/very large" data size so clients can
    # start decoding immediately while the stream keeps growing.
    data_size = 0xFFFFFFFF
    riff_size = 36 + data_size
    return (
        b"RIFF"
        + struct.pack("<I", riff_size & 0xFFFFFFFF)
        + b"WAVE"
        + b"fmt "
        + struct.pack("<IHHIIHH", 16, 1, channels, sample_rate, byte_rate, block_align, bits_per_sample)
        + b"data"
        + struct.pack("<I", data_size)
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--fifo", required=True, help="Path to the FIFO ffmpeg writes into")
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--bind", default="0.0.0.0")
    parser.add_argument("--content-type", default="audio/mpeg")
    parser.add_argument("--ready-file", default="")
    parser.add_argument("--flush-file", default="")
    parser.add_argument("--wav-stream", action="store_true")
    parser.add_argument("--wav-sample-rate", type=int, default=44100)
    parser.add_argument("--wav-channels", type=int, default=2)
    parser.add_argument("--wav-bits-per-sample", type=int, default=16)
    args = parser.parse_args()

    broadcaster = Broadcaster(args.fifo, ready_path=(args.ready_file or None), flush_path=(args.flush_file or None))
    broadcaster.wav_stream = args.wav_stream
    broadcaster.wav_sample_rate = args.wav_sample_rate
    broadcaster.wav_channels = args.wav_channels
    broadcaster.wav_bits_per_sample = args.wav_bits_per_sample
    reader_thread = threading.Thread(target=broadcaster.run_forever, daemon=True)
    reader_thread.start()
    if broadcaster.flush_path:
        flush_thread = threading.Thread(target=broadcaster.watch_flush_requests, daemon=True)
        flush_thread.start()

    handler_cls = make_handler(broadcaster, args.content_type)
    server = ThreadingHTTPServer((args.bind, args.port), handler_cls)
    print(f"[relay] listening on {args.bind}:{args.port}, content-type={args.content_type}", file=sys.stderr, flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
