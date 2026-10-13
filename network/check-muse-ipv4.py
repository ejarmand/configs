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


def echo_server(family, host):
    """Listen on HOST; echo each connection and record its peer address."""
    server = socket.socket(family, socket.SOCK_STREAM)
    server.bind((host, 0))
    server.listen()
    peers = []

    def serve():
        while True:
            try:
                connection, peer = server.accept()
            except OSError:
                return
            peers.append(peer)
            with connection:
                while data := connection.recv(65536):
                    connection.sendall(data)

    threading.Thread(target=serve, daemon=True).start()
    return server, peers


def connect(port, target, payload=b"ping"):
    """Send a request through the proxy; return its status line and the echo."""
    with socket.create_connection(("127.0.0.1", port), timeout=10) as client:
        client.sendall(target)
        reply = b""
        while b"\r\n\r\n" not in reply:
            chunk = client.recv(65536)
            if not chunk:
                break
            reply += chunk
        head, _, echoed = reply.partition(b"\r\n\r\n")
        status = head.split(b"\r\n")[0].decode()
        if not status.startswith("HTTP/1.1 200"):
            return status, None
        client.sendall(payload)
        client.shutdown(socket.SHUT_WR)
        while chunk := client.recv(65536):
            echoed += chunk
        return status, echoed


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
proxy = subprocess.Popen([sys.executable, "-I", str(PROXY)], stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE)
port = int(proxy.stdout.readline())
ipv4, ipv4_peers = echo_server(socket.AF_INET, "127.0.0.1")
v4 = ipv4.getsockname()[1]
status, echoed = connect(port, f"CONNECT localhost:{v4} HTTP/1.1\r\nHost: localhost:{v4}\r\n\r\n".encode())
assert status == "HTTP/1.1 200 Connection established" and echoed == b"ping", (status, echoed)
assert ipv4_peers and ipv4_peers[-1][0] == "127.0.0.1", ipv4_peers
print("PASS CONNECT tunnels both directions over IPv4")

ipv6, ipv6_peers = echo_server(socket.AF_INET6, "::1")
v6 = ipv6.getsockname()[1]
# Hold the IPv4 side of the port without listening, so only IPv6 would answer.
with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as reserved:
    reserved.bind(("127.0.0.1", v6))
    for target in (f"localhost:{v6}", f"[::1]:{v6}"):
        status, _ = connect(port, f"CONNECT {target} HTTP/1.1\r\n\r\n".encode())
        assert status == "HTTP/1.1 502 Bad Gateway", (target, status)
assert not ipv6_peers, ipv6_peers
print("PASS IPv6-only upstreams get 502, never an IPv6 connection")

status, _ = connect(port, b"GET http://localhost/ HTTP/1.1\r\nHost: localhost\r\n\r\n")
assert status == "HTTP/1.1 405 Method Not Allowed", status
status, _ = connect(port, b"nonsense\r\n\r\n")
assert status == "HTTP/1.1 400 Bad Request", status
print("PASS non-CONNECT requests rejected")

# An open tunnel doesn't keep the proxy alive once the launcher's pipe closes.
idle = socket.create_connection(("127.0.0.1", port))
idle.sendall(f"CONNECT 127.0.0.1:{v4} HTTP/1.1\r\n\r\n".encode())
assert idle.recv(1024).startswith(b"HTTP/1.1 200")
proxy.stdin.close()
assert proxy.wait(timeout=5) == 0
idle.close()
print("PASS proxy exits when its stdin closes, even with an open tunnel")

# The launcher, installed as install-tools.sh does, against a stub muse.
STUB = f"""#!{sys.executable}
import json, os, signal, socket, sys, time
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

if sys.argv[1] == "report":
    ignored = int(next(l for l in open("/proc/self/status") if l.startswith("SigIgn")).split()[1], 16)
    tty = os.isatty(0)
    record(env={{k: os.environ.get(k) for k in ("HTTPS_PROXY", "https_proxy", "NO_PROXY", "no_proxy",
                                                "HTTP_PROXY", "MUSE_HTTP_PROXY")}},
           args=sys.argv[1:], stdin=None if tty else sys.stdin.read(),
           foreground=tty and os.tcgetpgrp(0) == os.getpgrp(),
           int_quit_ignored=bool(ignored & 0x6), tunnel=through_proxy())
    sys.exit(7)
caught = []
signal.signal(signal.SIGINT, lambda *_: caught.append("INT"))
signal.signal(signal.SIGTERM, lambda *_: caught.append("TERM"))
record(pid=os.getpid())
while not caught:
    time.sleep(0.05)
# Ctrl+C mustn't have stopped the proxy while Muse keeps running.
record(signal=caught[0], tunnel=through_proxy())
sys.exit(3 if caught[0] == "INT" else 0)
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
           "NO_PROXY": "example.com", "HTTP_PROXY": "http://unchanged.invalid:1"}
    installed_proxy = dest / "muse-ipv4-proxy.py"

    def records():
        try:
            return [json.loads(line) for line in out.read_text().splitlines()]
        except FileNotFoundError:
            return []

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
    assert report["env"]["NO_PROXY"] == "example.com,localhost,127.0.0.1,::1", report
    assert report["env"]["no_proxy"] == "example.com,localhost,127.0.0.1,::1", report
    assert report["env"]["HTTP_PROXY"] == "http://unchanged.invalid:1", report
    assert report["env"]["MUSE_HTTP_PROXY"] is None, report
    assert report["args"] == ["report", "argument with spaces"], report
    assert report["stdin"] == "from stdin" and not report["int_quit_ignored"], report
    assert report["tunnel"].startswith("HTTP/1.1 200") and report["tunnel"].endswith("pong"), report
    assert wait_until(lambda: not running(installed_proxy))
    print("PASS environment, arguments, stdin and exit status pass through; proxy stopped")

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
    assert wait_until(lambda: records() and "pid" in records()[-1])
    os.write(master, b"\x03")
    assert process.wait(timeout=10) == 3
    os.close(master)
    report = records()[-1]
    assert report["signal"] == "INT" and report["tunnel"].startswith("HTTP/1.1 200"), report
    assert wait_until(lambda: not running(installed_proxy))
    print("PASS Ctrl+C reaches muse; the launcher and proxy keep running until it exits")

    out.unlink()
    process = subprocess.Popen([str(launcher), "wait"], env=env)
    assert wait_until(lambda: records() and "pid" in records()[-1])
    process.send_signal(signal.SIGTERM)
    assert process.wait(timeout=10) == 0
    assert records()[-1]["signal"] == "TERM", records()
    assert wait_until(lambda: not running(installed_proxy))
    print("PASS SIGTERM is forwarded to muse; proxy stopped")

    out.unlink()
    process = subprocess.Popen([str(launcher), "wait"], env=env)
    assert wait_until(lambda: records() and "pid" in records()[-1])
    muse = records()[-1]["pid"]
    assert running(installed_proxy)
    process.kill()
    process.wait()
    assert wait_until(lambda: not running(installed_proxy))
    os.kill(muse, signal.SIGKILL)
    print("PASS proxy exits on its own when the launcher is killed")
