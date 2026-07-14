#!/usr/bin/env python3
"""Self-test for a running sixrelay instance.

Starts a local source-observer echo server and drives traffic THROUGH the relay
to verify: auth, egress source in-subnet & unassigned, session stability,
per-connection rotation, concurrent uniqueness, and (unless disabled) real
external egress. Exit 0 only if every enabled gate passes.

Env:
  RELAY_HOST (required)  RELAY_PORT (required)
  SIXRELAY_USER / SIXRELAY_PASS (required)
  SIXRELAY_SUBNET (required, e.g. 2a06:9801:6::/64)
  ECHO_ADDR (required) - a local in-subnet address the relay can reach (usually
                         the host's primary global IPv6)
  ECHO_PORT (default 45678)
  EXTERNAL  (default 1) - set 0 to skip the real external-egress gate
  EXTERNAL_HOST/PORT (default 2001:4860:4860::8888 / 53)
  IFACE (default: auto) - used only for the 'unassigned' check
"""
import asyncio
import ipaddress
import os
import struct
import subprocess
import sys

RELAY_HOST = os.environ["RELAY_HOST"]
RELAY_PORT = int(os.environ["RELAY_PORT"])
USER = os.environ["SIXRELAY_USER"].encode()
PASS = os.environ["SIXRELAY_PASS"].encode()
SUBNET = ipaddress.IPv6Network(os.environ["SIXRELAY_SUBNET"])
ECHO_ADDR = os.environ["ECHO_ADDR"]
ECHO_PORT = int(os.environ.get("ECHO_PORT", "45678"))
EXTERNAL = os.environ.get("EXTERNAL", "1") == "1"
EXT_HOST = os.environ.get("EXTERNAL_HOST", "2001:4860:4860::8888")
EXT_PORT = int(os.environ.get("EXTERNAL_PORT", "53"))

results = []


def record(gate, ok, detail=""):
    results.append((gate, ok))
    print(f"  {'PASS' if ok else 'FAIL'}  {gate}: {detail}")


async def echo_handler(r, w):
    peer = w.get_extra_info("peername")
    ip = peer[0] if peer else "?"
    try:
        while True:
            line = await r.readline()
            if not line:
                break
            w.write(ip.encode() + b"\n")
            await w.drain()
    except OSError:
        pass
    finally:
        try:
            w.close()
        except OSError:
            pass


async def socks_open(target_host, target_port, user=USER, pw=PASS, expect_auth_ok=True):
    r, w = await asyncio.open_connection(RELAY_HOST, RELAY_PORT)
    w.write(b"\x05\x01\x02")
    await w.drain()
    if await r.readexactly(2) != b"\x05\x02":
        raise RuntimeError("no user/pass method")
    w.write(b"\x01" + bytes([len(user)]) + user + bytes([len(pw)]) + pw)
    await w.drain()
    auth = await r.readexactly(2)
    if auth != b"\x01\x00":
        if expect_auth_ok:
            raise PermissionError(repr(auth))
        return None, None, auth
    try:
        ip = ipaddress.ip_address(target_host)
    except ValueError:
        ip = None
    if isinstance(ip, ipaddress.IPv6Address):
        addr = b"\x04" + ip.packed
    elif isinstance(ip, ipaddress.IPv4Address):
        addr = b"\x01" + ip.packed
    else:
        hb = target_host.encode()
        addr = b"\x03" + bytes([len(hb)]) + hb
    w.write(b"\x05\x01\x00" + addr + struct.pack("!H", target_port))
    await w.drain()
    rep = await r.readexactly(4)
    if rep[1] != 0x00:
        raise ConnectionError(f"REP={rep[1]:#x}")
    bnd = rep[3]
    if bnd == 0x01:
        await r.readexactly(4)
    elif bnd == 0x04:
        await r.readexactly(16)
    elif bnd == 0x03:
        (l,) = await r.readexactly(1)
        await r.readexactly(l)
    await r.readexactly(2)
    return r, w, b"\x01\x00"


async def observed_source():
    r, w, _ = await socks_open(ECHO_ADDR, ECHO_PORT)
    w.write(b"x\n")
    await w.drain()
    line = await asyncio.wait_for(r.readline(), 10)
    w.close()
    return line.decode().strip()


def assigned_on_iface(addr):
    out = subprocess.run(["ip", "-6", "addr", "show"], capture_output=True, text=True).stdout
    want = str(ipaddress.IPv6Address(addr))
    for line in out.splitlines():
        line = line.strip()
        if line.startswith("inet6 "):
            a = line.split()[1].split("/")[0]
            try:
                if ipaddress.IPv6Address(a) == ipaddress.IPv6Address(want):
                    return True
            except ValueError:
                pass
    return False


def dns_query(name="dns.google"):
    q = b"\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00"
    for label in name.split("."):
        q += bytes([len(label)]) + label.encode()
    return q + b"\x00\x00\x01\x00\x01"


async def g_auth():
    try:
        _, w, _ = await socks_open(ECHO_ADDR, ECHO_PORT)
        w.close()
        good = True
    except Exception:
        good = False
    try:
        _, _, auth = await socks_open(ECHO_ADDR, ECHO_PORT, user=b"bad", pw=b"bad", expect_auth_ok=False)
        bad = auth == b"\x01\x01"
    except Exception:
        bad = False
    record("auth", good and bad, f"good-accept={good} bad-reject={bad}")


async def g_source():
    s = await observed_source()
    ok = ipaddress.IPv6Address(s) in SUBNET and not assigned_on_iface(s)
    record("egress-source", ok, f"src={s}")


async def g_session():
    r, w, _ = await socks_open(ECHO_ADDR, ECHO_PORT)
    w.write(b"a\n"); await w.drain()
    s1 = (await asyncio.wait_for(r.readline(), 10)).decode().strip()
    w.write(b"b\n"); await w.drain()
    s2 = (await asyncio.wait_for(r.readline(), 10)).decode().strip()
    w.close()
    record("session-stable", bool(s1) and s1 == s2, f"{s1} == {s2}")


async def g_rotation():
    srcs = [await observed_source() for _ in range(10)]
    record("rotation", len(set(srcs)) == 10, f"{len(set(srcs))}/10 distinct")


async def g_concurrency():
    srcs = await asyncio.gather(*[observed_source() for _ in range(20)], return_exceptions=True)
    good = [s for s in srcs if isinstance(s, str) and s]
    record("concurrency-unique", len(good) == 20 and len(set(good)) == 20,
           f"{len(good)}/20 ok, {len(set(good))} distinct")


async def g_external():
    try:
        r, w, _ = await socks_open(EXT_HOST, EXT_PORT)
        q = dns_query()
        w.write(struct.pack("!H", len(q)) + q); await w.drain()
        (rlen,) = struct.unpack("!H", await asyncio.wait_for(r.readexactly(2), 12))
        resp = await asyncio.wait_for(r.readexactly(rlen), 12)
        w.close()
        anc = struct.unpack("!H", resp[6:8])[0]
        record("external-egress", resp[:2] == b"\x12\x34" and anc >= 1, f"DNS via relay, ancount={anc}")
    except Exception as e:
        record("external-egress", False, f"{type(e).__name__}: {e}")


async def wait_ready():
    for _ in range(100):
        try:
            _, w = await asyncio.open_connection(RELAY_HOST, RELAY_PORT)
            w.close()
            return True
        except OSError:
            await asyncio.sleep(0.1)
    return False


async def main():
    if not await wait_ready():
        print("FAIL: relay never became ready")
        sys.exit(2)
    server = await asyncio.start_server(echo_handler, "::", ECHO_PORT)
    print(f"selftest: relay {RELAY_HOST}:{RELAY_PORT}, echo [::]:{ECHO_PORT} -> {ECHO_ADDR}")
    gates = [g_auth, g_source, g_session, g_rotation, g_concurrency]
    if EXTERNAL:
        gates.append(g_external)
    async with server:
        for g in gates:
            try:
                await g()
            except Exception as e:
                record(g.__name__, False, f"EXC {type(e).__name__}: {e}")
    passed = sum(1 for _, ok in results if ok)
    print(f"\n{passed}/{len(results)} gates passed")
    sys.exit(0 if passed == len(results) else 1)


if __name__ == "__main__":
    asyncio.run(main())
