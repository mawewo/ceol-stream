#!/usr/bin/env python3
"""
Ceòl Stream - Web UI Server
Lightweight REST API and static file server for managing the audio streamer.
No external dependencies - uses only Python 3 standard library.
"""

import http.server
import json
import os
import re
import subprocess
import socket
import pathlib
import threading
import time

WEB_DIR = pathlib.Path(__file__).parent
SERVICES = {
    "roonbridge": {
        "name": "Roon Bridge",
        "unit": "roonbridge.service",
        "description": "Roon Bridge endpoint renderer"
    },
    "networkaudiod": {
        "name": "HQPlayer NAA",
        "unit": "networkaudiod.service",
        "description": "HQPlayer Network Audio Adapter"
    },
    "shairport-sync": {
        "name": "AirPlay",
        "unit": "shairport-sync.service",
        "description": "AirPlay 1 receiver — truly lossless (16-bit / 44.1 kHz)"
    },
    "gmediarender": {
        "name": "UPnP/DLNA",
        "unit": "gmediarender.service",
        "description": "UPnP/DLNA renderer — hi-res (up to 24-bit / 192 kHz)"
    }
}
CEOL_CONF = "/etc/ceol-stream/config.json"


def run(cmd, timeout=10):
    """Run a shell command and return (returncode, stdout, stderr)."""
    try:
        r = subprocess.run(
            cmd, shell=True, capture_output=True, text=True, timeout=timeout
        )
        return r.returncode, r.stdout.strip(), r.stderr.strip()
    except subprocess.TimeoutExpired:
        return 1, "", "timeout"


def load_config():
    """Load persistent config."""
    try:
        with open(CEOL_CONF) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {"dac": "", "services": {"roonbridge": True, "networkaudiod": False, "shairport-sync": True}}


def save_config(cfg):
    """Save persistent config."""
    os.makedirs(os.path.dirname(CEOL_CONF), exist_ok=True)
    with open(CEOL_CONF, "w") as f:
        json.dump(cfg, f, indent=2)


# --- API Handlers ---

def _parse_dac_capabilities(card_num, dev_num):
    """Parse /proc/asound/cardX/streamY to get DAC capabilities."""
    caps = {"max_bit_depth": 0, "max_sample_rate": 0, "dsd": False, "formats": [], "rates": []}
    stream_path = f"/proc/asound/card{card_num}/stream{dev_num}"
    try:
        with open(stream_path) as f:
            content = f.read()
    except (FileNotFoundError, PermissionError):
        return caps

    in_playback = False
    for line in content.splitlines():
        # Look for the Playback section
        if "Playback:" in line:
            in_playback = True
            continue
        if "Capture:" in line:
            in_playback = False
            continue
        if not in_playback:
            continue

        line = line.strip()

        # Parse formats (e.g., S16_LE, S24_3LE, S32_LE, DSD_U32_BE)
        if line.startswith("Format:") or line.startswith("Formats:"):
            fmt_str = line.split(":", 1)[1].strip()
            for fmt in fmt_str.split():
                fmt = fmt.strip().rstrip(",")
                if not fmt:
                    continue
                if fmt.startswith("DSD"):
                    caps["dsd"] = True
                else:
                    # Extract bit depth from format name (S16_LE, S24_LE, S24_3LE, S32_LE, etc.)
                    m = re.search(r'[SU](\d+)', fmt)
                    if m:
                        bits = int(m.group(1))
                        # S24_3LE is true 24-bit, S32_LE could be 24-in-32 or 32-bit
                        if bits > caps["max_bit_depth"]:
                            caps["max_bit_depth"] = bits

        # Parse sample rates (e.g., "Rates: 44100, 48000, 88200, 96000, 176400, 192000")
        if line.startswith("Rate") and ":" in line:
            rate_str = line.split(":", 1)[1].strip()
            for r in rate_str.split(","):
                r = r.strip()
                if r.isdigit():
                    rate = int(r)
                    caps["rates"].append(rate)
                    if rate > caps["max_sample_rate"]:
                        caps["max_sample_rate"] = rate

    return caps


def _format_sample_rate(rate):
    """Format sample rate for display (e.g., 192000 -> '192 kHz')."""
    if rate >= 1000:
        return f"{rate / 1000:g} kHz"
    return f"{rate} Hz"


def api_dacs(_body):
    """List USB audio DACs available on the system."""
    dacs = []
    rc, out, _ = run("aplay -l 2>/dev/null")
    if rc == 0:
        for line in out.splitlines():
            m = re.match(r"^card (\d+): (\S+) \[(.+?)\], device (\d+): (.+)", line)
            if m:
                card_num, card_id, card_name, dev_num, dev_name = m.groups()
                # Only include USB devices
                rc2, out2, _ = run(f"readlink -f /sys/class/sound/card{card_num}/device 2>/dev/null")
                is_usb = "usb" in out2.lower() if rc2 == 0 else False
                if is_usb:
                    caps = _parse_dac_capabilities(card_num, dev_num)
                    dacs.append({
                        "card": int(card_num),
                        "device": int(dev_num),
                        "id": card_id,
                        "name": card_name,
                        "device_name": dev_name,
                        "alsa_device": f"hw:{card_num},{dev_num}",
                        "max_bit_depth": caps["max_bit_depth"],
                        "max_sample_rate": caps["max_sample_rate"],
                        "max_sample_rate_display": _format_sample_rate(caps["max_sample_rate"]) if caps["max_sample_rate"] else "Unknown",
                        "dsd": caps["dsd"]
                    })
    config = load_config()
    return {"dacs": dacs, "selected": config.get("dac", "")}


def api_set_dac(body):
    """Set the active USB DAC."""
    dac = body.get("dac", "")
    config = load_config()
    config["dac"] = dac
    save_config(config)
    _apply_dac_config(dac)
    return {"ok": True, "dac": dac}


def _apply_dac_config(dac):
    """Write ALSA and service configs to use the selected DAC."""
    if not dac:
        return
    # Write global ALSA config pointing to the selected DAC
    asound_conf = f"""# Ceòl Stream - ALSA configuration
# Bit-perfect output: no resampling, no mixing, direct hardware access
# Generated automatically - do not edit manually

defaults.pcm.card {dac.split(':')[1].split(',')[0] if ':' in dac else '0'}
defaults.pcm.device {dac.split(',')[1] if ',' in dac else '0'}
defaults.ctl.card {dac.split(':')[1].split(',')[0] if ':' in dac else '0'}

pcm.!default {{
    type hw
    card {dac.split(':')[1].split(',')[0] if ':' in dac else '0'}
    device {dac.split(',')[1] if ',' in dac else '0'}
}}

ctl.!default {{
    type hw
    card {dac.split(':')[1].split(',')[0] if ':' in dac else '0'}
}}
"""
    try:
        with open("/etc/asound.conf", "w") as f:
            f.write(asound_conf)
    except PermissionError:
        run(f"echo '{asound_conf}' | sudo tee /etc/asound.conf > /dev/null")

    # Update shairport-sync config with the correct ALSA device
    _update_shairport_config(dac)
    # Update gmediarender service with the correct ALSA device
    _update_gmediarender_config(dac)


def _update_shairport_config(dac):
    """Update shairport-sync.conf to use the selected DAC."""
    conf_path = "/etc/shairport-sync.conf"
    if not os.path.exists(conf_path):
        return
    try:
        with open(conf_path) as f:
            content = f.read()
        # Update the output_device line
        card_num = dac.split(':')[1].split(',')[0] if ':' in dac else '0'
        dev_num = dac.split(',')[1] if ',' in dac else '0'
        new_device = f"hw:{card_num},{dev_num}"
        content = re.sub(
            r'output_device\s*=\s*"[^"]*"',
            f'output_device = "{new_device}"',
            content
        )
        with open(conf_path, "w") as f:
            f.write(content)
        # Restart shairport-sync if it's running to pick up the new DAC
        run("systemctl restart shairport-sync.service 2>/dev/null")
    except (PermissionError, FileNotFoundError):
        pass


def _update_gmediarender_config(dac):
    """Update gmediarender systemd service to use the selected DAC."""
    service_path = "/etc/systemd/system/gmediarender.service"
    if not os.path.exists(service_path):
        return
    try:
        with open(service_path) as f:
            content = f.read()
        content = re.sub(
            r'--gstout-audiodevice=\S+',
            f'--gstout-audiodevice={dac}',
            content
        )
        with open(service_path, "w") as f:
            f.write(content)
        run("systemctl daemon-reload")
        run("systemctl restart gmediarender.service 2>/dev/null")
    except (PermissionError, FileNotFoundError):
        pass


def api_services(_body):
    """Get status of all streaming services."""
    config = load_config()
    result = {}
    for svc_id, svc in SERVICES.items():
        rc, state, _ = run(f"systemctl is-active {svc['unit']} 2>/dev/null")
        rc2, enabled, _ = run(f"systemctl is-enabled {svc['unit']} 2>/dev/null")
        # Check if the service is actually installed
        rc3, _, _ = run(f"systemctl cat {svc['unit']} 2>/dev/null")
        result[svc_id] = {
            "name": svc["name"],
            "description": svc["description"],
            "installed": rc3 == 0,
            "active": state == "active",
            "enabled": enabled == "enabled",
            "state": state if rc3 == 0 else "not installed"
        }
    return {"services": result}


def api_service_toggle(body):
    """Enable or disable a streaming service."""
    svc_id = body.get("service", "")
    action = body.get("action", "")  # "enable" or "disable"
    if svc_id not in SERVICES:
        return {"error": f"Unknown service: {svc_id}"}
    unit = SERVICES[svc_id]["unit"]
    if action == "enable":
        run(f"systemctl enable --now {unit}")
    elif action == "disable":
        run(f"systemctl disable --now {unit}")
    elif action == "restart":
        run(f"systemctl restart {unit}")
    else:
        return {"error": f"Unknown action: {action}"}
    config = load_config()
    config.setdefault("services", {})[svc_id] = (action == "enable")
    save_config(config)
    return {"ok": True}


def api_network(_body):
    """Get network configuration."""
    interfaces = []
    rc, out, _ = run("ip -j addr show 2>/dev/null")
    if rc == 0:
        try:
            ifaces = json.loads(out)
            for iface in ifaces:
                name = iface.get("ifname", "")
                if name == "lo":
                    continue
                addrs = []
                for addr_info in iface.get("addr_info", []):
                    if addr_info.get("family") == "inet":
                        addrs.append(addr_info.get("local", ""))
                is_wifi = name.startswith("wl")
                interfaces.append({
                    "name": name,
                    "type": "wifi" if is_wifi else "ethernet",
                    "addresses": addrs,
                    "state": iface.get("operstate", "unknown").lower()
                })
        except json.JSONDecodeError:
            pass

    # Get current hostname
    hostname = socket.gethostname()

    # Get WiFi networks if wifi interface exists
    wifi_connected = ""
    rc, out, _ = run("nmcli -t -f active,ssid dev wifi 2>/dev/null")
    if rc == 0:
        for line in out.splitlines():
            if line.startswith("yes:"):
                wifi_connected = line.split(":", 1)[1]

    # Check if using DHCP or static (via NetworkManager)
    ip_method = "auto"
    rc, out, _ = run("nmcli -t -f NAME,TYPE con show --active 2>/dev/null")
    if rc == 0:
        for line in out.splitlines():
            conn_name = line.split(":")[0]
            rc2, method, _ = run(f"nmcli -t -f ipv4.method con show '{conn_name}' 2>/dev/null")
            if rc2 == 0 and "manual" in method:
                ip_method = "static"
                break

    return {
        "hostname": hostname,
        "interfaces": interfaces,
        "wifi_connected": wifi_connected,
        "ip_method": ip_method
    }


def api_set_hostname(body):
    """Set the system hostname."""
    new_name = body.get("hostname", "").strip()
    if not new_name or not re.match(r'^[a-zA-Z0-9][a-zA-Z0-9\-]{0,62}$', new_name):
        return {"error": "Invalid hostname. Use alphanumeric characters and hyphens only."}
    run(f"hostnamectl set-hostname '{new_name}'")
    # Update /etc/hosts
    run(f"sed -i 's/127\\.0\\.1\\.1.*/127.0.1.1\\t{new_name}/' /etc/hosts")
    # Update shairport-sync name if configured
    conf_path = "/etc/shairport-sync.conf"
    if os.path.exists(conf_path):
        try:
            with open(conf_path) as f:
                content = f.read()
            content = re.sub(r'name\s*=\s*"[^"]*"', f'name = "{new_name}"', content)
            with open(conf_path, "w") as f:
                f.write(content)
            run("systemctl restart shairport-sync.service 2>/dev/null")
        except (PermissionError, FileNotFoundError):
            pass
    return {"ok": True, "hostname": new_name}


def api_wifi_scan(_body):
    """Scan for available WiFi networks."""
    networks = []
    rc, out, _ = run("nmcli -t -f ssid,signal,security dev wifi list --rescan yes 2>/dev/null", timeout=15)
    if rc == 0:
        seen = set()
        for line in out.splitlines():
            parts = line.split(":")
            if len(parts) >= 3 and parts[0] and parts[0] not in seen:
                seen.add(parts[0])
                networks.append({
                    "ssid": parts[0],
                    "signal": int(parts[1]) if parts[1].isdigit() else 0,
                    "security": parts[2] if parts[2] else "Open"
                })
    networks.sort(key=lambda x: x["signal"], reverse=True)
    return {"networks": networks}


def api_wifi_connect(body):
    """Connect to a WiFi network."""
    ssid = body.get("ssid", "")
    password = body.get("password", "")
    if not ssid:
        return {"error": "SSID is required"}
    if password:
        rc, _, err = run(f"nmcli dev wifi connect '{ssid}' password '{password}'", timeout=30)
    else:
        rc, _, err = run(f"nmcli dev wifi connect '{ssid}'", timeout=30)
    if rc != 0:
        return {"error": f"Failed to connect: {err}"}
    return {"ok": True}


def api_wifi_disconnect(_body):
    """Disconnect from the current WiFi network."""
    # Find the active wifi connection
    rc, out, _ = run("nmcli -t -f NAME,TYPE,DEVICE con show --active 2>/dev/null")
    if rc != 0:
        return {"error": "Failed to query connections"}
    for line in out.splitlines():
        parts = line.split(":")
        if len(parts) >= 3 and parts[1] == "802-11-wireless" and parts[2]:
            conn_name = parts[0]
            rc2, _, err = run(f"nmcli con down '{conn_name}'", timeout=15)
            if rc2 != 0:
                return {"error": f"Failed to disconnect: {err}"}
            return {"ok": True}
    return {"error": "No active WiFi connection found"}


def api_set_static_ip(body):
    """Set static IP configuration."""
    interface = body.get("interface", "")
    ip_addr = body.get("ip", "")
    gateway = body.get("gateway", "")
    dns = body.get("dns", "")
    if not interface or not ip_addr:
        return {"error": "Interface and IP address are required"}
    # Find the connection name for the interface
    rc, out, _ = run(f"nmcli -t -f NAME,DEVICE con show 2>/dev/null")
    conn_name = ""
    if rc == 0:
        for line in out.splitlines():
            parts = line.split(":")
            if len(parts) >= 2 and parts[1] == interface:
                conn_name = parts[0]
                break
    if not conn_name:
        return {"error": f"No connection found for interface {interface}"}
    run(f"nmcli con mod '{conn_name}' ipv4.method manual ipv4.addresses '{ip_addr}'")
    if gateway:
        run(f"nmcli con mod '{conn_name}' ipv4.gateway '{gateway}'")
    if dns:
        run(f"nmcli con mod '{conn_name}' ipv4.dns '{dns}'")
    run(f"nmcli con up '{conn_name}'")
    return {"ok": True}


def api_set_dhcp(body):
    """Set DHCP configuration."""
    interface = body.get("interface", "")
    if not interface:
        return {"error": "Interface is required"}
    rc, out, _ = run(f"nmcli -t -f NAME,DEVICE con show 2>/dev/null")
    conn_name = ""
    if rc == 0:
        for line in out.splitlines():
            parts = line.split(":")
            if len(parts) >= 2 and parts[1] == interface:
                conn_name = parts[0]
                break
    if not conn_name:
        return {"error": f"No connection found for interface {interface}"}
    run(f"nmcli con mod '{conn_name}' ipv4.method auto ipv4.addresses '' ipv4.gateway '' ipv4.dns ''")
    run(f"nmcli con up '{conn_name}'")
    return {"ok": True}


UPDATE_LOG = "/tmp/ceol-stream-update.log"
UPDATE_STATE = {"running": False, "rc": None, "started": 0}
_update_lock = threading.Lock()


def _run_update():
    """Background thread that runs the system update and streams output to a log file."""
    try:
        with open(UPDATE_LOG, "w") as log:
            log.write(">>> apt-get update\n")
            log.flush()
            proc = subprocess.Popen(
                ["apt-get", "update"],
                stdout=log, stderr=subprocess.STDOUT, text=True
            )
            proc.wait()
            log.write(f"\n>>> apt-get upgrade -y\n")
            log.flush()
            proc2 = subprocess.Popen(
                ["apt-get", "upgrade", "-y"],
                stdout=log, stderr=subprocess.STDOUT, text=True
            )
            proc2.wait()
            rc = proc2.returncode
            log.write(f"\n>>> Update finished (exit code {rc})\n")
            # Check if a reboot is required (e.g. kernel update)
            if os.path.exists("/var/run/reboot-required"):
                log.write("\n*** REBOOT REQUIRED ***\n")
                log.write("A system reboot is needed to apply all updates (e.g. kernel).\n")
                log.write("You can reboot from the System tab.\n")
    except Exception as e:
        rc = 1
        with open(UPDATE_LOG, "a") as log:
            log.write(f"\n>>> Error: {e}\n")
    with _update_lock:
        UPDATE_STATE["running"] = False
        UPDATE_STATE["rc"] = rc


def api_system_update(_body):
    """Start a system update in the background."""
    with _update_lock:
        if UPDATE_STATE["running"]:
            return {"ok": False, "error": "Update already running"}
        UPDATE_STATE["running"] = True
        UPDATE_STATE["rc"] = None
        UPDATE_STATE["started"] = time.time()
    # Clear old log
    with open(UPDATE_LOG, "w") as f:
        f.write("Starting system update...\n")
    t = threading.Thread(target=_run_update, daemon=True)
    t.start()
    return {"ok": True, "status": "started"}


def api_update_status(_body):
    """Get current update progress (log output and running state)."""
    output = ""
    try:
        with open(UPDATE_LOG) as f:
            output = f.read()
    except FileNotFoundError:
        pass
    with _update_lock:
        running = UPDATE_STATE["running"]
        rc = UPDATE_STATE["rc"]
    return {"running": running, "rc": rc, "output": output}


def api_system_info(_body):
    """Get system information."""
    _, hostname, _ = run("hostname")
    _, uptime, _ = run("uptime -p")
    _, arch, _ = run("uname -m")
    _, kernel, _ = run("uname -r")
    _, distro, _ = run("lsb_release -ds 2>/dev/null || cat /etc/os-release | head -1")
    _, mem, _ = run("free -h | awk '/^Mem:/ {print $2}'")
    _, mem_used, _ = run("free -h | awk '/^Mem:/ {print $3}'")
    _, cpu_temp, _ = run("cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null")
    temp = ""
    if cpu_temp and cpu_temp.isdigit():
        temp = f"{int(cpu_temp) / 1000:.1f}"

    return {
        "hostname": hostname,
        "uptime": uptime,
        "arch": arch,
        "kernel": kernel,
        "distro": distro,
        "memory": f"{mem_used} / {mem}",
        "cpu_temp": temp
    }


def api_reboot(_body):
    """Reboot the system."""
    run("systemctl reboot")
    return {"ok": True}


# --- Route table ---
ROUTES = {
    ("GET", "/api/dacs"): api_dacs,
    ("POST", "/api/dacs"): api_set_dac,
    ("GET", "/api/services"): api_services,
    ("POST", "/api/services"): api_service_toggle,
    ("GET", "/api/network"): api_network,
    ("POST", "/api/hostname"): api_set_hostname,
    ("GET", "/api/wifi/scan"): api_wifi_scan,
    ("POST", "/api/wifi/connect"): api_wifi_connect,
    ("POST", "/api/wifi/disconnect"): api_wifi_disconnect,
    ("POST", "/api/network/static"): api_set_static_ip,
    ("POST", "/api/network/dhcp"): api_set_dhcp,
    ("POST", "/api/system/update"): api_system_update,
    ("GET", "/api/system/update"): api_update_status,
    ("GET", "/api/system"): api_system_info,
    ("POST", "/api/system/reboot"): api_reboot,
}


class CeolHandler(http.server.SimpleHTTPRequestHandler):
    """HTTP request handler for Ceòl Stream web UI."""

    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(WEB_DIR), **kwargs)

    def do_GET(self):
        handler = ROUTES.get(("GET", self.path))
        if handler:
            self._json_response(handler(None))
        elif self.path == "/" or not self.path.startswith("/api/"):
            # Serve static files, default to index.html
            if self.path == "/":
                self.path = "/index.html"
            super().do_GET()
        else:
            self._json_response({"error": "Not found"}, 404)

    def do_POST(self):
        handler = ROUTES.get(("POST", self.path))
        if handler:
            body = self._read_body()
            self._json_response(handler(body))
        else:
            self._json_response({"error": "Not found"}, 404)

    def _read_body(self):
        length = int(self.headers.get("Content-Length", 0))
        if length:
            try:
                return json.loads(self.rfile.read(length))
            except json.JSONDecodeError:
                return {}
        return {}

    def _json_response(self, data, code=200):
        body = json.dumps(data).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", len(body))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        """Suppress default logging to stderr."""
        pass


def main():
    port = int(os.environ.get("CEOL_PORT", 8484))
    server = http.server.HTTPServer(("0.0.0.0", port), CeolHandler)
    print(f"Ceòl Stream web UI running on http://0.0.0.0:{port}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down.")
        server.shutdown()


if __name__ == "__main__":
    main()
