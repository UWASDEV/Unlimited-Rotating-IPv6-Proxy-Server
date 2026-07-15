#!/usr/bin/env python3
"""sixrelay - session-based rotating IPv6 SOCKS5 proxy.

Every accepted client connection is assigned a uniform-random source address
from the configured IPv6 subnet and that address is bound to the upstream
socket. The address is held for the whole lifetime of the TCP session and
released on close. An in-use set guarantees that no two *concurrent*
connections ever share a source address, so simultaneous connections always
egress from distinct IPv6 addresses.

Egress is IPv6-only by design. Two modes (SIXRELAY_MODE):
  routed  - bind an otherwise-unassigned address; relies on
            net.ipv6.ip_nonlocal_bind=1 + a `local <subnet>` route + ndppd, so
            the provider must route the whole subnet to this host.
  address - assign the address to the interface (nodad) for the connection's
            lifetime and remove it on close; needed on on-link providers that
            only accept source addresses that are configured on the interface.

All configuration comes from the environment (see /etc/sixrelay/sixrelay.env).
"""
import asyncio
import hmac
import ipaddress
import logging
import os
import re
import secrets
import signal
import socket
import struct
import subprocess
import sys


def _require(name):
    v = os.environ.get(name)
    if not v:
        sys.stderr.write(f"sixrelay: required env {name} is not set\n")
        raise SystemExit(2)
    return v


LISTEN_HOST = os.environ.get("SIXRELAY_LISTEN_HOST", "0.0.0.0")
LISTEN_PORT = int(os.environ.get("SIXRELAY_LISTEN_PORT", "1080"))
SUBNET = ipaddress.IPv6Network(_require("SIXRELAY_SUBNET"), strict=False)
PROXY_USER = _require("SIXRELAY_USER").encode()
PROXY_PASS = _require("SIXRELAY_PASS").encode()
CONNECT_TIMEOUT = float(os.environ.get("SIXRELAY_CONNECT_TIMEOUT", "15"))
HANDSHAKE_TIMEOUT = float(os.environ.get("SIXRELAY_HANDSHAKE_TIMEOUT", "10"))
IDLE_TIMEOUT = float(os.environ.get("SIXRELAY_IDLE_TIMEOUT", "300"))
MAX_SESSIONS = int(os.environ.get("SIXRELAY_MAX_SESSIONS", "2000"))
# routed  = bind an otherwise-unassigned address (provider routes the whole /64)
# address = assign the address to the interface for the connection's lifetime
#           (needed on on-link providers that only accept assigned sources)
MODE = os.environ.get("SIXRELAY_MODE", "routed").strip().lower()
IFACE = os.environ.get("SIXRELAY_IFACE", "").strip()
BUF = 65536

IPV6_FREEBIND = getattr(socket, "IPV6_FREEBIND", 78)

_PREFIX_INT = int(SUBNET.network_address)
_HOST_BITS = 128 - SUBNET.prefixlen
_HOSTMASK = (1 << _HOST_BITS) - 1 if _HOST_BITS else 0
_PLEN = SUBNET.prefixlen


def _parse_reserved(spec):
    """Host parts never handed out. Accepts comma-separated host-part ints
    (decimal or 0x..) and/or full IPv6 addresses (reduced to their host part)."""
    out = {0, 1}  # subnet-router anycast + the conventional ::1 gateway
    for tok in spec.split(","):
        tok = tok.strip()
        if not tok:
            continue
        try:
            out.add(int(tok, 0) & _HOSTMASK)
            continue
        except ValueError:
            pass
        try:
            out.add(int(ipaddress.IPv6Address(tok)) & _HOSTMASK)
        except ValueError:
            logging.getLogger("sixrelay").warning("ignoring bad reserved token %r", tok)
    return out


_RESERVED = _parse_reserved(os.environ.get("SIXRELAY_RESERVED", ""))

log = logging.getLogger("sixrelay")
_inuse = set()
_active = 0  # live sessions; single-threaded event loop => no lock needed


# ---- Source-address pool -----------------------------------------------------
def pick_source():
    """Reserve and return a random, currently-unused host part of the subnet.

    Bounded retry so a saturated/degenerate pool can never spin forever.
    """
    for _ in range(64):
        host = secrets.randbits(_HOST_BITS) if _HOST_BITS else 0
        if host in _RESERVED or host in _inuse:
            continue
        _inuse.add(host)
        return host
    raise RuntimeError("source pool saturated")


def release_source(host):
    _inuse.discard(host)


def host_to_addr(host):
    return str(ipaddress.IPv6Address(_PREFIX_INT | (host & _HOSTMASK)))


# ---- Address mode: assign/unassign the source on the interface --------------
async def _ip_run(*args):
    try:
        proc = await asyncio.create_subprocess_exec(
            "ip", *args,
            stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL,
        )
        return await proc.wait()
    except OSError:
        return -1


async def assign_source(addr):
    # rc 0 = added; 2 = already present (leaked from a prior run, treat as ours)
    rc = await _ip_run("-6", "addr", "add", f"{addr}/{_PLEN}", "dev", IFACE, "nodad")
    return rc in (0, 2)


async def unassign_source(addr):
    await _ip_run("-6", "addr", "del", f"{addr}/{_PLEN}", "dev", IFACE)


def flush_stale_pool():
    """Remove leftover non-reserved in-subnet addresses on the interface (from a
    prior crash) so address-mode starts clean."""
    try:
        out = subprocess.run(
            ["ip", "-6", "addr", "show", "dev", IFACE, "scope", "global"],
            capture_output=True, text=True,
        ).stdout
    except OSError:
        return
    n = 0
    for m in re.finditer(r"inet6 ([0-9A-Fa-f:]+)/\d+", out):
        try:
            a = ipaddress.IPv6Address(m.group(1))
        except ValueError:
            continue
        if a in SUBNET and (int(a) & _HOSTMASK) not in _RESERVED:
            subprocess.run(
                ["ip", "-6", "addr", "del", f"{a}/{_PLEN}", "dev", IFACE],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
            n += 1
    if n:
        log.info("address-mode: flushed %d stale pool address(es)", n)


def _pack_addrport(addr, port):
    """Encode a bound address/port into a SOCKS5 reply body (ATYP+addr+port)."""
    try:
        ip = ipaddress.ip_address(addr)
    except ValueError:
        ip = None
    if isinstance(ip, ipaddress.IPv6Address):
        return b"\x04" + ip.packed + struct.pack("!H", port)
    if isinstance(ip, ipaddress.IPv4Address):
        return b"\x01" + ip.packed + struct.pack("!H", port)
    return b"\x01\x00\x00\x00\x00" + struct.pack("!H", port)


# ---- SOCKS5 -----------------------------------------------------------------
async def socks5_handshake(reader, writer):
    """Method negotiation + username/password auth (RFC 1928 / RFC 1929)."""
    ver, nmethods = await reader.readexactly(2)
    if ver != 0x05:
        return False
    methods = await reader.readexactly(nmethods)
    if 0x02 not in methods:  # require username/password
        writer.write(b"\x05\xff")
        await writer.drain()
        return False
    writer.write(b"\x05\x02")
    await writer.drain()

    (auth_ver,) = await reader.readexactly(1)
    if auth_ver != 0x01:
        return False
    (ulen,) = await reader.readexactly(1)
    username = await reader.readexactly(ulen)
    (plen,) = await reader.readexactly(1)
    password = await reader.readexactly(plen)
    ok = hmac.compare_digest(username, PROXY_USER)
    ok = hmac.compare_digest(password, PROXY_PASS) and ok
    if not ok:
        writer.write(b"\x01\x01")
        await writer.drain()
        return False
    writer.write(b"\x01\x00")
    await writer.drain()
    return True


async def socks5_read_request(reader):
    """Return (host, port) for a CONNECT, or raise ValueError(<int reply code>)."""
    ver, cmd, _rsv, atyp = await reader.readexactly(4)
    if ver != 0x05:
        raise ValueError(0x01)
    if cmd != 0x01:                     # only CONNECT (TCP) is supported
        raise ValueError(0x07)
    if atyp == 0x01:                    # IPv4 literal: no IPv6 egress path
        await reader.readexactly(4)
        await reader.readexactly(2)
        raise ValueError(0x08)
    if atyp == 0x03:                    # domain
        (dlen,) = await reader.readexactly(1)
        raw = await reader.readexactly(dlen)
        try:
            host = raw.decode("ascii")
        except UnicodeError:
            raise ValueError(0x08)
    elif atyp == 0x04:                  # IPv6 literal
        host = str(ipaddress.IPv6Address(await reader.readexactly(16)))
    else:
        raise ValueError(0x08)
    (port,) = struct.unpack("!H", await reader.readexactly(2))
    return host, port


async def open_upstream(loop, host, port, source_host):
    """Resolve AAAA, bind the chosen subnet source, connect. Returns a connected
    AF_INET6 socket. Raises OSError / asyncio.TimeoutError on failure."""
    infos = await loop.getaddrinfo(
        host, port, family=socket.AF_INET6, type=socket.SOCK_STREAM
    )
    if not infos:
        raise OSError("no AAAA")
    src = host_to_addr(source_host)
    last = None
    for family, socktype, proto, _canon, sa in infos:
        sock = socket.socket(family, socktype, proto)
        try:
            sock.setblocking(False)
            try:
                sock.setsockopt(socket.IPPROTO_IPV6, IPV6_FREEBIND, 1)
            except OSError:
                pass  # global net.ipv6.ip_nonlocal_bind=1 already permits it
            sock.bind((src, 0))
            await asyncio.wait_for(loop.sock_connect(sock, sa), CONNECT_TIMEOUT)
            return sock
        except (OSError, asyncio.TimeoutError) as exc:
            last = exc
            sock.close()
    raise last if last else OSError("connect failed")


async def pipe(reader, writer):
    try:
        while True:
            data = await asyncio.wait_for(reader.read(BUF), IDLE_TIMEOUT)
            if not data:
                break
            writer.write(data)
            await writer.drain()
    except (OSError, asyncio.TimeoutError, asyncio.IncompleteReadError):
        pass
    finally:
        try:
            writer.write_eof()
        except (OSError, RuntimeError):
            pass


async def handle_client(reader, writer):
    global _active
    peer = writer.get_extra_info("peername")
    source_host = None
    src_addr = None
    assigned = False
    sock = None
    up_writer = None
    if _active >= MAX_SESSIONS:
        try:
            writer.close()
        except OSError:
            pass
        return
    _active += 1
    try:
        ok = await asyncio.wait_for(socks5_handshake(reader, writer), HANDSHAKE_TIMEOUT)
        if not ok:
            return
        try:
            host, port = await asyncio.wait_for(
                socks5_read_request(reader), HANDSHAKE_TIMEOUT
            )
        except ValueError as ve:
            code = ve.args[0] if ve.args and isinstance(ve.args[0], int) else 0x01
            writer.write(b"\x05" + bytes([code]) + b"\x00\x01\x00\x00\x00\x00\x00\x00")
            await writer.drain()
            return

        try:
            source_host = pick_source()
        except RuntimeError:
            writer.write(b"\x05\x01\x00\x01\x00\x00\x00\x00\x00\x00")
            await writer.drain()
            return
        src_addr = host_to_addr(source_host)
        if MODE == "address":
            assigned = await assign_source(src_addr)
            if not assigned:
                # On an on-link provider an unassigned source cannot egress;
                # fail fast rather than attempt a doomed upstream connect.
                log.warning("address-mode: could not assign %s on %s", src_addr, IFACE)
                writer.write(b"\x05\x01\x00\x01\x00\x00\x00\x00\x00\x00")
                await writer.drain()
                return

        try:
            sock = await open_upstream(
                asyncio.get_running_loop(), host, port, source_host
            )
        except (OSError, asyncio.TimeoutError) as exc:
            log.info("connect fail %s:%s via %s: %s", host, port,
                     host_to_addr(source_host), exc)
            writer.write(b"\x05\x04\x00\x01\x00\x00\x00\x00\x00\x00")
            await writer.drain()
            return

        bound = sock.getsockname()
        up_reader, up_writer = await asyncio.open_connection(sock=sock)
        sock = None  # ownership transferred to the transport
        writer.write(b"\x05\x00\x00" + _pack_addrport(bound[0], bound[1]))
        await writer.drain()

        await asyncio.gather(pipe(reader, up_writer), pipe(up_reader, writer))
    except (OSError, asyncio.TimeoutError, asyncio.IncompleteReadError):
        pass
    except Exception:
        log.exception("unexpected error handling %s", peer)
    finally:
        if up_writer is not None:
            try:
                up_writer.close()
            except OSError:
                pass
        if sock is not None:
            try:
                sock.close()
            except OSError:
                pass
        try:
            writer.close()
        except OSError:
            pass
        if assigned and src_addr is not None:
            try:
                await unassign_source(src_addr)
            except OSError:
                pass
        if source_host is not None:
            release_source(source_host)
        _active -= 1


async def main():
    logging.basicConfig(
        level=os.environ.get("SIXRELAY_LOGLEVEL", "INFO"),
        format="%(asctime)s %(levelname)s %(message)s",
    )
    if MODE not in ("routed", "address"):
        sys.stderr.write(f"sixrelay: invalid SIXRELAY_MODE={MODE!r} (routed|address)\n")
        raise SystemExit(2)
    if MODE == "address":
        if not IFACE:
            sys.stderr.write("sixrelay: address mode requires SIXRELAY_IFACE\n")
            raise SystemExit(2)
        flush_stale_pool()  # clear any addresses leaked by a prior crash
    server = await asyncio.start_server(
        handle_client, LISTEN_HOST, LISTEN_PORT, reuse_address=True
    )
    log.info(
        "sixrelay listening on %s:%s, egress %s mode=%s (%d reserved), session-rotating unique-per-conn",
        LISTEN_HOST, LISTEN_PORT, SUBNET, MODE, len(_RESERVED),
    )
    loop = asyncio.get_running_loop()
    stop = loop.create_future()

    def _request_stop():
        if not stop.done():
            stop.set_result(None)

    for sig in (signal.SIGTERM, signal.SIGINT):
        try:
            loop.add_signal_handler(sig, _request_stop)
        except (NotImplementedError, RuntimeError):
            pass  # e.g. not the main thread / unsupported platform

    try:
        await stop
    finally:
        # Stop accepting, then clean up immediately. We deliberately do NOT
        # `await server.wait_closed()`: on Python 3.12+ it blocks until every
        # in-flight proxied connection ends, which would stall systemd's stop
        # timeout and end in SIGKILL -- skipping the flush below and leaking
        # addresses. Closing the listener and flushing now gives a prompt, clean
        # shutdown.
        server.close()
        # Cancel in-flight handlers and let them unwind so none is mid-assignment
        # when we flush, then remove any pool addresses still on the interface so
        # a stop/restart/uninstall leaves it clean (address mode only). The
        # startup flush backstops the sub-millisecond orphaned-`ip add` window.
        handlers = [t for t in asyncio.all_tasks() if t is not asyncio.current_task()]
        for t in handlers:
            t.cancel()
        if handlers:
            await asyncio.gather(*handlers, return_exceptions=True)
        if MODE == "address":
            flush_stale_pool()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
