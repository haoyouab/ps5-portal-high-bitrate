"""Send corrective ARP replies telling the Portal that the PS5 IP is at the PS5's real MAC.

Use only while no relay is running (for example after a power loss or forced kill).
Replies are spaced 1.5 s apart because Linux clients ignore ARP updates within ~1 s (locktime).
"""
import json
import socket
import struct
import time

CONFIG = '/etc/portal-relay-pi4/config.json'


def mac(value):
    return bytes.fromhex(value.replace(':', ''))


def main():
    cfg = json.load(open(CONFIG))
    own = mac(open('/sys/class/net/eth0/address').read().strip())
    portal, ps5 = mac(cfg['portal_mac']), mac(cfg['ps5_mac'])
    frame = portal + own + struct.pack('!H', 0x0806) + struct.pack(
        '!HHBBH6s4s6s4s', 1, 0x0800, 6, 4, 2,
        ps5, socket.inet_aton(cfg['network']['ps5_ip']),
        portal, socket.inet_aton(cfg['network']['portal_ip']),
    )
    sock = socket.socket(socket.AF_PACKET, socket.SOCK_RAW)
    sock.bind(('eth0', 0))
    for _ in range(6):
        sock.send(frame)
        time.sleep(1.5)
    print('Sent 6 corrective ARP replies to the Portal.')


if __name__ == '__main__':
    main()
