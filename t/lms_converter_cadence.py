#!/usr/bin/env python3

import os
import resource
import selectors
import struct
import subprocess
import tempfile
import threading
import time


RATE = 44100
CHANNELS = 2
SOURCE_FRAME_BYTES = 8
PCM_FRAME_BYTES = 4
CHUNK_FRAMES = 441
RUN_SECONDS = 8


def bridge_command(source, output_format):
    common = [
        "ffmpeg",
        "-nostdin",
        "-hide_banner",
        "-loglevel",
        "error",
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
            "-",
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
            "-",
        ]
    raise ValueError(output_format)


def run_format(output_format, recurring_reader_stalls):
    with tempfile.TemporaryDirectory(prefix="soloist-bridge-cadence-") as temp:
        fifo = os.path.join(temp, "source.s32le")
        os.mkfifo(fifo)
        before = resource.getrusage(resource.RUSAGE_CHILDREN)
        process = subprocess.Popen(
            bridge_command(fifo, output_format),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0,
        )
        write_events = []
        write_durations = []

        def produce():
            frame = struct.pack("<ii", 0x08000000, -0x08000000)
            chunk = frame * CHUNK_FRAMES
            with open(fifo, "wb", buffering=0) as output:
                deadline = time.monotonic()
                for _ in range(RUN_SECONDS * 100):
                    started = time.monotonic()
                    output.write(chunk)
                    write_durations.append(time.monotonic() - started)
                    write_events.append(time.monotonic())
                    deadline += 0.01
                    delay = deadline - time.monotonic()
                    if delay > 0:
                        time.sleep(delay)

        producer = threading.Thread(target=produce, daemon=True)
        producer.start()
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ)
        output_bytes = 0
        started = time.monotonic()
        next_stall = started + 0.75
        stall_count = 0
        while process.poll() is None or producer.is_alive():
            now = time.monotonic()
            if recurring_reader_stalls and producer.is_alive() and now >= next_stall:
                time.sleep(0.205)
                stall_count += 1
                next_stall += 0.75
            for key, _ in selector.select(0.02):
                data = os.read(key.fileobj.fileno(), 65536)
                if data:
                    output_bytes += len(data)
            if not producer.is_alive() and process.poll() is not None:
                break

        producer.join(timeout=2)
        remaining = process.stdout.read()
        if remaining:
            output_bytes += len(remaining)
        stderr = process.stderr.read().decode("utf-8", "replace")
        status = process.wait(timeout=3)
        if status:
            raise SystemExit(f"{output_format} bridge converter failed ({status}): {stderr}")
        if producer.is_alive():
            raise SystemExit(f"{output_format} S32 producer did not finish")

        input_gaps = [b - a for a, b in zip(write_events, write_events[1:])]
        max_gap = max(input_gaps, default=0)
        max_write = max(write_durations, default=0)
        if max_gap >= 0.200 or max_write >= 0.200:
            raise SystemExit(
                f"{output_format} recurring output stalls backpressured the S32 source "
                f"for {max(max_gap, max_write) * 1000:.1f} ms"
            )
        if recurring_reader_stalls and stall_count < 8:
            raise SystemExit(f"only exercised {stall_count} recurring reader stalls")
        if output_format == "pcm":
            expected = RUN_SECONDS * RATE * PCM_FRAME_BYTES
            if output_bytes != expected:
                raise SystemExit(f"PCM output width mismatch: {output_bytes} != {expected}")
        elif output_bytes < 1024:
            raise SystemExit(f"FLAC converter produced implausibly little output: {output_bytes}")

        after = resource.getrusage(resource.RUSAGE_CHILDREN)
        cpu = (after.ru_utime - before.ru_utime) + (after.ru_stime - before.ru_stime)
        print(
            f"{output_format}: bytes={output_bytes} stalls={stall_count} "
            f"source_gap_max={max_gap * 1000:.1f} ms "
            f"source_write_max={max_write * 1000:.1f} ms cpu={cpu:.3f} s"
        )


def main():
    run_format("pcm", recurring_reader_stalls=True)
    run_format("flac", recurring_reader_stalls=False)


if __name__ == "__main__":
    main()
