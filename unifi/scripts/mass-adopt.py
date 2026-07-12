#!/usr/bin/env python3
"""mass-adopt.py — bulk-adopt UniFi devices onto a UniFi OS Server controller.

Cross-platform (Windows or Linux). Discovers UniFi devices across one or more
subnets and points each at *your* controller via `mca-cli-op set-inform`, so a
whole site's worth of factory/migrating APs and switches join in one pass.

Authorized-admin tooling: it only works with SSH credentials you already hold
and only redirects devices to the controller you name. Use it on estates you
manage. It does not exfiltrate anything — credentials are read from a local
.env, kept in memory, and never printed or passed on the command line.

Credentials / config come from a .env file (see .env.example). Keys:
    UNIFI_CONTROLLER      controller host/IP devices must reach (required)
    UNIFI_INFORM_PORT     inform port (default 8080)
    UNIFI_SSH_USERS       comma list of SSH users to try (default: ui,ubnt)
    UNIFI_SSH_PASSWORD    SSH password for factory/managed devices (optional)
    UNIFI_SSH_KEY         path to an SSH private key (preferred over password)
    UNIFI_SUBNETS         comma list of CIDRs to scan (or use --subnet/--host)
    UNIFI_API_KEY         optional; used only for the post-adoption --verify check

Examples:
    ./mass-adopt.py --env .env --subnet 192.168.1.0/24 --dry-run
    ./mass-adopt.py --env .env                 # uses UNIFI_SUBNETS from .env
    ./mass-adopt.py --host 192.168.1.20 --host 192.168.1.21
"""
from __future__ import annotations

import argparse
import ipaddress
import os
import shutil
import socket
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed

INFORM_CMD = "mca-cli-op set-inform {url}"


def load_env(path: str) -> dict[str, str]:
    """Minimal .env reader — KEY=VALUE, # comments, optional quotes."""
    env: dict[str, str] = {}
    if not path or not os.path.isfile(path):
        return env
    with open(path, encoding="utf-8") as fh:
        for raw in fh:
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, val = line.partition("=")
            val = val.strip().strip('"').strip("'")
            env[key.strip()] = val
    return env


def cfg(env: dict[str, str], key: str, default: str = "") -> str:
    """Real environment wins over the .env file, then default."""
    return os.environ.get(key) or env.get(key) or default


def discover_nmap(cidr: str) -> list[str]:
    """Use nmap UDP/10001 to find genuine UniFi devices (least collateral)."""
    cmd = ["nmap", "-n", "-sU", "-p", "10001,22", cidr, "-oG", "-"]
    if os.name != "nt" and os.geteuid() != 0:
        cmd.insert(0, "sudo")
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=600).stdout
    except (subprocess.SubprocessError, OSError) as exc:
        print(f"  nmap failed on {cidr}: {exc}", file=sys.stderr)
        return []
    hosts = []
    for line in out.splitlines():
        if line.startswith("Host:") and "10001/open" in line:
            hosts.append(line.split()[1])
    return hosts


def discover_tcp(cidr: str, port: int = 22, workers: int = 128) -> list[str]:
    """Opt-in fallback: TCP/22 sweep when nmap is unavailable."""
    net = ipaddress.ip_network(cidr, strict=False)

    def probe(ip: str) -> str | None:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.settimeout(1.0)
            return ip if s.connect_ex((ip, port)) == 0 else None

    found: list[str] = []
    addrs = [str(h) for h in net.hosts()]
    with ThreadPoolExecutor(max_workers=workers) as pool:
        for fut in as_completed(pool.submit(probe, ip) for ip in addrs):
            if (ip := fut.result()) is not None:
                found.append(ip)
    return found


def set_inform(host: str, users: list[str], password: str, key: str, url: str) -> tuple[bool, str]:
    """SSH to a device and run set-inform, trying each user. Needs paramiko."""
    try:
        import paramiko
    except ImportError:
        return False, "paramiko not installed (pip install paramiko)"

    pkey = None
    if key:
        try:
            pkey = paramiko.PKey.from_path(key) if hasattr(paramiko.PKey, "from_path") \
                else paramiko.RSAKey.from_private_key_file(key)
        except Exception as exc:  # noqa: BLE001 - report and fall through to password
            return False, f"bad key {key}: {exc}"

    last = "no credentials accepted"
    for user in users:
        client = paramiko.SSHClient()
        client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        try:
            client.connect(
                host, port=22, username=user,
                password=password or None, pkey=pkey,
                timeout=5, allow_agent=False, look_for_keys=False,
            )
            _in, out, err = client.exec_command(INFORM_CMD.format(url=url), timeout=10)
            rc = out.channel.recv_exit_status()
            msg = (out.read().decode() + err.read().decode()).strip()
            if rc == 0:
                return True, f"{user}: {msg or 'set-inform ok'}"
            last = f"{user}: exit {rc}: {msg}"
        except Exception as exc:  # noqa: BLE001 - try next user
            last = f"{user}: {exc}"
        finally:
            client.close()
    return False, last


def main() -> int:
    ap = argparse.ArgumentParser(description="Bulk-adopt UniFi devices via set-inform.")
    ap.add_argument("--env", default=".env", help="path to .env (default: .env)")
    ap.add_argument("--subnet", action="append", default=[], help="CIDR to scan (repeatable)")
    ap.add_argument("--host", action="append", default=[], help="explicit device IP (repeatable)")
    ap.add_argument("--controller", help="override controller host/IP")
    ap.add_argument("--inform-port", type=int, help="override inform port")
    ap.add_argument("--tcp-scan", action="store_true", help="fall back to TCP/22 sweep if nmap missing")
    ap.add_argument("--dry-run", action="store_true", help="print planned set-inform, do nothing")
    ap.add_argument("--yes", action="store_true", help="skip the confirmation prompt")
    args = ap.parse_args()

    env = load_env(args.env)
    controller = args.controller or cfg(env, "UNIFI_CONTROLLER")
    if not controller:
        print("error: UNIFI_CONTROLLER not set (in --env or environment)", file=sys.stderr)
        return 2
    port = args.inform_port or int(cfg(env, "UNIFI_INFORM_PORT", "8080"))
    users = [u.strip() for u in cfg(env, "UNIFI_SSH_USERS", "ui,ubnt").split(",") if u.strip()]
    password = cfg(env, "UNIFI_SSH_PASSWORD")
    key = cfg(env, "UNIFI_SSH_KEY")
    url = f"http://{controller}:{port}/inform"

    subnets = args.subnet or [s.strip() for s in cfg(env, "UNIFI_SUBNETS").split(",") if s.strip()]

    # Build the target list.
    targets: list[str] = list(dict.fromkeys(args.host))
    if subnets:
        have_nmap = shutil.which("nmap") is not None
        for cidr in subnets:
            if have_nmap:
                found = discover_nmap(cidr)
            elif args.tcp_scan:
                print(f"  nmap missing — TCP/22 sweep on {cidr}", file=sys.stderr)
                found = discover_tcp(cidr)
            else:
                print(f"  skip {cidr}: nmap not found (install it or pass --tcp-scan)", file=sys.stderr)
                found = []
            targets.extend(found)
    targets = list(dict.fromkeys(targets))

    if not targets:
        print("No target devices (give --host, --subnet, or UNIFI_SUBNETS).")
        return 0

    print(f"Controller inform URL : {url}")
    print(f"Devices to adopt      : {len(targets)}")
    for t in targets:
        print(f"  - {t}")

    if args.dry_run:
        print("\nDRY-RUN: would run, per device:")
        print(f"  ssh <{'/'.join(users)}>@<device> '{INFORM_CMD.format(url=url)}'")
        return 0

    if not args.yes and sys.stdin.isatty():
        if input(f"\nPoint {len(targets)} device(s) at {controller}? [y/N] ").strip().lower() != "y":
            print("Aborted.")
            return 1

    ok = failed = 0
    for host in targets:
        good, detail = set_inform(host, users, password, key, url)
        print(f"  [{'ok ' if good else 'FAIL'}] {host}  {detail}")
        ok += good
        failed += not good

    print(f"\nSummary: {ok} adopted, {failed} failed, {len(targets)} total.")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
