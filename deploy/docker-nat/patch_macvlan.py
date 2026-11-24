"""Local patch: let linux_native.py accept a Docker macvlan eth0 when PORTAL_ALLOW_MACVLAN=1.

Upstream rejects any virtual link (macvlan reports iflink != ifindex and info_kind=macvlan).
A macvlan child has its own MAC on the parent L2 LAN, which is what the relay needs.
"""
import sys
from pathlib import Path

p = Path(sys.argv[1])
src = p.read_text()
edits = [
    (
        "    if not is_veth_sysfs and (iface_dir / 'ifindex').exists() and (iface_dir / 'iflink').exists():",
        "    if not is_veth_sysfs and os.environ.get('PORTAL_ALLOW_MACVLAN') != '1' and (iface_dir / 'ifindex').exists() and (iface_dir / 'iflink').exists():",
    ),
    (
        "    elif info_kind:\n",
        "    elif info_kind == 'macvlan' and os.environ.get('PORTAL_ALLOW_MACVLAN') == '1':\n        pass\n    elif info_kind:\n",
    ),
]
for old, new in edits:
    assert src.count(old) == 1, f'patch anchor not found exactly once: {old!r}'
    src = src.replace(old, new)

# macvlan TX queue can momentarily fill (EAGAIN) on the non-blocking AF_PACKET TX socket;
# upstream lets that exception kill the relay. Wait for writability and retry instead.
tx_head, sep, tx_tail = src.partition('class LinuxTxSocket')
assert sep, 'LinuxTxSocket not found'
old_send = "    def send(self, frame):\n        return self.sock.send(bytes(frame))\n"
assert tx_tail.count(old_send) >= 1, 'LinuxTxSocket.send anchor not found'
new_send = """    def send(self, frame):
        raw = bytes(frame)
        deadline = time.monotonic() + 0.5
        while True:
            try:
                return self.sock.send(raw)
            except BlockingIOError:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise
                select.select([], [self.sock], [], min(remaining, 0.02))
"""
tx_tail = tx_tail.replace(old_send, new_send, 1)
old_nb = "            self.sock.bind((interface, 0))\n            self.sock.setblocking(False)\n"
assert tx_tail.count(old_nb) >= 1, 'LinuxTxSocket setblocking anchor not found'
tx_tail = tx_tail.replace(old_nb, "            self.sock.bind((interface, 0))\n            try:\n                self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 4 * 1024 * 1024)\n            except OSError:\n                pass\n            self.sock.setblocking(False)\n", 1)
src = tx_head + sep + tx_tail
for mod in ('\nimport select\n', '\nimport time\n', '\nimport socket\n'):
    assert mod in src, mod
assert '\nimport os\n' in src
p.write_text(src)
print('patched', p)
