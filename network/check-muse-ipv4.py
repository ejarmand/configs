"""Exercise the Muse IPv4 proxy and launcher offline, against a stub muse."""
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import termios
import threading
import time

repo = Path(__file__).resolve().parent.parent
PROXY = repo / "network/muse-ipv4-proxy.py"
# Short timings so lifetime checks finish quickly.
FAST = {"MUSE_IPV4_PROXY_TIMEOUT": "1", "MUSE_IPV4_PROXY_GRACE": "0.5",
        "MUSE_IPV4_PROXY_CAP": "3"}


def server(family, host, handle):
    """Listen on HOST and run HANDLE for each connection in its own thread."""
    listener = socket.socket(family, socket.SOCK_STREAM)
    listener.bind((host, 0))
    listener.listen()
    peers = []

    def serve():
        while True:
            try:
                connection, peer = listener.accept()
            except OSError:
                return
            peers.append(peer)
            threading.Thread(target=handle, args=(connection,), daemon=True).start()

    threading.Thread(target=serve, daemon=True).start()
    return listener.getsockname()[1], peers


def echo(connection):
    with connection:
        while data := connection.recv(65536):
            connection.sendall(data)


def silent(connection):
    # Never answers and never closes, like a stuck upstream.
    time.sleep(3600)


def start_proxy(command=None, **overrides):
    environment = {**os.environ, **FAST, **overrides}
    process = subprocess.Popen(command or [sys.executable, "-I", str(PROXY)], env=environment,
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    return process, int(process.stdout.readline())


def open_tunnel(port, request):
    """Send REQUEST to the proxy; return the socket and the response's status line."""
    client = socket.create_connection(("127.0.0.1", port), timeout=10)
    client.sendall(request)
    reply = b""
    while b"\r\n\r\n" not in reply:
        chunk = client.recv(65536)
        if not chunk:
            break
        reply += chunk
    return client, reply.split(b"\r\n")[0].decode()


def round_trip(client, payload):
    client.sendall(payload)
    client.shutdown(socket.SHUT_WR)
    echoed = b""
    while chunk := client.recv(65536):
        echoed += chunk
    client.close()
    return echoed


def wait_until(condition, timeout=5):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if condition():
            return True
        time.sleep(0.05)
    return condition()


def running(path):
    """PIDs of processes whose command line mentions PATH."""
    found = []
    for entry in Path("/proc").iterdir():
        try:
            if str(path).encode() in (entry / "cmdline").read_bytes():
                found.append(int(entry.name))
        except (OSError, ValueError):
            pass
    return found


# The proxy on its own.
proxy, port = start_proxy()
v4, v4_peers = server(socket.AF_INET, "127.0.0.1", echo)
client, status = open_tunnel(port, f"CONNECT localhost:{v4} HTTP/1.1\r\nHost: x\r\n\r\n".encode())
assert status == "HTTP/1.1 200 Connection established", status
assert round_trip(client, b"ping") == b"ping"
assert v4_peers[-1][0] == "127.0.0.1", v4_peers
print("PASS CONNECT tunnels both directions over IPv4")

# Every tunnel is open before any of them sends data.
tunnels = [open_tunnel(port, f"CONNECT 127.0.0.1:{v4} HTTP/1.1\r\n\r\n".encode()) for _ in range(5)]
assert all(status.startswith("HTTP/1.1 200") for _, status in tunnels), tunnels
for number, (client, _) in reversed(list(enumerate(tunnels))):
    assert round_trip(client, b"tunnel %d" % number) == b"tunnel %d" % number
print("PASS simultaneous tunnels stay independent")

v6, v6_peers = server(socket.AF_INET6, "::1", echo)
# Hold the IPv4 side of the port without listening, so only IPv6 would answer.
with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as reserved:
    reserved.bind(("127.0.0.1", v6))
    for target in (f"localhost:{v6}", f"[::1]:{v6}"):
        client, status = open_tunnel(port, f"CONNECT {target} HTTP/1.1\r\n\r\n".encode())
        client.close()
        assert status == "HTTP/1.1 502 Bad Gateway", (target, status)
assert not v6_peers, v6_peers
print("PASS IPv6-only upstreams get 502, never an IPv6 connection")

connections = len(v4_peers)
for line, expected in [
    ("GET http://localhost/ HTTP/1.1", "405 Method Not Allowed"),
    (f"GET 127.0.0.1:{v4} HTTP/1.1", "405 Method Not Allowed"),
    (f"GET 127.0.0.1:{v4}", "400 Bad Request"),
    (f"POST 127.0.0.1:{v4} HTTP/1.1 extra", "400 Bad Request"),
    (f"CONNECT 127.0.0.1:{v4}", "400 Bad Request"),
    (f"CONNECT 127.0.0.1:{v4} HTTP/2", "400 Bad Request"),
    ("CONNECT 127.0.0.1 HTTP/1.1", "400 Bad Request"),
    (f"CONNECT :{v4} HTTP/1.1", "400 Bad Request"),
    ("CONNECT 127.0.0.1:70000 HTTP/1.1", "400 Bad Request"),
    ("nonsense", "400 Bad Request"),
]:
    client, status = open_tunnel(port, f"{line}\r\n\r\n".encode())
    client.close()
    assert status == f"HTTP/1.1 {expected}", (line, status)
assert len(v4_peers) == connections, v4_peers
print("PASS only CONNECT host:port HTTP/1.x opens a tunnel")

# A client that closes its side mustn't leave a tunnel to a silent upstream.
quiet, _ = server(socket.AF_INET, "127.0.0.1", silent)
descriptors = len(os.listdir(f"/proc/{proxy.pid}/fd"))
stuck = []
for _ in range(5):
    client, status = open_tunnel(port, f"CONNECT 127.0.0.1:{quiet} HTTP/1.1\r\n\r\n".encode())
    assert status.startswith("HTTP/1.1 200"), status
    client.shutdown(socket.SHUT_WR)
    stuck.append(client)
for client in stuck:
    assert client.recv(1024) == b""  # within the 10 s socket timeout
    client.close()
assert wait_until(lambda: len(os.listdir(f"/proc/{proxy.pid}/fd")) <= descriptors)
print("PASS half-closed tunnels to a silent upstream close after the idle timeout")
proxy.stdin.close()
assert proxy.wait(timeout=5) == 0

# After the launcher's pipe closes, later requests still work until idle.
proxy, port = start_proxy(MUSE_IPV4_PROXY_GRACE="1")
proxy.stdin.close()
for _ in range(3):
    time.sleep(0.6)
    client, status = open_tunnel(port, f"CONNECT 127.0.0.1:{v4} HTTP/1.1\r\n\r\n".encode())
    assert status.startswith("HTTP/1.1 200") and round_trip(client, b"later") == b"later"
idle_since = time.monotonic()
assert proxy.wait(timeout=5) == 0
assert 0.9 <= time.monotonic() - idle_since < 3, time.monotonic() - idle_since
print("PASS proxy serves until idle for the grace period after its stdin closes")

# An open tunnel can't keep it alive past the cap.
proxy, port = start_proxy(MUSE_IPV4_PROXY_TIMEOUT="30", MUSE_IPV4_PROXY_CAP="1.5")
client, status = open_tunnel(port, f"CONNECT 127.0.0.1:{v4} HTTP/1.1\r\n\r\n".encode())
assert status.startswith("HTTP/1.1 200")
proxy.stdin.close()
assert proxy.wait(timeout=4) == 0
client.close()
print("PASS an open tunnel doesn't keep the proxy past its cap")

# Nor can a DNS lookup that never returns.
stalled_dns = ("import runpy, socket, sys, time\n"
               "real = socket.getaddrinfo\n"
               "def stall(host, *args, **kwargs):\n"
               "    if host == 'stall.invalid': time.sleep(60)\n"
               "    return real(host, *args, **kwargs)\n"
               "socket.getaddrinfo = stall\n"
               "runpy.run_path(sys.argv[1], run_name='__main__')\n")
proxy, port = start_proxy([sys.executable, "-I", "-c", stalled_dns, str(PROXY)],
                          MUSE_IPV4_PROXY_CAP="1")
client = socket.create_connection(("127.0.0.1", port))
client.sendall(b"CONNECT stall.invalid:443 HTTP/1.1\r\n\r\n")
time.sleep(0.2)
proxy.stdin.close()
assert proxy.wait(timeout=4) == 0
client.close()
print("PASS a stalled DNS lookup doesn't delay exit")

# The launcher, installed as install-tools.sh does, against a stub muse.
STUB = f"""#!{sys.executable}
import json, os, signal, socket, subprocess, sys, time
out = os.environ["MUSE_STUB_OUT"]

def through_proxy():
    proxy = os.environ["HTTPS_PROXY"].rpartition(":")
    with socket.create_connection(("127.0.0.1", int(proxy[2])), timeout=10) as client:
        client.sendall(b"CONNECT 127.0.0.1:%s HTTP/1.1\\r\\n\\r\\n" % os.environ["MUSE_STUB_TARGET"].encode())
        reply = client.recv(1024)
        client.sendall(b"pong")
        client.shutdown(socket.SHUT_WR)
        return (reply + client.recv(1024)).decode()

def record(**values):
    with open(out, "a") as file:
        file.write(json.dumps(values) + "\\n")

mode = sys.argv[1]
if mode == "report":
    ignored = int(next(l for l in open("/proc/self/status") if l.startswith("SigIgn")).split()[1], 16)
    tty = os.isatty(0)
    record(env={{k: os.environ.get(k) for k in ("HTTPS_PROXY", "https_proxy", "NO_PROXY", "no_proxy",
                                                "HTTP_PROXY", "MUSE_HTTP_PROXY")}},
           args=sys.argv[1:], stdin=None if tty else sys.stdin.read(),
           foreground=tty and os.tcgetpgrp(0) == os.getpgrp(),
           int_quit_ignored=bool(ignored & 0x6), tunnel=through_proxy())
    sys.exit(7)
if mode == "update":
    # Like Muse's wrapper: start a background updater, then exit at once.
    subprocess.Popen([sys.argv[0], "updater"], stdin=subprocess.DEVNULL,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    sys.exit(0)
if mode == "updater":
    for _ in range(2):
        time.sleep(0.5)
        record(update=through_proxy())
    sys.exit(0)
caught = []
for name in ("INT", "TERM", "HUP", "QUIT"):
    signal.signal(getattr(signal, "SIG" + name), lambda *_, name=name: caught.append(name))
record(pid=os.getpid())
while not caught:
    time.sleep(0.05)
# A signal mustn't have stopped the proxy while Muse keeps running.
record(signal=caught[0], tunnel=through_proxy())
sys.exit(3)
"""

with tempfile.TemporaryDirectory(prefix="muse-ipv4-check-") as temporary:
    root = Path(temporary)
    home = root / "home"
    bin_dir = home / ".local/bin"
    bin_dir.mkdir(parents=True)
    dest = root / "data/configs/muse-ipv4"
    dest.mkdir(parents=True)
    for name in ("muse-ipv4", "muse-ipv4-proxy.py"):
        shutil.copy2(repo / "network" / name, dest / name)
    launcher = bin_dir / "muse-ipv4"
    launcher.symlink_to(dest / "muse-ipv4")
    out = root / "out.jsonl"
    env = {"PATH": os.path.dirname(sys.executable) + ":" + os.defpath, "HOME": str(home),
           "LANG": "C", "MUSE_STUB_OUT": str(out), "MUSE_STUB_TARGET": str(v4),
           "NO_PROXY": "example.com", "HTTP_PROXY": "http://unchanged.invalid:1", **FAST}
    installed_proxy = dest / "muse-ipv4-proxy.py"

    def records():
        try:
            return [json.loads(line) for line in out.read_text().splitlines()]
        except FileNotFoundError:
            return []

    def started():
        return records() and "pid" in records()[-1]

    result = subprocess.run([str(launcher), "report"], env=env, text=True, capture_output=True)
    assert result.returncode == 1 and "Missing" in result.stderr, result
    assert not running(installed_proxy)
    print("PASS missing muse fails clearly, before starting the proxy")

    stub = bin_dir / "muse"
    stub.write_text(STUB)
    stub.chmod(0o755)
    result = subprocess.run([str(launcher), "report", "argument with spaces"], env=env, text=True,
                            input="from stdin", capture_output=True)
    assert result.returncode == 7, result
    report = records()[-1]
    proxy_url = report["env"]["HTTPS_PROXY"]
    assert proxy_url.startswith("http://127.0.0.1:") and report["env"]["https_proxy"] == proxy_url, report
    assert report["env"]["HTTP_PROXY"] == "http://unchanged.invalid:1", report
    assert report["env"]["MUSE_HTTP_PROXY"] is None, report
    assert report["args"] == ["report", "argument with spaces"], report
    assert report["stdin"] == "from stdin" and not report["int_quit_ignored"], report
    assert report["tunnel"].startswith("HTTP/1.1 200") and report["tunnel"].endswith("pong"), report
    assert wait_until(lambda: not running(installed_proxy))
    print("PASS environment, arguments, stdin and exit status pass through; proxy stopped")

    local = "localhost,127.0.0.1,::1"
    for preset, expected in [({"NO_PROXY": "example.com"}, "example.com," + local),
                             ({"no_proxy": "corp.test"}, "corp.test," + local),
                             ({"NO_PROXY": "", "no_proxy": "corp.test"}, "corp.test," + local),
                             ({}, local)]:
        case = {key: value for key, value in env.items() if key != "NO_PROXY"}
        subprocess.run([str(launcher), "report"], env={**case, **preset}, input="", check=False)
        report = records()[-1]["env"]
        assert report["NO_PROXY"] == report["no_proxy"] == expected, (preset, report)
    print("PASS NO_PROXY and no_proxy merge, with an empty value counting as unset")

    # Muse's wrapper may start a background update and exit at once, as for
    # T3's `muse --version` probe. The proxy has to outlast the launcher.
    out.unlink()
    begun = time.monotonic()
    result = subprocess.run([str(launcher), "update"], env={**env, "MUSE_IPV4_PROXY_GRACE": "2"},
                            capture_output=True)
    assert result.returncode == 0 and time.monotonic() - begun < 2, (result, time.monotonic() - begun)
    assert wait_until(lambda: len(records()) == 2, timeout=10), records()
    assert all(r["update"].startswith("HTTP/1.1 200") and r["update"].endswith("pong")
               for r in records()), records()
    assert wait_until(lambda: not running(installed_proxy), timeout=6)
    print("PASS the launcher returns at once; the proxy serves a background update, then exits")

    # An interactive terminal: Muse is in the foreground and handles Ctrl+C.
    def on_terminal(mode):
        master, slave = os.openpty()

        def controlling_terminal():
            import fcntl
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)

        process = subprocess.Popen([str(launcher), mode], env=env, stdin=slave, stdout=slave,
                                   stderr=slave, start_new_session=True,
                                   preexec_fn=controlling_terminal)
        os.close(slave)
        return process, master

    process, master = on_terminal("report")
    assert process.wait(timeout=10) == 7
    os.close(master)
    report = records()[-1]
    assert report["foreground"] and not report["int_quit_ignored"], report
    print("PASS on a terminal, muse runs in the foreground process group")

    out.unlink()
    process, master = on_terminal("wait")
    assert wait_until(started)
    os.write(master, b"\x03")
    assert process.wait(timeout=10) == 3
    os.close(master)
    report = records()[-1]
    assert report["signal"] == "INT" and report["tunnel"].startswith("HTTP/1.1 200"), report
    assert wait_until(lambda: not running(installed_proxy))
    print("PASS Ctrl+C reaches muse; the launcher and proxy keep running until it exits")

    # Under stdio pipes, as T3 runs `muse serve`, signals come to the launcher.
    for name in ("INT", "QUIT", "TERM", "HUP"):
        out.unlink()
        process = subprocess.Popen([str(launcher), "wait"], env=env, stdin=subprocess.PIPE)
        assert wait_until(started)
        process.send_signal(getattr(signal, "SIG" + name))
        assert process.wait(timeout=10) == 3
        report = records()[-1]
        assert report["signal"] == name and report["tunnel"].startswith("HTTP/1.1 200"), report
        assert wait_until(lambda: not running(installed_proxy))
    print("PASS without a terminal, INT, QUIT, TERM and HUP are forwarded to muse")

    out.unlink()
    process = subprocess.Popen([str(launcher), "wait"], env=env, stdin=subprocess.PIPE)
    assert wait_until(started)
    muse = records()[-1]["pid"]
    assert running(installed_proxy)
    process.kill()
    process.wait()
    assert wait_until(lambda: not running(installed_proxy))
    os.kill(muse, signal.SIGKILL)
    print("PASS proxy exits on its own when the launcher is killed")

    # A proxy that never reports a port fails the launch instead of hanging.
    fake = root / "fake-python"
    fake.mkdir()
    (fake / "python3").write_text(f'#!/bin/sh\necho $$ > "{root}/fake.pid"\nexec sleep 60 2>/dev/null\n')
    (fake / "python3").chmod(0o755)
    begun = time.monotonic()
    result = subprocess.run([str(launcher), "report"], env={**env, "PATH": f"{fake}:{env['PATH']}"},
                            text=True, capture_output=True, timeout=30)
    os.kill(int((root / "fake.pid").read_text()), signal.SIGKILL)
    assert result.returncode == 1 and "did not start" in result.stderr, result
    assert time.monotonic() - begun < 15
    print("PASS a proxy that never reports its port fails the launch")
