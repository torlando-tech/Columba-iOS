#!/usr/bin/env python3
"""
Send AutoInterface-shaped test traffic to a Columba iPhone over the
LAN — multicast HELLO discovery beacons (so iOS spawns a peer for
us) plus a unicast announce-shaped UDP packet on the data port.

Used by `run_test.sh` to drive an automated end-to-end check of the
Columba extension's AutoInterface implementation. Run from a Mac
that's on the same Wi-Fi as the iPhone.

Usage:
    python3 send_test_traffic.py --iface en0 \\
        --target-ip fe80::14cb:9def:5400:73b9 \\
        --group-id reticulum \\
        [--data-port 42671] [--discovery-port 29716]

Mirrors reticulum-swift's `AutoInterfaceConstants`:
- multicast group: ff12:0:<6 segments derived from SHA256(groupId)>
- discovery token: SHA256(groupId + sourceAddressString)
- discovery port: 29716, data port: 42671
"""

import argparse
import hashlib
import os
import socket
import struct
import sys
import time


def derive_multicast_address(group_id: str) -> str:
    """Mirror AutoInterfaceConstants.multicastAddress(for:)."""
    h = hashlib.sha256(group_id.encode("utf-8")).digest()
    # 6 segments from bytes 2..13, little-endian pair
    segments = []
    for i in range(6):
        lo = h[2 + i * 2 + 1]
        hi = h[2 + i * 2] << 8
        segments.append(format(lo + hi, "x"))
    return "ff12:0:" + ":".join(segments)


def derive_discovery_token(group_id: str, address: str) -> bytes:
    """Mirror AutoInterfaceConstants.discoveryToken(groupId:address:)."""
    return hashlib.sha256(group_id.encode("utf-8") + address.encode("utf-8")).digest()


def get_iface_link_local(iface: str) -> str:
    """Pick the first IPv6 link-local address on the given interface."""
    import ipaddress
    import subprocess

    out = subprocess.check_output(["ifconfig", iface]).decode()
    for line in out.splitlines():
        line = line.strip()
        if line.startswith("inet6 fe80"):
            addr = line.split()[1].split("%")[0]
            return addr
    raise RuntimeError(f"no link-local address found on {iface}")


def send_multicast_hello(group_addr: str, port: int, token: bytes,
                        iface_idx: int) -> None:
    """Send a HELLO beacon to the multicast group on the chosen interface."""
    sock = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)
    # Bind multicast send to the chosen interface so iOS sees us
    # arriving on en0 (the Wi-Fi side they're on).
    sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_MULTICAST_IF,
                   struct.pack("I", iface_idx))
    sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_MULTICAST_HOPS, 1)
    addr_info = socket.getaddrinfo(group_addr, port, socket.AF_INET6,
                                    socket.SOCK_DGRAM)[0]
    sockaddr = addr_info[4]
    sock.sendto(token, sockaddr)
    sock.close()


def send_unicast_data(target_ip: str, port: int, payload: bytes,
                      iface: str) -> None:
    """Send a UDP datagram to the iPhone's data port."""
    sock = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)
    # Build sockaddr_in6 with the scope id for the link-local target.
    addr_info = socket.getaddrinfo(f"{target_ip}%{iface}", port,
                                    socket.AF_INET6, socket.SOCK_DGRAM)[0]
    sockaddr = addr_info[4]
    sock.sendto(payload, sockaddr)
    sock.close()


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--iface", default="en0",
                   help="local Wi-Fi interface (default en0)")
    p.add_argument("--target-ip", required=True,
                   help="iPhone's link-local IPv6 (without scope)")
    p.add_argument("--group-id", default="reticulum",
                   help="AutoInterface group id (default 'reticulum')")
    p.add_argument("--discovery-port", type=int, default=29716)
    p.add_argument("--data-port", type=int, default=42671)
    p.add_argument("--n-hellos", type=int, default=3,
                   help="number of HELLO beacons to send")
    p.add_argument("--data-payload-bytes", type=int, default=128,
                   help="size of the unicast test packet")
    args = p.parse_args()

    multicast_addr = derive_multicast_address(args.group_id)
    own_addr = get_iface_link_local(args.iface)
    token = derive_discovery_token(args.group_id, own_addr)
    iface_idx = socket.if_nametoindex(args.iface)

    print(f"local link-local : {own_addr}")
    print(f"multicast group  : {multicast_addr}")
    print(f"discovery token  : {token.hex()}")
    print(f"target           : {args.target_ip}%{args.iface}")
    print()

    for i in range(args.n_hellos):
        send_multicast_hello(multicast_addr, args.discovery_port, token,
                            iface_idx)
        print(f"  HELLO #{i + 1} sent")
        time.sleep(0.5)

    # Distinctive payload — first 4 bytes are an ASCII tag the verifier
    # can grep for in the iOS log if we ever decide to dump received
    # bytes there.
    payload = b"COLB" + os.urandom(args.data_payload_bytes - 4)
    send_unicast_data(args.target_ip, args.data_port, payload, args.iface)
    print(f"  unicast test packet ({len(payload)}B) sent to "
          f"{args.target_ip}%{args.iface}:{args.data_port}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
