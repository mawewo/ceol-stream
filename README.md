# Ceòl Stream

**Audiophile music streamer for Debian Linux.**

Part of the [Ceòl project](https://ceol-music.org) — open source audiophile music streaming and serving.

Ceòl (Gaelic for "music") Stream turns a headless Debian system into a high-quality network audio renderer with support for Roon, HQPlayer, AirPlay, and UPnP/DLNA — all playing through a USB DAC with bit-perfect signal integrity.

## Features

- **Roon Bridge** — Endpoint renderer for Roon (RAAT protocol)
- **HQPlayer NAA** — Network Audio Adapter for HQPlayer
- **AirPlay (Shairport Sync)** — AirPlay 1 (classic) receiver, truly lossless (16-bit/44.1kHz ALAC)
- **UPnP/DLNA (gmediarender)** — UPnP/DLNA renderer for hi-res streaming (up to 24-bit/192kHz)
- **Seamless switching** — Switch between sources without restarting anything
- **Bit-perfect playback** — No resampling, no mixing, no software volume
- **Web UI** — Configure DAC, services, network, and system from a browser
- **Lightweight** — Minimal resource footprint, runs on Raspberry Pi and similar SBCs

## Supported Platforms

- **Architecture:** arm64 (aarch64) and amd64 (x86_64)
- **OS:** Debian 12 (bookworm) and newer, including derivatives (Ubuntu, Raspberry Pi OS, etc.)

## Quick Start

```sh
git clone https://github.com/youruser/ceol-stream.git
cd ceol-stream
chmod +x ceol-stream-setup.sh
sudo ./ceol-stream-setup.sh
```

The script will ask which services to install and guide you through the setup.

After installation, open the web UI at `http://<device-ip>:8484`.

## How It Works

### Signal Path

```
Source (Roon / HQPlayer / AirPlay / UPnP)
  |
  | Network (TCP/IP)
  | Protocol: RAAT / NAA / RTSP+ALAC / UPnP-AV
  v
Renderer (Roon Bridge / networkaudiod / Shairport Sync / gmediarender)
  |
  | ALSA hw:X,Y (exclusive, direct hardware access)
  | No dmix. No resampling. No software volume.
  v
USB DAC (bit-perfect output)
```

### Seamless Source Switching

All streaming services run simultaneously as system services. Each is configured to output directly to the ALSA hardware device (`hw:X,Y`). ALSA operates in **exclusive access mode** — only one service can hold the device at a time.

When you pause or stop playback in one app (e.g., Roon), the service releases the ALSA device immediately. You can then start playing from another app (e.g., AirPlay) and it will grab the DAC instantly. No restart, no configuration change, no clicking in the web UI.

This is by design: exclusive access means zero mixing, zero resampling, and zero signal degradation.

### Why Exclusive Access (No dmix)?

The default ALSA `dmix` plugin allows multiple applications to share an audio device by:
1. Resampling all streams to a common sample rate
2. Mixing them together in software
3. Applying software volume control

For audiophile use, this is unacceptable — it alters the original signal. Ceòl Stream bypasses dmix entirely:

| Feature | dmix (default ALSA) | Ceòl Stream (hw:) |
|---------|--------------------|--------------------|
| Resampling | Yes (to common rate) | No |
| Mixing | Yes | No (exclusive access) |
| Software volume | Yes | No |
| Bit-perfect | No | Yes |
| Multiple simultaneous streams | Yes | No (one at a time) |
| Signal integrity | Degraded | Pristine |

### Supported Formats

| Format | Roon Bridge | HQPlayer NAA | AirPlay (Shairport) | UPnP/DLNA |
|--------|-------------|--------------|---------------------|-----------|
| 16-bit / 44.1 kHz | Yes | Yes | Yes | Yes |
| 16-bit / 48 kHz | Yes | Yes | No | Yes |
| 24-bit / 96 kHz | Yes | Yes | No | Yes |
| 24-bit / 192 kHz | Yes | Yes | No | Yes |
| DSD (DoP) | Yes | Yes | No | No |

*Ceòl Stream uses AirPlay 1 (classic) deliberately. AirPlay 1 streams truly lossless ALAC at 16-bit / 44.1 kHz (CD quality). AirPlay 2, despite Apple's marketing, uses lossy AAC transcoding in many scenarios — unacceptable for audiophile use.

## Web UI

The web UI runs on port **8484** and provides:

- **Services** — Enable/disable/restart Roon Bridge, HQPlayer NAA, AirPlay, UPnP/DLNA
- **Audio** — Select USB DAC, view signal path diagram
- **Network** — Set hostname, configure Wi-Fi, set static IP or DHCP
- **System** — View system info, run OS updates, reboot

## File Locations

| Path | Description |
|------|-------------|
| `/opt/ceol-stream/web/` | Web UI files |
| `/opt/RoonBridge/` | Roon Bridge installation |
| `/etc/ceol-stream/config.json` | Ceòl Stream configuration |
| `/etc/asound.conf` | ALSA configuration (managed by web UI) |
| `/etc/shairport-sync.conf` | Shairport Sync configuration |
| `/etc/systemd/system/ceol-stream-web.service` | Web UI service |
| `/etc/systemd/system/roonbridge.service` | Roon Bridge service |
| `/etc/systemd/system/shairport-sync.service` | Shairport Sync service |
| `/etc/systemd/system/gmediarender.service` | UPnP/DLNA renderer service |

## Service Management

```sh
# Check status of all services
systemctl status roonbridge shairport-sync networkaudiod gmediarender ceol-stream-web

# Restart a service
sudo systemctl restart shairport-sync

# View logs
journalctl -u shairport-sync -f
```

## OS Updates

System updates can be triggered from the web UI (System tab) or manually:

```sh
sudo apt-get update && sudo apt-get upgrade -y
```

The streaming services are installed independently of system packages (Roon Bridge and NAA are standalone binaries, Shairport Sync is built from source to `/usr/local`), so standard `apt upgrade` will not break them.

## Disclaimer

This project downloads and installs the following proprietary software at setup time:

- **Roon Bridge** by [Roon Labs](https://roonlabs.com/) — requires a Roon subscription
- **networkaudiod (HQPlayer NAA)** by [Signalyst](https://www.signalyst.com/) — requires HQPlayer running on a separate machine

These binaries are downloaded directly from their official sources. This project does not redistribute any proprietary software. All other components (Shairport Sync, the web UI, the setup script) are open source.

## License

MIT — see the script header for details. Proprietary components (Roon Bridge, networkaudiod) are subject to their respective licenses.

---

Ceòl Stream is part of the [Ceòl project](https://ceol-music.org) — *ceòl* is the Gaelic word for music.
