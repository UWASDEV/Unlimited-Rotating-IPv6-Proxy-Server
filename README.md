# Unlimited Rotating IPv6 Proxy Server

Turn a single VPS with a routed IPv6 **/64** into a **session-based rotating IPv6 SOCKS5 proxy** — with one command.

Every new connection egresses from a **random** IPv6 out of the whole `/64` (18 quintillion addresses), that address stays fixed **for the lifetime of the TCP session**, and **concurrent connections always get distinct addresses**. No addresses are pre-assigned to the interface, so there is nothing to "expire", flush, or churn.

```
client ──IPv4/SOCKS5+auth──▶ sixrelay ──IPv6──▶ target
                              per connection: bind a random unused /64 address
                              (held for the session, released on close)
```

## Why this instead of the classic 3proxy setup?

The usual `ipv6-proxy-server` approach assigns thousands of individual `/128` addresses to the NIC and maps one port to each. Those addresses are not owned by the network configuration, so the network manager keeps flushing them and they "die". This project takes the opposite approach:

| | Classic (per-address) | This project (routed) |
|---|---|---|
| Addresses on the NIC | thousands of `/128` | **none** (just your primary) |
| Rotation | one fixed IP per port | **random per connection**, session-stable |
| Concurrency | one IP per port | **every concurrent connection a distinct IP** |
| Pool size | however many you pre-created | the **entire /64** |
| Stability | addresses get flushed / "die" | nothing to flush |

It works by binding otherwise-unassigned addresses (`net.ipv6.ip_nonlocal_bind`), making the whole subnet locally deliverable (`ip -6 route replace local <subnet>`), and answering neighbor discovery for the subnet with `ndppd`.

## Requirements

- Ubuntu **22.04** or **24.04** (fresh install is fine).
- A **routed or on-link IPv6 `/64`** reachable on the server (most IPv6-enabled VPS providers give you one).
- Root access.

> **Note on subnet detection:** the installer derives the subnet from the interface's primary address. Some providers assign a **`/128`** and route a separate **`/64`** that is not visible in `ip addr`. If auto-detection can't find a rotatable subnet, pass it explicitly with `--subnet <your::/64>`.

## Install

```bash
git clone https://github.com/<you>/unlimited-rotating-ipv6-proxy
cd unlimited-rotating-ipv6-proxy
sudo bash install.sh
```

The installer auto-detects your interface, subnet, gateway and public IPv4 (see the subnet note above), installs dependencies, sets everything up as systemd services, and runs a self-test. It prints your endpoint and credentials at the end. Re-running it keeps your existing credentials unless you pass `--user`/`--pass`.

Non-interactive / custom:

```bash
sudo bash install.sh --yes \
  --port 1080 --user myuser --pass mysecret \
  --subnet 2a06:9801:6::/64
```

| Option | Meaning |
|---|---|
| `--subnet CIDR` | subnet to rotate within (default: derived from the primary address) |
| `--iface NAME` | interface (default: the IPv6 default-route interface) |
| `--listen ADDR` | listen address (default: primary public IPv4, else `0.0.0.0`) |
| `--port N` | listen port (default: `1080`) |
| `--user` / `--pass` | SOCKS5 credentials (default: randomly generated) |
| `--reserved LIST` | extra comma-separated addresses to never hand out (bare numbers are decimal host parts; use full addresses or `0x…`) |
| `--no-test` | skip the post-install self-test |
| `--yes` | accept detected values, non-interactive |
| `--uninstall` | remove everything the installer created |

## Usage

Point any SOCKS5 client at the endpoint. Each connection gets its own IPv6:

```bash
# each request → a different source IPv6
curl -x socks5h://user:pass@SERVER_IP:1080 -6 https://ifconfig.co
curl -x socks5h://user:pass@SERVER_IP:1080 -6 https://ifconfig.co

# 20 concurrent requests → 20 distinct source IPv6 addresses
seq 20 | xargs -P20 -I_ curl -s -x socks5h://user:pass@SERVER_IP:1080 -6 https://ifconfig.co
```

- Protocol: **SOCKS5** (TCP `CONNECT`), username/password auth.
- Egress is **IPv6-only** (targets must have an AAAA record). IPv4-only targets are not reachable.

## How it works

- **sixrelay** (`/opt/sixrelay/sixrelay.py`): an asyncio SOCKS5 server. For each connection it draws a random, currently-unused host part of the subnet, binds the upstream socket to that address, and relays. An in-use set guarantees uniqueness across concurrent sessions; the address is released on close.
- **sixrelay-net** (`/opt/sixrelay/sixrelay-net.sh`): a tiny loop that (re-)asserts the sysctls, the `local <subnet>` route, and ndppd — so the setup survives network reconfigurations and reboots.
- **ndppd**: answers IPv6 neighbor discovery for the whole subnet. This is only needed for **on-link** subnets (where the gateway ARPs/NDPs for each address); if your provider **routes** the `/64` to your host, ndppd is not required and the installer continues even if it can't be installed. The self-test's external-egress check tells you whether return traffic actually works.
- Configuration lives in `/etc/sixrelay/sixrelay.env`; both services read it. Edit and `systemctl restart sixrelay`.

## Management

```bash
systemctl status sixrelay          # relay
systemctl status sixrelay-net      # network prerequisites
journalctl -u sixrelay -f          # live logs
python3 /opt/sixrelay/test/selftest.py   # re-run gates (needs env, see install output)
```

## Security notes

- Authentication is **mandatory**; there is no anonymous mode.
- An authenticated client can reach any IPv6 the host can, including provider-internal ranges. Keep the credentials private, and firewall the listen port to trusted clients if needed.
- The listener binds your public IP; restrict with `--listen` or a firewall as appropriate.

## Uninstall

```bash
sudo bash install.sh --uninstall
```

Removes the services, files, routes and sysctl drop-in. The `ndppd` package is left installed; runtime sysctls clear on reboot.

## License

MIT — see [LICENSE](LICENSE).
