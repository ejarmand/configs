"""Run with the installed ai-ipv4.so preloaded and previous preload empty."""
import errno
import os
import socket
import subprocess
import sys

assert not os.environ.get("LD_PRELOAD"), "preload must not reach child tools"
addresses = socket.getaddrinfo("api.anthropic.com", 443, type=socket.SOCK_STREAM)
assert addresses and {a[0] for a in addresses} == {socket.AF_INET}, addresses
print("PASS API DNS returns IPv4 only")

with socket.socket(socket.AF_INET6, socket.SOCK_STREAM) as connection:
    try:
        connection.connect(("2001:db8::1", 443))
    except OSError as error:
        assert error.errno == errno.ENETUNREACH, error
    else:
        raise AssertionError("external IPv6 unexpectedly connected")
print("PASS explicit external IPv6 connection rejected")

with socket.socket(socket.AF_INET6, socket.SOCK_STREAM) as server:
    server.bind(("::1", 0))
    server.listen(1)
    with socket.socket(socket.AF_INET6, socket.SOCK_STREAM) as client:
        client.connect(server.getsockname())
        peer, _ = server.accept()
        peer.close()
print("PASS local IPv6 loopback preserved")

subprocess.run(
    [sys.executable, "-c", "import os; assert not os.environ.get('LD_PRELOAD')"],
    check=True,
)
print("PASS child tools do not inherit the preload")
