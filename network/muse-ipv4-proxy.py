"""Tunnel muse-ipv4's HTTPS CONNECT requests over IPv4 only.

Listens on an ephemeral 127.0.0.1 port and prints it on stdout. The launcher
holds the other end of stdin, so end of file means it has exited, however it
ended. Muse's wrapper may have started a background self-update that is still
using the proxy, so the proxy keeps serving until it has had no tunnels for
GRACE seconds, and for at most CAP seconds. Standard library only; run with -I.
"""
import asyncio
import os
import signal
import socket
import time

# The updater makes a few requests in a row. The cap allows a slow download of
# the ~360 MB binary. Tests shorten these through the environment.
TIMEOUT = float(os.environ.get("MUSE_IPV4_PROXY_TIMEOUT", 30))
GRACE = float(os.environ.get("MUSE_IPV4_PROXY_GRACE", 10))
CAP = float(os.environ.get("MUSE_IPV4_PROXY_CAP", 600))
tunnels = 0
last_tunnel = 0.0


async def respond(writer, status):
    writer.write(f"HTTP/1.1 {status}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".encode())
    await writer.drain()


async def pipe(reader, writer, activity):
    # Pass end of file on, so each direction can close on its own.
    while True:
        data = await reader.read(65536)
        if not data:
            break
        activity[0] = time.monotonic()
        writer.write(data)
        await writer.drain()
    if writer.can_write_eof():
        writer.write_eof()


async def relay(client, upstream):
    activity = [time.monotonic()]
    directions = {asyncio.ensure_future(pipe(client[0], upstream[1], activity)),
                  asyncio.ensure_future(pipe(upstream[0], client[1], activity))}
    done, pending = await asyncio.wait(directions, return_when=asyncio.FIRST_COMPLETED)
    # Once one direction ends, a peer that never closes its side mustn't hold
    # the tunnel open: allow TIMEOUT seconds of quiet, then close both.
    while pending and not any(task.exception() for task in done):
        quiet = time.monotonic() - activity[0]
        if quiet >= TIMEOUT:
            break
        done, pending = await asyncio.wait(pending, timeout=TIMEOUT - quiet)
    for task in pending:
        task.cancel()
    await asyncio.gather(*directions, return_exceptions=True)


async def tunnel(client_reader, client_writer):
    global tunnels, last_tunnel
    tunnels += 1
    upstream = None
    try:
        request = await asyncio.wait_for(client_reader.readuntil(b"\r\n\r\n"), TIMEOUT)
        # Only "CONNECT host:port HTTP/1.x".
        line = request.split(b"\r\n", 1)[0].split(b" ")
        if len(line) != 3 or line[2] not in (b"HTTP/1.0", b"HTTP/1.1"):
            return await respond(client_writer, "400 Bad Request")
        if line[0] != b"CONNECT":
            return await respond(client_writer, "405 Method Not Allowed")
        try:
            host, _, port = line[1].decode("ascii").rpartition(":")
            port = int(port)
        except ValueError:
            host, port = "", 0
        if not host or not 0 < port < 65536:
            return await respond(client_writer, "400 Bad Request")
        try:
            # An IPv6 literal or IPv6-only host fails here rather than leaking.
            upstream = await asyncio.wait_for(asyncio.open_connection(
                host.strip("[]"), port, family=socket.AF_INET), TIMEOUT)
        except (OSError, asyncio.TimeoutError, UnicodeError):
            return await respond(client_writer, "502 Bad Gateway")
        client_writer.write(b"HTTP/1.1 200 Connection established\r\n\r\n")
        await relay((client_reader, client_writer), upstream)
    except (OSError, asyncio.IncompleteReadError, asyncio.LimitOverrunError, asyncio.TimeoutError):
        pass
    finally:
        for writer in (client_writer, upstream and upstream[1]):
            if writer:
                writer.close()
        tunnels -= 1
        last_tunnel = time.monotonic()


async def main():
    server = await asyncio.start_server(tunnel, "127.0.0.1", 0)
    print(server.sockets[0].getsockname()[1], flush=True)
    # Don't hold the launcher's stderr open, or callers reading it would wait
    # for the proxy rather than for Muse.
    os.dup2(os.open(os.devnull, os.O_WRONLY), 2)

    def read_until_eof():
        while os.read(0, 4096):
            pass

    # A thread, since the event loop can't watch every kind of stdin.
    await asyncio.get_running_loop().run_in_executor(None, read_until_eof)
    launcher_gone = time.monotonic()
    while time.monotonic() - launcher_gone < CAP:
        if not tunnels and time.monotonic() - max(launcher_gone, last_tunnel) >= GRACE:
            break
        await asyncio.sleep(0.1)
    server.close()
    # Exit now: a normal return would wait for any DNS lookup still running in
    # a thread, and drops the remaining tunnels anyway.
    os._exit(0)


# Ctrl+C reaches the whole foreground process group. Muse decides what it means.
signal.signal(signal.SIGINT, signal.SIG_IGN)
signal.signal(signal.SIGQUIT, signal.SIG_IGN)
asyncio.run(main())
