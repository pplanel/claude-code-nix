# One line per way out: "<name>\t<PASS|BLOCK>\t<error>". PASS means it worked.
# tests/run.sh runs this outside the sandbox (what's reachable here) and
# inside (what the profile lets through), and compares.
# Usage: net-probe.py <proxy port> <gateway> <tailscale peer or -> <unix socket>...
import socket, sys

proxy_port, gateway, peer = int(sys.argv[1]), sys.argv[2], sys.argv[3]
sockets = sys.argv[4:]

def tcp(host, port, family=socket.AF_INET):
    s = socket.socket(family, socket.SOCK_STREAM); s.settimeout(3)
    s.connect((host, port)); s.close()

def udp(host, port, family=socket.AF_INET):
    s = socket.socket(family, socket.SOCK_DGRAM); s.settimeout(3)
    s.sendto(b"probe", (host, port)); s.close()

def unix(path):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.settimeout(3)
    s.connect(path); s.close()

def listen(port):
    s = socket.socket(); s.bind(("127.0.0.1", port)); s.listen(1); s.close()

cases = [
    ("proxy 127.0.0.1:%d" % proxy_port, lambda: tcp("127.0.0.1", proxy_port)),
    ("another localhost TCP port", lambda: tcp("127.0.0.1", proxy_port + 1)),
    ("localhost UDP 127.0.0.1:53", lambda: udp("127.0.0.1", 53)),
    ("listen on 127.0.0.1", lambda: listen(proxy_port + 2)),
    ("LAN gateway %s:80" % gateway, lambda: tcp(gateway, 80)),
    ("internet TCP 1.1.1.1:443", lambda: tcp("1.1.1.1", 443)),
    ("internet UDP 1.1.1.1:53", lambda: udp("1.1.1.1", 53)),
    ("DNS lookup", lambda: socket.getaddrinfo("example.com", 443)),
    ("mDNS multicast 224.0.0.251:5353", lambda: udp("224.0.0.251", 5353)),
    ("AWDL multicast ff02::1%awdl0", lambda: udp("ff02::1%awdl0", 5353, socket.AF_INET6)),
]
if peer != "-":
    cases.append(("tailscale peer %s:22" % peer, lambda: tcp(peer, 22)))
for path in sockets:
    cases.append(("unix " + path, lambda p=path: unix(p)))

for name, fn in cases:
    try:
        fn()
        print(f"{name}\tPASS\t")
    except Exception as e:
        print(f"{name}\tBLOCK\t{type(e).__name__}: {e}"[:120])
