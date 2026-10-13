"""Tunnel muse-ipv4's HTTPS CONNECT requests over IPv4 only.

Listens on an ephemeral 127.0.0.1 port and prints it on stdout. Exits when
stdin reaches end of file: the launcher holds the other end, so the proxy
stops with it however the launcher ends. Standard library only; run with -I.
"""
import asyncio
import os
import signal
import socket

TIMEOUT = 30


async def respond(writer, status):
    writer.write(f"HTTP/1.1 {status}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".encode())
    await writer.drain()


async def pipe(reader, writer):
    # Pass end of file on, so each direction can close on its own.
    while True:
        data = await reader.read(65536)
        if not data:
            break
        writer.write(data)
        await writer.drain()
    if writer.can_write_eof():
        writer.write_eof()


async def tunnel(client_reader, client_writer):
    upstream = None
    try:
        request = await asyncio.wait_for(client_reader.readuntil(b"\r\n\r\n"), TIMEOUT)
        line = request.split(b"\r\n", 1)[0].split(b" ")
        if len(line) == 3 and line[0] != b"CONNECT":
            return await respond(client_writer, "405 Method Not Allowed")
        try:
            host, _, port = line[1].decode("ascii").rpartition(":")
            port = int(port)
        except (IndexError, ValueError):
            return await respond(client_writer, "400 Bad Request")
        try:
            # An IPv6 literal or IPv6-only host fails here rather than leaking.
            upstream = await asyncio.wait_for(asyncio.open_connection(
                host.strip("[]"), port, family=socket.AF_INET), TIMEOUT)
        except (OSError, asyncio.TimeoutError, OverflowError, UnicodeError):
            return await respond(client_writer, "502 Bad Gateway")
        client_writer.write(b"HTTP/1.1 200 Connection established\r\n\r\n")
        await asyncio.gather(pipe(client_reader, upstream[1]), pipe(upstream[0], client_writer))
    except (OSError, asyncio.IncompleteReadError, asyncio.LimitOverrunError, asyncio.TimeoutError):
        pass
    finally:
        for writer in (client_writer, upstream and upstream[1]):
            if writer:
                writer.close()


async def main():
    server = await asyncio.start_server(tunnel, "127.0.0.1", 0)
    print(server.sockets[0].getsockname()[1], flush=True)

    def read_until_eof():
        while os.read(0, 4096):
            pass

    # A thread, since the event loop can't watch every kind of stdin.
    await asyncio.get_running_loop().run_in_executor(None, read_until_eof)
    # Returning cancels any open tunnels.
    server.close()


# Ctrl+C reaches the whole foreground process group. Muse decides what it means.
signal.signal(signal.SIGINT, signal.SIG_IGN)
signal.signal(signal.SIGQUIT, signal.SIG_IGN)
asyncio.run(main())
