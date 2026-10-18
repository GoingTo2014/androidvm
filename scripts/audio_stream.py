#!/usr/bin/env python3
"""Low-latency PCM audio over WebSocket for AndroidVM.

FFmpeg captures the PulseAudio null-sink monitor and emits mono signed 16-bit
PCM at 22.05 kHz. Sending raw frames avoids the encoder and HTML media-element
buffering delay of a live MP3/Icecast stream.
"""
import asyncio
import contextlib

import websockets
from websockets.exceptions import ConnectionClosed

HOST = "127.0.0.1"
PORT = 8765
SAMPLE_RATE = 22050
CHUNK_BYTES = 2048  # about 46 ms of mono s16le audio at 22.05 kHz
clients = set()


async def audio_client(websocket, path=None):
    clients.add(websocket)
    print("Audio client connected; clients =", len(clients), flush=True)
    try:
        await websocket.wait_closed()
    finally:
        clients.discard(websocket)
        print("Audio client disconnected; clients =", len(clients), flush=True)


async def broadcast_loop():
    command = [
        "/usr/bin/ffmpeg",
        "-nostdin",
        "-hide_banner",
        "-loglevel", "warning",
        "-fflags", "nobuffer",
        "-flags", "low_delay",
        "-thread_queue_size", "16",
        "-f", "pulse",
        "-fragment_size", "1024",
        "-i", "vm_audio.monitor",
        "-ac", "1",
        "-ar", str(SAMPLE_RATE),
        "-acodec", "pcm_s16le",
        "-f", "s16le",
        "pipe:1",
    ]

    while True:
        process = None
        try:
            print("Starting low-latency PulseAudio PCM capture...", flush=True)
            process = await asyncio.create_subprocess_exec(
                *command,
                stdout=asyncio.subprocess.PIPE,
            )
            pending = bytearray()
            while True:
                data = await process.stdout.read(4096)
                if not data:
                    code = await process.wait()
                    raise RuntimeError("FFmpeg audio capture ended with exit code " + str(code))
                pending.extend(data)
                while len(pending) >= CHUNK_BYTES:
                    frame = bytes(pending[:CHUNK_BYTES])
                    del pending[:CHUNK_BYTES]
                    if not clients:
                        continue
                    stale = []
                    for websocket in tuple(clients):
                        try:
                            # Drop a slow client rather than queue seconds of stale audio.
                            await asyncio.wait_for(websocket.send(frame), timeout=0.08)
                        except (asyncio.TimeoutError, ConnectionClosed, OSError):
                            stale.append(websocket)
                    for websocket in stale:
                        clients.discard(websocket)
                        with contextlib.suppress(Exception):
                            await websocket.close(code=1013, reason="Audio client too slow")
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            print("Audio capture problem:", repr(exc), flush=True)
        finally:
            if process is not None and process.returncode is None:
                process.terminate()
                with contextlib.suppress(Exception):
                    await asyncio.wait_for(process.wait(), timeout=2)
                if process.returncode is None:
                    process.kill()
                    await process.wait()
        await asyncio.sleep(1)


async def main():
    async with websockets.serve(
        audio_client,
        HOST,
        PORT,
        ping_interval=20,
        ping_timeout=20,
        max_size=None,
        max_queue=2,
        write_limit=4096,
    ):
        print("Low-latency audio WebSocket listening on %s:%d" % (HOST, PORT), flush=True)
        await broadcast_loop()


if __name__ == "__main__":
    asyncio.run(main())
