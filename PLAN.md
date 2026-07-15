# Plan: one-shot installer for the rotating IPv6 proxy

Goal: a single `sudo bash install.sh` turns a **fresh Ubuntu 22.04/24.04 VPS** that has a routed/on-link IPv6 `/64` into the session-based rotating IPv6 SOCKS5 proxy proven in the previous work — generically (no values hardcoded to any one box), idempotently, with a built-in self-test and a clean uninstall. To be published on GitHub.

## Repo layout
```
unlimited-rotating-ipv6-proxy/
├── install.sh          # detection + packages + files + services + self-test + uninstall
├── sixrelay.py         # the relay (asyncio SOCKS5, fully env-driven)
├── sixrelay-net.sh     # network-prerequisite asserter (loop)
├── test/selftest.py    # gate harness (also run by install.sh)
├── README.md  LICENSE  PLAN.md
```
install.sh copies `sixrelay.py`, `sixrelay-net.sh`, `test/selftest.py` from its own directory (a git checkout), so those files are the single source of truth — no code is duplicated inside the installer.

## What gets installed
- `/opt/sixrelay/{sixrelay.py,sixrelay-net.sh,test/selftest.py}`
- `/etc/sixrelay/sixrelay.env` (0640) — the one config both services read (systemd `EnvironmentFile`), including `SIXRELAY_MODE`.
- `/etc/sysctl.d/99-sixrelay.conf` — **routed mode**: `ip_nonlocal_bind`, forwarding, `proxy_ndp`, `accept_dad=0`, `dad_transmits=0`. **address mode**: only `accept_dad=0`, `dad_transmits=0` (no `ip_nonlocal_bind`/forwarding/`proxy_ndp` — the sources are real, assigned addresses).
- `/etc/ndppd.conf` — **routed mode only**: `static` rule for the detected subnet (previous `/etc/ndppd.conf` backed up to `…​.sixrelay-orig`). Address mode installs no ndppd rule and disables the service.
- `sixrelay-net.service` (loop asserts the mode-appropriate prerequisites — routed: sysctls + `local <subnet>` route + ndppd; address: only DAD suppression) and `sixrelay.service` (the relay). Both enabled → boot-safe.

## Auto-detection (the crux of being generic)
- **python3 first**: python3 is used during detection, so if it is missing it is `apt`-installed before any detection runs.
- **iface**: interface of the IPv6 default route; fallback = first non-lo interface with a global IPv6.
- **primary /prefix**: first global IPv6 on the iface, preferring a **stable** address (skips `temporary`/`deprecated` SLAAC-privacy addresses) → reserved (never handed out).
- **subnet**: the network of the primary address. If that yields a `/128` (or prefix > /120, no room to rotate), fall back to scanning `ip -6 route show dev <iface>` for a routed non-default, non-link-local, non-`/128` prefix. If still none, fail with an explicit `--subnet <your::/64>` hint (covers the "/128 primary + separately-routed /64" provider layout). `--subnet` always wins and is never overridden by the route scan.
- **gateway**: `via` of the IPv6 default route → reserved.
- **mode**: auto-detected by probing egress (see *Egress modes* above); `--mode routed|address` overrides; reused from the env file on re-run.
- **listen**: primary public IPv4, else `0.0.0.0`; overridable.
- **config reuse on re-run**: iface, listen, port, subnet, interval and credentials are all **kept** from the existing `sixrelay.env` unless overridden on the CLI, so a bare re-run never silently changes the port/creds clients depend on; a fresh box gets detected values + random `[A-Za-z0-9]` creds. Credentials are validated against `[A-Za-z0-9._-]` so they are safe in the `EnvironmentFile` and shell.
- Detection functions tolerate a bad `--iface`/missing data (return empty, then the explicit `die` fires) rather than aborting under `set -e`.
- Everything is printed and (unless `--yes`, required for non-tty runs) confirmed before any change.

## Egress modes (routed vs address)
Two provider topologies need different handling, so the relay and installer support two modes and the installer **auto-detects** which one works (override: `--mode`):

- **routed** — the provider statically routes the whole `/64` to the host. Sources are bound *without* being assigned to the interface (`ip_nonlocal_bind` + `IPV6_FREEBIND` + `ip -6 route replace local <subnet>` + `ndppd`). Nothing is added to the NIC; the entire `/64` is the pool. Proven on a real `/64` (box 1: unassigned-source bind → egress → return path all verified).
- **address** — the `/64` is *on-link* (shared L2 segment; the upstream router does NDP per address and only accepts source addresses configured on the interface). Here the relay assigns each source to the interface with `ip -6 addr add <addr>/64 dev <if> nodad`, binds it, and removes it on close. It deliberately does **not** add a `local <subnet>` route or an ndppd static rule — on a shared segment either one would blackhole or hijack traffic for addresses the host does not own. Proven on box 2 (Netvia `2a13:a440:9:bf::/64`): unassigned bind fails, assigned-source egress works immediately (no warm-up).

**Address-mode leak safety (three layers):** each connection removes its address in `finally` on normal close; `flush_stale_pool()` removes any strays on **startup** (crash recovery); a SIGTERM/SIGINT handler flushes again on **graceful shutdown** so `systemctl stop`/uninstall leave the interface clean. `--uninstall` also flushes any non-reserved in-subnet address as a final backstop.

**Mode auto-detection (installer, fresh install only):** apply the routed prerequisites live, let ndppd settle, then probe real egress (`bind` a random unassigned in-subnet source, `connect` to a public DNS resolver on TCP/53) with a tight timeout. Success → **routed**. Failure → withdraw the routed-only bits (the `local` route + ndppd) and probe again with an *assigned* source → **address**. Both fail → default to address with a loud warning (the self-test then shows whether egress works). A re-run reuses `SIXRELAY_MODE` from the env file instead of re-probing, so it never disrupts a working box or flips its mode.

**Known tradeoff (documented, accepted):** the routed probe briefly makes the `local <subnet>` route and an ndppd static rule live on the segment (a few seconds, one time, at install). On a *shared* on-link segment this transiently proxies NDP for the subnet — but that is exactly the case where the routed probe fails, so the bits are withdrawn immediately. Exposure is bounded by a single short-timeout probe rather than a retry loop. This is the price of an empirical (reliable) probe over a routing-table heuristic (which misclassifies box-1-style "on-link but fully-owned /64" providers).

## Design decisions / rationale
- **Two modes, auto-detected** (see above): covers both routed and on-link `/64` providers from one installer, with no user input in the common case.
- **ndppd is routed-mode-only and best-effort**: routed subnets that are on-link to the provider need it; if `apt-get install ndppd` fails (e.g. universe disabled), warn and continue — the self-test then reveals whether egress works, rather than aborting. Address mode never uses ndppd.
- **Idempotent**: re-running overwrites files and restarts services; existing credentials are preserved (see detection) so repeated runs never invalidate issued creds; safe to run repeatedly.
- **dpkg-lock tolerance**: all `apt-get` calls use `-o DPkg::Lock::Timeout=300` — fresh Ubuntu VPSes routinely run `unattended-upgrades`/`apt-daily` right after boot, which would otherwise make the package installs fail spuriously (observed and fixed during Layer-3 testing: `apt-get install` returned exit 100 with the lock held by `unattended-upgr`).
- **Credentials restricted to alnum**: avoids `EnvironmentFile`/shell quoting hazards.
- `sixrelay-net.sh` reads only `SIXRELAY_IFACE`/`SIXRELAY_SUBNET`, from the environment (systemd injects them) or via a narrow `sed` of the env file — it never `source`s the whole file.

## Gates (the installer's self-test must pass all; `test/selftest.py`)
Local source-observer (`srcecho` bound `[::]:45678`) driven **through** the relay, plus a real external gate. Objective, scripted, exit 0 only if all pass:
- **auth**: good creds accepted, wrong creds rejected (`01 01`).
- **egress-source**: observed source ∈ subnet. In **routed** mode it must additionally be **not assigned to any interface**; in **address** mode the source *is* assigned for the session by design, so only the in-subnet invariant applies (the self-test reads `SIXRELAY_MODE`).
- **session-stable**: two round-trips on one connection report the same source.
- **rotation**: 10 sequential connections → 10 distinct sources.
- **concurrency-unique**: 20 simultaneous connections → 20 distinct sources, all succeed.
- **external-egress**: SOCKS5 CONNECT through the relay to `[2001:4860:4860::8888]:53` + DNS round-trip (proves the unassigned-source return path off-box). Skippable with `EXTERNAL=0` for offline boxes.

## From-scratch test methodology (executed AFTER reviewer PASS)
Three layers, each validating a different claim, chosen so that no single layer is asked to prove something it can't:

**Layer 1 — detection parsers against provider fixtures (proves genericity).**
Run the exact `awk`/python detection expressions against captured/synthetic `ip -6 addr`/`ip -6 route` outputs for multiple provider shapes: normal `/64` primary; SLAAC with a `temporary` privacy address; `/128` primary + separately-routed `/64` (route-scan path); `/128` primary with **no** visible `/64` (must fail with the `--subnet` hint); link-local `via` gateway; missing default route; no IPv4. Assert each yields the right iface/subnet/primary or the right failure.

**Layer 2 — packaging on BOTH OSes in fresh containers (proves the apt path on 22.04 and 24.04).**
If Docker/LXD is available: `ubuntu:22.04` and `ubuntu:24.04` containers running `apt-get update && apt-get install -y ndppd python3` to prove the dependencies exist on both releases (the real cross-version risk). Containers lack a routed `/64` and PID-1 systemd, so they validate package availability + file-laydown + `bash -n`/`py_compile`, not service start. To exercise the script body itself on a genuinely fresh OS, also run `bash install.sh --yes --subnet 2001:db8::/64 --no-test` in the container and confirm it gets through python3-ensure + detection + env-file write + file laydown before the expected `systemctl` failure. If no container runtime is available, record that and rely on Layer 3 + documented package availability.

**Layer 3 — full functional install on this real /64 box (proves end-to-end behaviour).**
This box has a genuine routed `/64`, which a container cannot reproduce. Tear down the previous ad-hoc setup to a clean baseline (stop/disable prior `sixrelay.service` + `ipv6-proxy-server-net.service`, remove their units, drop the `local` route + sysctls; interface keeps only primary + link-local; prior-phase backups remain). Then:
1. **Static**: `bash -n`, `python3 -m py_compile`, `shellcheck` if present.
2. **Fresh install**: `sudo bash install.sh --yes --port 30000 --user ahmet --pass 177147at` (explicit values keep the box's existing client working; the bare `sudo bash install.sh` detection path is exercised in Layer 1). Detection output must match reality.
3. **Self-test**: all gates PASS (incl. real external egress).
4. **Idempotency**: re-run; must converge, keep creds, still pass.
5. **Uninstall**: `--uninstall`; services/files/route gone, box at baseline; then re-install so it ends in the working rotating state.

**Address-mode validation.** Routed mode is proven end-to-end on box 1's real routed `/64` (Layer 3). Address mode is proven two ways: (a) on a real on-link provider (box 2, Netvia) where an unassigned-source bind fails but an assigned-source (`ip -6 addr add … nodad`) egresses immediately; and (b) locally against a loopback echo with a ULA on `lo`, driving the full self-test through the relay — all gates pass, and startup/graceful-shutdown flushing leaves zero stray addresses. The mode-detection probe logic (in-subnet random source, assign/bind/connect/unassign) is unit-checked for correctness.

**Honesty note:** Layer 3 is authoritative for behaviour but runs where python3/ndppd already exist; Layer 2 covers the fresh-OS package path; Layer 1 covers the detection genericity that neither of the others exercises. Together they substantiate "works on a fresh Ubuntu 22.04/24.04 VPS" as far as is possible without renting a second VPS per provider.

## Rollback / safety
- Prior-phase backups remain at `/root/proxyserver/backup-*/`.
- `--uninstall` fully reverses the installer; ndppd.conf original is restored from its backup.
- The teardown/reinstall causes a brief proxy interruption on this box (acceptable; ends working), consistent with the user's request to test a from-scratch install.

## Known limitations (documented, non-blocking)
- Egress IPv6-only (IPv4-only targets unreachable — inherent to an IPv6 proxy).
- TCP `CONNECT` only (no UDP ASSOCIATE / BIND).
- Authenticated clients can reach host-internal IPv6 (SSRF-class); documented in README security notes.
