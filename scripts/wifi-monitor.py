"""One bounded sample per launchd invocation; no network reconfiguration."""

import argparse
import concurrent.futures
import datetime
import fcntl
import gzip
import json
import os
from pathlib import Path
import re
import subprocess
import socket
import time

RETENTION = 30 * 24 * 60 * 60
LOG_PREDICATE = '''
(process == "airportd" AND (
  eventMessage CONTAINS "LQM: rssi=" OR
  eventMessage CONTAINS "APPLE80211_M_LINK_CHANGED" OR
  eventMessage CONTAINS "APPLE80211_M_DEAUTH" OR
  eventMessage CONTAINS "APPLE80211_M_DISASSOC" OR
  eventMessage CONTAINS "PRIVATE MAC:" OR
  eventMessage CONTAINS "LINK DOWN" OR
  eventMessage CONTAINS "Roam complete" OR
  eventMessage CONTAINS "Power changed"
)) OR (process == "configd" AND eventMessage CONTAINS "en0")
'''


def run(args, timeout=8, limit=65536):
    started = time.monotonic()
    try:
        result = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
        return {
            "exit_code": result.returncode,
            "elapsed_s": round(time.monotonic() - started, 3),
            "stdout": result.stdout[-limit:],
            "stderr": result.stderr[-4096:],
            "truncated": len(result.stdout) > limit,
        }
    except subprocess.TimeoutExpired:
        return {"exit_code": None, "error": "timeout", "timeout_s": timeout}
    except OSError as error:
        return {"exit_code": None, "error": str(error)}


def prune(directory, now):
    for path in directory.glob("sample-*.json"):
        # Filename time survives copying and does not require parsing every record.
        match = re.fullmatch(r"sample-(\d+)\.json", path.name)
        if match and int(match[1]) < now - RETENTION:
            path.unlink(missing_ok=True)
    for path in directory.glob("samples-*.jsonl.gz"):
        match = re.fullmatch(r"samples-(\d+)\.jsonl\.gz", path.name)
        # Keep the bucket until its last possible sample has expired.
        if match and int(match[1]) + 3600 <= now - RETENTION:
            path.unlink(missing_ok=True)


def tcp_probe(host, port):
    started = time.monotonic()
    try:
        with socket.create_connection((host, port), timeout=2):
            status = "connected"
    except ConnectionRefusedError:
        status = "refused"  # A TCP reset also establishes that the target responded.
    except OSError as error:
        return {"host": host, "port": port, "status": "error", "error": str(error)}
    return {"host": host, "port": port, "status": status,
            "elapsed_s": round(time.monotonic() - started, 3)}


def compact_events(result):
    lines = []
    radio = []
    unparsed = 0
    for line in result.get("stdout", "").splitlines():
        try:
            event = json.loads(line)
        except ValueError:
            unparsed += 1
            continue
        if "eventMessage" not in event:
            continue
        message = event["eventMessage"]
        lines.append(json.dumps({"timestamp": event.get("timestamp"),
                                 "process": event.get("processImagePath"),
                                 "message": message}, ensure_ascii=False))
        if "LQM: rssi=" in message:
            metrics = {key: float(value) for key, value in re.findall(
                r"\b(rssi|noise|snr|cca|ccaSelfTotal|ccaOtherTotal|interferenceTotal|txRate|rxRate|txFrames|txFail|txRetrans|rxRetryFrames|beaconRecv|beaconSched)=(-?[\d.]+)", message)}
            radio.append({"timestamp": event.get("timestamp"), **metrics})
    result["stdout"] = "\n".join(lines)
    result["unparsed_lines"] = unparsed
    return radio


def save(directory, snapshot):
    now = snapshot["epoch"]
    target = directory / f"samples-{now // 3600 * 3600:010d}.jsonl.gz"
    payload = json.dumps(snapshot, ensure_ascii=False, separators=(",", ":")) + "\n"
    with target.open("ab") as output:
        output.write(gzip.compress(payload.encode(), compresslevel=6))
    temporary = directory / ".state.tmp"
    temporary.write_text(json.dumps({"epoch": now}))
    temporary.replace(directory / ".state.json")
    return target


def collect(directory, now):
    existing = sorted(directory.glob("sample-*.json"))
    previous = int(existing[-1].stem.split("-")[1]) if existing else now - 90
    try:
        previous = json.loads((directory / ".state.json").read_text())["epoch"]
    except (OSError, ValueError, KeyError):
        pass
    lookback = min(86400, max(90, now - previous + 10))
    hardware = run(["/usr/sbin/networksetup", "-listallhardwareports"])
    match = re.search(r"Hardware Port: (?:Wi-Fi|AirPort)\nDevice: (\S+)", hardware.get("stdout", ""))
    interface = match[1] if match else "en0"
    route = run(["/sbin/route", "-n", "get", "default"])
    dhcp_router = run(["/usr/sbin/ipconfig", "getoption", interface, "router"])
    gateway = dhcp_router.get("stdout", "").strip().splitlines()
    probes = {
        "interface": ["/sbin/ifconfig", interface],
        "dhcp": ["/usr/sbin/ipconfig", "getsummary", interface],
        "dns_config": ["/usr/sbin/scutil", "--dns"],
        "network": ["/usr/sbin/scutil", "--nwi"],
        "counters": ["/usr/sbin/netstat", "-I", interface, "-b", "-d"],
        "internet_ping": ["/sbin/ping", "-n", "-c", "3", "-W", "1000", "1.1.1.1"],
        "internet_ping_second": ["/sbin/ping", "-n", "-c", "3", "-W", "1000", "8.8.8.8"],
        "internet_route": ["/sbin/route", "-n", "get", "1.1.1.1"],
        "public_dns": ["/usr/bin/dig", "@1.1.1.1", "www.apple.com", "+time=2", "+tries=1", "+noall", "+comments", "+answer"],
        "dns_lookup": ["/usr/bin/dscacheutil", "-q", "host", "-a", "name", "www.apple.com"],
        "https": ["/usr/bin/curl", "--silent", "--show-error", "--noproxy", "*",
                  "--connect-timeout", "3", "--max-time", "6", "--output", "/dev/null",
                  "--write-out", "%{http_code} dns=%{time_namelookup} connect=%{time_connect} total=%{time_total}\n",
                  "https://www.apple.com/library/test/success.html"],
    }
    if gateway and re.fullmatch(r"[0-9.]+", gateway[0]):
        probes["gateway_ping"] = ["/sbin/ping", "-n", "-c", "3", "-W", "1000", "-b", interface, gateway[0]]
        probes["gateway_arp"] = ["/usr/sbin/arp", "-n", gateway[0]]
        probes["gateway_route"] = ["/sbin/route", "-n", "get", gateway[0]]
        probes["gateway_dns"] = ["/usr/bin/dig", "@" + gateway[0], "www.apple.com", "+time=2", "+tries=1", "+noall", "+comments", "+answer"]
    probes["wifi_events"] = ["/usr/bin/log", "show", "--last", f"{lookback}s",
                             "--style", "ndjson", "--predicate", LOG_PREDICATE.replace("en0", interface)]
    snapshot = {
        "schema": 2, "epoch": now,
        "timestamp": datetime.datetime.fromtimestamp(now).astimezone().isoformat(),
        "wifi_interface": interface, "default_route": route, "dhcp_router": dhcp_router,
        "log_lookback_s": lookback,
    }
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(probes) + 3) as pool:
        futures = {name: pool.submit(run, args, 15 if name == "wifi_events" else 8,
                                    262144 if name == "wifi_events" else 65536)
                   for name, args in probes.items()}
        tcp_futures = {"internet_tcp": pool.submit(tcp_probe, "1.1.1.1", 443)}
        if gateway and re.fullmatch(r"[0-9.]+", gateway[0]):
            tcp_futures.update({f"gateway_tcp_{port}": pool.submit(tcp_probe, gateway[0], port) for port in (80, 443)})
        snapshot.update({name: future.result() for name, future in futures.items()})
        snapshot.update({name: future.result() for name, future in tcp_futures.items()})
    snapshot["radio"] = compact_events(snapshot["wifi_events"])
    # Independent fallback when macOS omits LQM logs. Avoid scanning every minute.
    if (not existing and not (directory / ".state.json").exists()) or now // 300 != previous // 300:
        snapshot["wifi_details"] = run(["/usr/sbin/system_profiler", "SPAirPortDataType", "-json"], 20)
    target = save(directory, snapshot)
    prune(directory, int(time.time()))
    return target


def records(directory, since):
    for path in sorted(directory.glob("sample-*.json")):
        if int(path.stem.split("-")[1]) >= since:
            yield json.loads(path.read_text())
    for path in sorted(directory.glob("samples-*.jsonl.gz")):
        if int(path.name.split("-")[1].split(".")[0]) + 3600 < since:
            continue
        with gzip.open(path, "rt") as source:
            for line in source:
                sample = json.loads(line)
                if sample["epoch"] >= since:
                    yield sample


def summary(directory, hours):
    totals = {"samples": 0, "gateway_ping_loss": 0, "gateway_tcp_unresponsive": 0,
              "both_external_pings_failed": 0, "router_dns_failed": 0,
              "public_dns_failed": 0, "https_failed": 0}
    signal = []
    size = sum(p.stat().st_size for p in directory.glob("samples-*.jsonl.gz"))
    for row in records(directory, time.time() - hours * 3600):
        totals["samples"] += 1
        for r in row.get("radio", []):
            if "rssi" in r:
                signal.append(r["rssi"])
        ping = row.get("gateway_ping", {}).get("stdout", "")
        loss = re.search(r"([\d.]+)% packet loss", ping)
        totals["gateway_ping_loss"] += bool(loss and float(loss[1]) > 0)
        tcp = [row[k]["status"] for k in ("gateway_tcp_80", "gateway_tcp_443") if k in row]
        totals["gateway_tcp_unresponsive"] += bool(tcp and all(s == "error" for s in tcp))
        totals["both_external_pings_failed"] += all(k in row and row[k].get("exit_code") != 0 for k in ("internet_ping", "internet_ping_second"))
        for key, label in (("gateway_dns", "router_dns_failed"), ("public_dns", "public_dns_failed")):
            probe = row.get(key)
            if probe:
                totals[label] += probe.get("exit_code") != 0 or "status: NOERROR" not in probe.get("stdout", "")
        https = row.get("https", {})
        totals["https_failed"] += https.get("exit_code") != 0 or not https.get("stdout", "").startswith("200 ")
    print(json.dumps({"hours": hours, **totals, "rssi_min_max_dbm": [min(signal), max(signal)] if signal else None,
                      "compressed_bytes_on_disk": size,
                      "note": "Counts are observations, not proof of router failure. Compare radio quality and simultaneous probe results."}, ensure_ascii=False, indent=2))


def main():
    parser = argparse.ArgumentParser(description="Record Wi-Fi diagnostics and retain the latest 30 days.")
    parser.add_argument("--directory", type=Path, default=Path.home() / "Library/Logs/wifi-monitor")
    parser.add_argument("--summary", action="store_true", help="Summarize saved probes without making network requests")
    parser.add_argument("--hours", type=int, default=24, help="Summary window (720 for 30 days)")
    args = parser.parse_args()
    os.umask(0o077)
    args.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (args.directory / ".lock").open("w") as lock:
        if args.summary:
            fcntl.flock(lock, fcntl.LOCK_SH)
            summary(args.directory, args.hours)
            return
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return
        now = int(time.time())
        prune(args.directory, now)
        print(collect(args.directory, now))


if __name__ == "__main__":
    main()
