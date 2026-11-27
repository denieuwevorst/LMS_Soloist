#!/usr/bin/env python3

import errno
import os
import selectors
import shutil
import struct
import subprocess
import tempfile
import threading
import time


RATE = 44100
CHANNELS = 2
CHUNK_FRAMES = 441
MAX_FIRST_BYTE_SECONDS = 0.5
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIFO_READER_WAIT = os.path.join(ROOT, "Bin", "wait-for-fifo-reader.pl")


def bridge_command(source, output, output_format):
    common = [
        "ffmpeg",
        "-nostdin",
        "-hide_banner",
        "-loglevel",
        "error",
        "-y",
        "-analyzeduration",
        "0",
        "-probesize",
        "32",
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


def write_source(source_fd, started, start_time, stop, write_durations):
    frame = struct.pack("<ii", 0x10000000, -0x10000000)
    chunk = frame * CHUNK_FRAMES
    deadline = time.monotonic()
    start_time.append(time.monotonic())
    started.set()
    while not stop.is_set():
        write_started = time.monotonic()
        view = memoryview(chunk)
        while view and not stop.is_set():
            try:
                written = os.write(source_fd, view)
                view = view[written:]
            except BlockingIOError:
                time.sleep(0.001)
            except BrokenPipeError:
                return
        write_durations.append(time.monotonic() - write_started)
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
        process = None
        drainer = None
        waiter = None
        output_fd = None
        producer = None
        stop = threading.Event()
        try:
            started = threading.Event()
            start_time = []
            write_durations = []
            producer = threading.Thread(
                target=write_source,
                args=(source_fd, started, start_time, stop, write_durations),
                daemon=True,
            )
            drainer = subprocess.Popen(
                ["cat", source],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
            )
            waiter = subprocess.Popen(
                [
                    os.environ.get("PERL", "perl"),
                    FIFO_READER_WAIT,
                    output,
                    str(os.getpid()),
                ],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
            )
            producer.start()
            started.wait(timeout=1)
            if not start_time:
                raise SystemExit(f"{output_format} source producer did not start")
            time.sleep(source_delay)
            if drainer.poll() is not None:
                stderr = drainer.stderr.read().decode("utf-8", "replace")
                raise SystemExit(
                    f"{output_format} standby source drainer exited before LMS reader: {stderr}"
                )
            if waiter.poll() is not None:
                stderr = waiter.stderr.read().decode("utf-8", "replace")
                raise SystemExit(
                    f"{output_format} reader detector exited before LMS reader: {stderr}"
                )
            if max(write_durations, default=0) >= 0.2:
                raise SystemExit(
                    f"{output_format} source blocked for "
                    f"{max(write_durations) * 1000:.1f} ms without an LMS reader"
                )

            reader_opened = time.monotonic()
            output_fd = os.open(output, os.O_RDONLY | os.O_NONBLOCK)
            waiter_status = waiter.wait(timeout=1)
            if waiter_status:
                stderr = waiter.stderr.read().decode("utf-8", "replace")
                raise SystemExit(
                    f"{output_format} reader detector failed ({waiter_status}): {stderr}"
                )
            drainer.terminate()
            drainer.wait(timeout=1)
            process = subprocess.Popen(
                bridge_command(source, output, output_format),
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
            )

            selector = selectors.DefaultSelector()
            selector.register(output_fd, selectors.EVENT_READ)
            first = b""
            deadline = reader_opened + MAX_FIRST_BYTE_SECONDS
            while time.monotonic() < deadline and not first:
                for _, _ in selector.select(0.01):
                    try:
                        first = os.read(output_fd, 65536)
                    except BlockingIOError:
                        pass

            latency = time.monotonic() - reader_opened
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
            if waiter is not None and waiter.poll() is None:
                waiter.terminate()
                waiter.wait(timeout=2)
            if drainer is not None and drainer.poll() is None:
                drainer.terminate()
                drainer.wait(timeout=2)
            if output_fd is not None:
                os.close(output_fd)
            os.close(source_fd)
            if process is not None and process.poll() is None:
                process.terminate()
            if process is not None:
                try:
                    process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=2)


def main():
    for command in ("ffmpeg", "cat", os.environ.get("PERL", "perl")):
        if not shutil.which(command):
            raise SystemExit(f"{command} is required for the FIFO startup test")
    measure_format("pcm", source_delay=5.0)
    measure_format("flac", source_delay=5.0)
    measure_format("mp3", source_delay=5.0)


if __name__ == "__main__":
    try:
        main()
    except OSError as error:
        if error.errno in (errno.ENOSYS, errno.EOPNOTSUPP):
            raise SystemExit(f"FIFO startup test unsupported: {error}")
        raise
