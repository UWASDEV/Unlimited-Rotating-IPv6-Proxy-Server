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
- `/etc/sixrelay/sixrelay.env` (0640) — the one config both services read (systemd `EnvironmentFile`).
- `/etc/sysctl.d/99-sixrelay.conf` — `ip_nonlocal_bind`, forwarding, `proxy_ndp`, `accept_dad=0`, `dad_transmits=0`.
- `/etc/ndppd.conf` — `static` rule for the detected subnet (previous `/etc/ndppd.conf` backed up to `…​.sixrelay-orig`).
- `sixrelay-net.service` (loop asserts sysctls + `local <subnet>` route + ndppd) and `sixrelay.service` (the relay). Both enabled → boot-safe.

## Auto-detection (the crux of being generic)
- **python3 first**: python3 is used during detection, so if it is missing it is `apt`-installed before any detection runs.
- **iface**: interface of the IPv6 default route; fallback = first non-lo interface with a global IPv6.
- **primary /prefix**: first global IPv6 on the iface, preferring a **stable** address (skips `temporary`/`deprecated` SLAAC-privacy addresses) → reserved (never handed out).
- **subnet**: the network of the primary address. If that yields a `/128` (or prefix > /120, no room to rotate), fall back to scanning `ip -6 route show dev <iface>` for a routed non-default, non-link-local, non-`/128` prefix. If still none, fail with an explicit `--subnet <your::/64>` hint (covers the "/128 primary + separately-routed /64" provider layout). `--subnet` always wins and is never overridden by the route scan.
- **gateway**: `via` of the IPv6 default route → reserved.
- **listen**: primary public IPv4, else `0.0.0.0`; overridable.
- **config reuse on re-run**: iface, listen, port, subnet, interval and credentials are all **kept** from the existing `sixrelay.env` unless overridden on the CLI, so a bare re-run never silently changes the port/creds clients depend on; a fresh box gets detected values + random `[A-Za-z0-9]` creds. Credentials are validated against `[A-Za-z0-9._-]` so they are safe in the `EnvironmentFile` and shell.
- Detection functions tolerate a bad `--iface`/missing data (return empty, then the explicit `die` fires) rather than aborting under `set -e`.
- Everything is printed and (unless `--yes`, required for non-tty runs) confirmed before any change.

## Design decisions / rationale
- **Routed-mode only** (no per-address assignment): this is the whole point — nothing to flush, entire /64 as the pool. Proven on a real /64 in the previous phase (unassigned-source bind → egress → return path all verified).
- **ndppd is best-effort**: routed subnets work without it; on-link subnets need it. If `apt-get install ndppd` fails (e.g. universe disabled), warn and continue — the self-test then reveals whether egress works, rather than aborting.
- **Idempotent**: re-running overwrites files and restarts services; existing credentials are preserved (see detection) so repeated runs never invalidate issued creds; safe to run repeatedly.
- **dpkg-lock tolerance**: all `apt-get` calls use `-o DPkg::Lock::Timeout=300` — fresh Ubuntu VPSes routinely run `unattended-upgrades`/`apt-daily` right after boot, which would otherwise make the package installs fail spuriously (observed and fixed during Layer-3 testing: `apt-get install` returned exit 100 with the lock held by `unattended-upgr`).
- **Credentials restricted to alnum**: avoids `EnvironmentFile`/shell quoting hazards.
- `sixrelay-net.sh` reads only `SIXRELAY_IFACE`/`SIXRELAY_SUBNET`, from the environment (systemd injects them) or via a narrow `sed` of the env file — it never `source`s the whole file.

## Gates (the installer's self-test must pass all; `test/selftest.py`)
Local source-observer (`srcecho` bound `[::]:45678`) driven **through** the relay, plus a real external gate. Objective, scripted, exit 0 only if all pass:
- **auth**: good creds accepted, wrong creds rejected (`01 01`).
- **egress-source**: observed source ∈ subnet **and** not assigned to any interface.
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

**Honesty note:** Layer 3 is authoritative for behaviour but runs where python3/ndppd already exist; Layer 2 covers the fresh-OS package path; Layer 1 covers the detection genericity that neither of the others exercises. Together they substantiate "works on a fresh Ubuntu 22.04/24.04 VPS" as far as is possible without renting a second VPS per provider.

## Rollback / safety
- Prior-phase backups remain at `/root/proxyserver/backup-*/`.
- `--uninstall` fully reverses the installer; ndppd.conf original is restored from its backup.
- The teardown/reinstall causes a brief proxy interruption on this box (acceptable; ends working), consistent with the user's request to test a from-scratch install.

## Known limitations (documented, non-blocking)
- Egress IPv6-only (IPv4-only targets unreachable — inherent to an IPv6 proxy).
- TCP `CONNECT` only (no UDP ASSOCIATE / BIND).
- Authenticated clients can reach host-internal IPv6 (SSRF-class); documented in README security notes.
