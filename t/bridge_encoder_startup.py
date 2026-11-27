#!/usr/bin/env python3

import errno
import os
import selectors
import struct
import subprocess
import tempfile
import threading
import time


RATE = 44100
CHANNELS = 2
CHUNK_FRAMES = 441
MAX_FIRST_BYTE_SECONDS = 0.5


def bridge_command(source, output, output_format):
    common = [
        "ffmpeg",
        "-nostdin",
        "-hide_banner",
        "-loglevel",
        "error",
        "-y",
        "-f",
        "s32le",
        "-ar",
        str(RATE),
        "-ac",
        str(CHANNELS),
        "-blocksize",
        "4096",
        "-i",
        source,
        "-map",
        "0:a:0",
    ]
    if output_format == "pcm":
        return common + [
            "-af",
            "aresample=osf=s16:dither_method=triangular",
            "-flush_packets",
            "1",
            "-f",
            "s16le",
            output,
        ]
    if output_format == "flac":
        return common + [
            "-af",
            "aresample=osf=s16:dither_method=triangular",
            "-c:a",
            "flac",
            "-sample_fmt",
            "s16",
            "-compression_level",
            "0",
            "-flush_packets",
            "1",
            "-f",
            "flac",
            output,
        ]
    if output_format == "mp3":
        return common + [
            "-c:a",
            "libmp3lame",
            "-b:a",
            "320k",
            "-flush_packets",
            "1",
            "-f",
            "mp3",
            output,
        ]
    raise ValueError(output_format)


def write_source(source_fd, started, start_time, stop):
    frame = struct.pack("<ii", 0x10000000, -0x10000000)
    chunk = frame * CHUNK_FRAMES
    deadline = time.monotonic()
    start_time.append(time.monotonic())
    started.set()
    for _ in range(100):
        if stop.is_set():
            return
        view = memoryview(chunk)
        while view and not stop.is_set():
            try:
                written = os.write(source_fd, view)
                view = view[written:]
            except BlockingIOError:
                time.sleep(0.001)
            except BrokenPipeError:
                return
        deadline += 0.01
        delay = deadline - time.monotonic()
        if delay > 0:
            time.sleep(delay)


def measure_format(output_format, source_delay):
    with tempfile.TemporaryDirectory(prefix="soloist-encoder-startup-") as temp:
        source = os.path.join(temp, "source.fifo")
        output = os.path.join(temp, "audio.fifo")
        os.mkfifo(source)
        os.mkfifo(output)

        source_fd = os.open(source, os.O_RDWR | os.O_NONBLOCK)
        process = subprocess.Popen(
            bridge_command(source, output, output_format),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
        )
        output_fd = None
        producer = None
        stop = threading.Event()
        try:
            time.sleep(0.1)
            if process.poll() is not None:
                stderr = process.stderr.read().decode("utf-8", "replace")
                raise SystemExit(
                    f"{output_format} converter exited before LMS opened its FIFO: {stderr}"
                )

            output_fd = os.open(output, os.O_RDONLY | os.O_NONBLOCK)
            time.sleep(source_delay)
            if process.poll() is not None:
                stderr = process.stderr.read().decode("utf-8", "replace")
                raise SystemExit(
                    f"{output_format} converter exited while waiting for source audio: {stderr}"
                )

            started = threading.Event()
            start_time = []
            producer = threading.Thread(
                target=write_source,
                args=(source_fd, started, start_time, stop),
                daemon=True,
            )
            producer.start()
            started.wait(timeout=1)
            if not start_time:
                raise SystemExit(f"{output_format} source producer did not start")
            source_started = start_time[0]

            selector = selectors.DefaultSelector()
            selector.register(output_fd, selectors.EVENT_READ)
            first = b""
            deadline = source_started + MAX_FIRST_BYTE_SECONDS
            while time.monotonic() < deadline and not first:
                for _, _ in selector.select(0.01):
                    try:
                        first = os.read(output_fd, 65536)
                    except BlockingIOError:
                        pass

            latency = time.monotonic() - source_started
            if not first:
                raise SystemExit(
                    f"{output_format} produced no final FIFO bytes within "
                    f"{MAX_FIRST_BYTE_SECONDS * 1000:.0f} ms"
                )
            if process.poll() is not None:
                stderr = process.stderr.read().decode("utf-8", "replace")
                raise SystemExit(
                    f"{output_format} converter exited after first output: {stderr}"
                )
            if output_format == "flac" and not first.startswith(b"fLaC"):
                raise SystemExit("FLAC output did not begin with a fresh stream header")

            print(
                f"{output_format}: first_final_bytes={len(first)} "
                f"source_delay={source_delay:.1f}s "
                f"first_byte_latency={latency * 1000:.1f}ms"
            )
        finally:
            stop.set()
            if producer is not None:
                producer.join(timeout=2)
            if output_fd is not None:
                os.close(output_fd)
            os.close(source_fd)
            if process.poll() is None:
                process.terminate()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=2)


def main():
    measure_format("pcm", source_delay=5.0)
    measure_format("flac", source_delay=0.1)
    measure_format("mp3", source_delay=0.1)


if __name__ == "__main__":
    try:
        main()
    except OSError as error:
        if error.errno in (errno.ENOSYS, errno.EOPNOTSUPP):
            raise SystemExit(f"FIFO startup test unsupported: {error}")
        raise
