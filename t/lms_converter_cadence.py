#!/usr/bin/env python3

import os
import re
import resource
import selectors
import shlex
import struct
import subprocess
import sys
import tempfile
import threading
import time


RATE = 44100
CHANNELS = 2
SOURCE_FRAME_BYTES = 8
CHUNK_FRAMES = 441
RUN_SECONDS = 4


def rule_command(config, rule, fifo):
    text = open(config, encoding="utf-8").read()
    match = re.search(
        rf"^{re.escape(rule)}\s*$.*?^\s*(\[ffmpeg\][^\r\n]*)$",
        text,
        re.MULTILINE | re.DOTALL,
    )
    if not match:
        raise SystemExit(f"missing conversion command for {rule}")
    command = match.group(1).replace("[ffmpeg]", "ffmpeg", 1)
    command = command.replace("$FILE$", fifo)
    return shlex.split(command)


def wav_header():
    return (
        b"RIFF"
        + struct.pack("<I", (36 + 0xFFFFFFFF) & 0xFFFFFFFF)
        + b"WAVEfmt "
        + struct.pack("<IHHIIHH", 16, 1, CHANNELS, RATE, RATE * 8, 8, 32)
        + b"data"
        + struct.pack("<I", 0xFFFFFFFF)
    )


def run_rule(config, rule, max_output_gap):
    with tempfile.TemporaryDirectory(prefix="soloist-converter-cadence-") as temp:
        fifo = os.path.join(temp, "source.wav")
        os.mkfifo(fifo)
        command = rule_command(config, rule, fifo)
        started = time.monotonic()
        process = subprocess.Popen(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0,
        )
        write_events = []

        def produce():
            frame = struct.pack("<ii", 0x08000000, -0x08000000)
            chunk = frame * CHUNK_FRAMES
            with open(fifo, "wb", buffering=0) as output:
                output.write(wav_header())
                deadline = time.monotonic()
                for _ in range(RUN_SECONDS * 100):
                    output.write(chunk)
                    write_events.append(time.monotonic())
                    deadline += 0.01
                    delay = deadline - time.monotonic()
                    if delay > 0:
                        time.sleep(delay)

        producer = threading.Thread(target=produce, daemon=True)
        producer.start()
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ)
        output_events = []
        output_bytes = 0
        while process.poll() is None or producer.is_alive():
            for key, _ in selector.select(0.1):
                data = os.read(key.fileobj.fileno(), 65536)
                if data:
                    output_bytes += len(data)
                    output_events.append(time.monotonic())
            if not producer.is_alive() and process.poll() is not None:
                break
        producer.join(timeout=1)
        remaining = process.stdout.read()
        if remaining:
            output_bytes += len(remaining)
            output_events.append(time.monotonic())
        stderr = process.stderr.read().decode("utf-8", "replace")
        status = process.wait(timeout=2)
        if status:
            raise SystemExit(f"{rule} converter failed ({status}): {stderr}")
        if not output_events:
            raise SystemExit(f"{rule} converter produced no output")

        startup = output_events[0] - started
        input_gaps = [b - a for a, b in zip(write_events, write_events[1:])]
        output_gaps = [b - a for a, b in zip(output_events, output_events[1:])]
        max_input_gap = max(input_gaps, default=0)
        max_gap = max(output_gaps, default=0)
        if startup > 0.250:
            raise SystemExit(f"{rule} startup latency was {startup * 1000:.1f} ms")
        if max_input_gap > 0.040:
            raise SystemExit(f"{rule} input cadence gap was {max_input_gap * 1000:.1f} ms")
        if max_gap > max_output_gap:
            raise SystemExit(f"{rule} output cadence gap was {max_gap * 1000:.1f} ms")
        if rule == "s32p pcm * *":
            expected = RUN_SECONDS * RATE * CHANNELS * 2
            if output_bytes != expected:
                raise SystemExit(f"PCM cadence output width mismatch: {output_bytes} != {expected}")
        elif output_bytes < 1024:
            raise SystemExit(f"{rule} produced implausibly little output: {output_bytes}")

        print(
            f"{rule}: startup={startup * 1000:.1f} ms "
            f"input_gap_max={max_input_gap * 1000:.1f} ms "
            f"output_gap_max={max_gap * 1000:.1f} ms bytes={output_bytes}"
        )


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: lms_converter_cadence.py custom-convert.conf")
    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    run_rule(sys.argv[1], "s32p pcm * *", 0.120)
    run_rule(sys.argv[1], "s32f flc * *", 0.180)
    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    cpu = (after.ru_utime - before.ru_utime) + (after.ru_stime - before.ru_stime)
    if cpu > 2.0:
        raise SystemExit(f"converter CPU time was unexpectedly high: {cpu:.3f} s")
    print(f"actual LMS converter commands used {cpu:.3f} s CPU")


if __name__ == "__main__":
    main()
