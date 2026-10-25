#!/usr/bin/env python3

import argparse
import os
import socket
import subprocess
import tempfile
import threading
import time


def wait_for(predicate, timeout=5):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if predicate():
            return
        time.sleep(0.02)
    raise AssertionError("timed out waiting for condition")


def connect_client(port, receive_buffer=None):
    sock = socket.socket()
    if receive_buffer is not None:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, receive_buffer)
    sock.settimeout(5)
    sock.connect(("127.0.0.1", port))
    sock.sendall(b"GET /soloist.wav HTTP/1.1\r\nHost: localhost\r\n\r\n")
    received = b""
    while b"\r\n\r\n" not in received:
        received += sock.recv(1024)
    headers, payload = received.split(b"\r\n\r\n", 1)
    assert b"HTTP/1.1 200 OK" in headers
    while len(payload) < 44:
        payload += sock.recv(44 - len(payload))
    assert payload[:4] == b"RIFF"
    assert payload[8:12] == b"WAVE"
    return sock, payload[44:]


def read_exact(sock, initial, size):
    data = initial
    while len(data) < size:
        data += sock.recv(size - len(data))
    return data[:size]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("relay")
    args = parser.parse_args()

    with tempfile.TemporaryDirectory() as directory:
        fifo = os.path.join(directory, "audio.fifo")
        ready = os.path.join(directory, "relay.ready")
        flush = os.path.join(directory, "relay.flush")
        os.mkfifo(fifo)

        probe = socket.socket()
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
        probe.close()

        process = subprocess.Popen(
            [
                args.relay,
                "--fifo",
                fifo,
                "--port",
                str(port),
                "--bind",
                "127.0.0.1",
                "--content-type",
                "audio/wav",
                "--ready-file",
                ready,
                "--flush-file",
                flush,
                "--wav-stream",
                "--wav-sample-rate",
                "44100",
                "--wav-channels",
                "2",
                "--wav-bits-per-sample",
                "16",
            ],
            stderr=subprocess.PIPE,
            text=True,
        )

        try:
            wait_for(
                lambda: process.poll() is not None
                or _can_connect(port)
            )
            assert process.poll() is None

            first, first_initial = connect_client(port)
            second, second_initial = connect_client(port)

            with open(fifo, "wb", buffering=0) as writer:
                writer.write(b"A" * 8192)
            assert read_exact(first, first_initial, 8192) == b"A" * 8192
            assert read_exact(second, second_initial, 8192) == b"A" * 8192
            wait_for(lambda: os.path.exists(ready))

            time.sleep(0.6)
            with open(fifo, "wb", buffering=0) as writer:
                writer.write(b"B" * 4096)
            assert read_exact(first, b"", 4096) == b"B" * 4096
            assert read_exact(second, b"", 4096) == b"B" * 4096

            slow, _ = connect_client(port, receive_buffer=4096)

            def fill_slow_client():
                with open(fifo, "wb", buffering=0) as writer:
                    block = b"C" * 65536
                    for _ in range(256):
                        writer.write(block)

            producer = threading.Thread(target=fill_slow_client)
            producer.start()
            time.sleep(0.5)
            with open(flush, "ab"):
                pass
            os.utime(flush, None)
            time.sleep(0.3)
            producer.join(timeout=10)
            assert not producer.is_alive()

            first.close()
            second.close()
            slow.close()
        finally:
            process.terminate()
            try:
                _, stderr = process.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                _, stderr = process.communicate(timeout=5)

        assert process.returncode in (0, -15), (
            f"relay exited with {process.returncode}\n"
            f"stderr:\n{stderr}"
        )
        assert "fifo writer went away, reopening" in stderr
        assert "flushed " in stderr
        print("audio relay behavior OK")


def _can_connect(port):
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=0.1):
            return True
    except OSError:
        return False


if __name__ == "__main__":
    main()
