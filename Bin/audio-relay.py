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
import queue
import socket
import socketserver
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler


class Broadcaster:
    """Fans out chunks read from the FIFO to every registered client queue."""

    def __init__(self, fifo_path, chunk_size=4096, queue_maxsize=256):
        self.fifo_path = fifo_path
        self.chunk_size = chunk_size
        self.queue_maxsize = queue_maxsize
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


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--fifo", required=True, help="Path to the FIFO ffmpeg writes into")
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--bind", default="0.0.0.0")
    parser.add_argument("--content-type", default="audio/mpeg")
    args = parser.parse_args()

    broadcaster = Broadcaster(args.fifo)
    reader_thread = threading.Thread(target=broadcaster.run_forever, daemon=True)
    reader_thread.start()

    handler_cls = make_handler(broadcaster, args.content_type)
    server = ThreadingHTTPServer((args.bind, args.port), handler_cls)
    print(f"[relay] listening on {args.bind}:{args.port}, content-type={args.content_type}", file=sys.stderr, flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
