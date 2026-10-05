"""Import a private Proton WireGuard config without putting keys in Nix outputs."""

import argparse
import base64
import configparser
import ipaddress
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


def wg_key(value):
    if len(base64.b64decode(value, validate=True)) != 32:
        raise ValueError("Invalid WireGuard key")
    return value


def convert(source, port=17890):
    parser = configparser.ConfigParser(interpolation=None, inline_comment_prefixes=("#",))
    parser.read_string(source)
    interface, peer = parser["Interface"], parser["Peer"]
    endpoint = peer["Endpoint"]
    host, endpoint_port = endpoint.rsplit(":", 1)
    host = str(ipaddress.ip_address(host.strip("[]")))
    endpoint_port = int(endpoint_port)
    if not 1 <= endpoint_port <= 65535:
        raise ValueError("Invalid endpoint port")
    addresses = [str(ipaddress.ip_interface(x.strip())) for x in interface["Address"].split(",")]
    dns = str(ipaddress.ip_address(interface["DNS"].split(",")[0].strip()))
    allowed = [str(ipaddress.ip_network(x.strip())) for x in peer["AllowedIPs"].split(",")]
    if "0.0.0.0/0" not in allowed:
        raise ValueError("A full-tunnel WireGuard config is required")
    wg_peer = {
        "address": host,
        "port": endpoint_port,
        "public_key": wg_key(peer["PublicKey"]),
        "allowed_ips": allowed,
        "persistent_keepalive_interval": 25,
    }
    if peer.get("PresharedKey"):
        wg_peer["pre_shared_key"] = wg_key(peer["PresharedKey"])
    return {
        "log": {"level": "warn", "timestamp": True},
        "inbounds": [{"type": "http", "tag": "mirror", "listen": "127.0.0.1", "listen_port": port}],
        "endpoints": [{
            "type": "wireguard", "tag": "proton", "system": False, "mtu": 1280,
            "address": addresses, "private_key": wg_key(interface["PrivateKey"]),
            "peers": [wg_peer],
        }],
        "dns": {"servers": [{"type": "udp", "tag": "vpn-dns", "server": dns, "detour": "proton"}],
                "final": "vpn-dns"},
        "route": {"final": "proton", "default_domain_resolver": "vpn-dns"},
    }


def main():
    argparser = argparse.ArgumentParser(description=__doc__)
    argparser.add_argument("source", type=Path, help="Downloaded Proton WireGuard .conf")
    argparser.add_argument("--output", type=Path, default=Path.home() / ".config/mirror/vpn.json")
    argparser.add_argument("--port", type=int, default=17890)
    args = argparser.parse_args()
    if not 1 <= args.port <= 65535:
        argparser.error("Invalid proxy port")
    # Do not print parse exceptions: they can contain secret input lines.
    try:
        config = convert(args.source.read_text(), args.port)
    except Exception:
        argparser.exit(1, "Could not import config. Use a Proton WireGuard .conf with an IP endpoint.\n")
    executable = shutil.which("sing-box")
    if not executable:
        argparser.exit(1, "sing-box is required to validate the configuration.\n")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    fd, temp_path = tempfile.mkstemp(prefix=".vpn-", suffix=".json", dir=args.output.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(config, stream)
        check = subprocess.run([executable, "check", "-c", temp_path], capture_output=True)
        if check.returncode:
            argparser.exit(1, "sing-box rejected the configuration; existing config preserved.\n")
        os.replace(temp_path, args.output)
    finally:
        if os.path.exists(temp_path):
            os.unlink(temp_path)
    print(f"Imported private VPN config to {args.output} (permissions 600).")
    if args.output == Path.home() / ".config/mirror/vpn.json":
        # If activation has already registered the service, apply updated credentials.
        result = subprocess.run(
            ["/bin/launchctl", "kickstart", "-k", f"gui/{os.getuid()}/org.nixos.mirror-vpn"],
            capture_output=True,
        )
        print("VPN service restarted." if result.returncode == 0 else "Activate the Nix configuration with ./apply to start the VPN service.")


if __name__ == "__main__":
    main()
