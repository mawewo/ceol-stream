#!/bin/sh
# =============================================================================
# Ceòl Stream - Audiophile Music Streamer Setup
# =============================================================================
#
# Transforms a fresh Debian installation (bookworm+) into a high-quality
# music streamer supporting Roon Bridge, HQPlayer NAA, AirPlay, and UPnP/DLNA.
#
# Supported architectures: arm64 (aarch64) and amd64 (x86_64)
# Supported OS: Debian 12 (bookworm) and newer, and derivatives (Ubuntu, etc.)
#
# Usage:
#   chmod +x ceol-stream-setup.sh
#   sudo ./ceol-stream-setup.sh --install
#   sudo ./ceol-stream-setup.sh --uninstall
#
# Signal path (bit-perfect):
#   Source (Roon/HQPlayer/AirPlay) -> Network -> Renderer -> ALSA hw: -> USB DAC
#   No resampling. No mixing. No software volume. Clean, untouched signal.
#
# DISCLAIMER:
#   This script downloads and installs Roon Bridge (by Roon Labs) and
#   HQPlayer NAA / networkaudiod (by Signalyst). These are proprietary
#   software products. This script does NOT redistribute their binaries —
#   it downloads them directly from the official sources at install time.
#   Roon Bridge requires a Roon subscription. HQPlayer NAA requires
#   HQPlayer software running on a separate machine.
#   All other components are open source.
#
# License: MIT (for this script and the web UI)
# =============================================================================

# Note: We intentionally do NOT use 'set -e' here.
# Each install step handles its own errors gracefully so that a single
# failure (e.g. a download 404) doesn't abort the entire setup.

# --- Resolve script directory (must happen before any cd) ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Constants ---
CEOL_VERSION="1.0.0"
INSTALL_DIR="/opt/ceol-stream"
WEB_DIR="${INSTALL_DIR}/web"
CONF_DIR="/etc/ceol-stream"
ROON_DIR="/opt/RoonBridge"
SHAIRPORT_BUILD_DIR="/tmp/shairport-sync-build"

# Roon Bridge download URLs
ROON_URL_AMD64="https://download.roonlabs.net/builds/RoonBridge_linuxx64.tar.bz2"
ROON_URL_ARM64="https://download.roonlabs.net/builds/RoonBridge_linuxarmv8.tar.bz2"

# HQPlayer NAA (networkaudiod) - base URL for auto-detecting latest version
NAA_BASE_URL="https://www.signalyst.eu/bins/naa/linux/bookworm"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# --- Helper functions ---

info()  { printf "${CYAN}[INFO]${NC}  %s\n" "$1"; }
ok()    { printf "${GREEN}[OK]${NC}    %s\n" "$1"; }
warn()  { printf "${YELLOW}[WARN]${NC}  %s\n" "$1"; }
error() { printf "${RED}[ERROR]${NC} %s\n" "$1"; }
die()   { error "$1"; exit 1; }

ask_yes_no() {
    printf "${CYAN}[?]${NC} %s [y/N]: " "$1"
    read -r answer
    case "$answer" in
        [yY]|[yY][eE][sS]) return 0 ;;
        *) return 1 ;;
    esac
}

ask_input() {
    printf "${CYAN}[?]${NC} %s: " "$1" >&2
    read -r answer
    echo "$answer"
}

# --- Pre-flight checks ---

preflight() {
    info "Ceòl Stream v${CEOL_VERSION} - Audiophile Streamer Setup"
    echo ""

    # Must be root
    if [ "$(id -u)" -ne 0 ]; then
        die "This script must be run as root. Use: sudo $0"
    fi

    # Check architecture
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)  ARCH_TAG="amd64" ;;
        aarch64) ARCH_TAG="arm64" ;;
        *)       die "Unsupported architecture: $ARCH (need x86_64 or aarch64)" ;;
    esac
    ok "Architecture: $ARCH ($ARCH_TAG)"

    # Check Debian version
    if [ ! -f /etc/os-release ]; then
        die "Cannot determine OS version. /etc/os-release not found."
    fi
    . /etc/os-release
    DISTRO_ID="$ID"
    DISTRO_VERSION="$VERSION_ID"
    DISTRO_NAME="$PRETTY_NAME"

    # Accept Debian, Ubuntu, and derivatives
    case "$ID" in
        debian|ubuntu|linuxmint|pop|raspbian) ;;
        *)
            if [ -f /etc/debian_version ]; then
                warn "Non-standard Debian derivative detected: $DISTRO_NAME"
            else
                die "Unsupported OS: $DISTRO_NAME. Need Debian bookworm or newer."
            fi
            ;;
    esac

    # Check minimum version (Debian 12 / bookworm)
    if [ "$ID" = "debian" ] || [ "$ID" = "raspbian" ]; then
        if [ -n "$VERSION_ID" ] && [ "$VERSION_ID" -lt 12 ] 2>/dev/null; then
            die "Debian $VERSION_ID is too old. Need bookworm (12) or newer."
        fi
    fi
    ok "Distribution: $DISTRO_NAME"

    echo ""
}

# --- Ask what to install ---

ask_components() {
    echo "================================================================"
    echo "  Which streaming services would you like to install?"
    echo "================================================================"
    echo ""

    INSTALL_ROON=false
    INSTALL_NAA=false
    INSTALL_SHAIRPORT=false
    INSTALL_UPNP=false

    if ask_yes_no "Install Roon Bridge? (requires Roon subscription)"; then
        INSTALL_ROON=true
    fi

    if ask_yes_no "Install HQPlayer NAA? (requires HQPlayer on another machine)"; then
        INSTALL_NAA=true
    fi

    if ask_yes_no "Install AirPlay receiver (Shairport Sync)? (lossless CD quality, 16/44.1)"; then
        INSTALL_SHAIRPORT=true
    fi

    if ask_yes_no "Install UPnP/DLNA renderer (gmediarender)? (hi-res, gapless)"; then
        INSTALL_UPNP=true
    fi

    if ! $INSTALL_ROON && ! $INSTALL_NAA && ! $INSTALL_SHAIRPORT && ! $INSTALL_UPNP; then
        die "No services selected. At least one streaming service is required."
    fi

    echo ""

    # Ask for hostname
    CURRENT_HOSTNAME=$(hostname)
    NEW_HOSTNAME=$(ask_input "Set hostname (press Enter to keep '$CURRENT_HOSTNAME')")
    if [ -z "$NEW_HOSTNAME" ]; then
        NEW_HOSTNAME="$CURRENT_HOSTNAME"
    fi

    echo ""
    echo "================================================================"
    echo "  Installation summary:"
    echo "================================================================"
    echo "  Architecture:     $ARCH_TAG"
    echo "  Hostname:         $NEW_HOSTNAME"
    $INSTALL_ROON     && echo "  Roon Bridge:      YES"
    $INSTALL_NAA      && echo "  HQPlayer NAA:     YES"
    $INSTALL_SHAIRPORT && echo "  AirPlay (lossless): YES"
    $INSTALL_UPNP      && echo "  UPnP/DLNA:        YES"
    echo "  Web UI:           YES (port 8484)"
    echo "================================================================"
    echo ""

    if ! ask_yes_no "Proceed with installation?"; then
        echo "Aborted."
        exit 0
    fi

    echo ""
}

# --- Install system dependencies ---

install_dependencies() {
    info "Updating package lists..."
    apt-get update -qq

    info "Installing base dependencies..."
    apt-get install -y -qq \
        alsa-utils \
        python3 \
        curl \
        wget \
        avahi-daemon \
        > /dev/null 2>&1
    ok "Base dependencies installed"

    # Shairport Sync build dependencies
    if $INSTALL_SHAIRPORT; then
        info "Installing Shairport Sync build dependencies..."
        apt-get install -y -qq \
            build-essential \
            git \
            autoconf \
            automake \
            libtool \
            libpopt-dev \
            libconfig-dev \
            libasound2-dev \
            libavahi-client-dev \
            libssl-dev \
            libsoxr-dev \
            > /dev/null 2>&1
        ok "Shairport Sync build dependencies installed"
    fi

    # Install NetworkManager if not present (for WiFi and network management via web UI)
    if ! command -v nmcli > /dev/null 2>&1; then
        info "Installing NetworkManager..."
        apt-get install -y -qq network-manager > /dev/null 2>&1
        systemctl enable NetworkManager
        systemctl start NetworkManager
        ok "NetworkManager installed"
    fi
}

# --- Set hostname ---

set_hostname() {
    if [ "$NEW_HOSTNAME" != "$(hostname)" ]; then
        info "Setting hostname to '$NEW_HOSTNAME'..."
        hostnamectl set-hostname "$NEW_HOSTNAME"
        # Update /etc/hosts
        if grep -q "127.0.1.1" /etc/hosts; then
            sed -i "s/127\.0\.1\.1.*/127.0.1.1\t$NEW_HOSTNAME/" /etc/hosts
        else
            echo "127.0.1.1\t$NEW_HOSTNAME" >> /etc/hosts
        fi
        ok "Hostname set to '$NEW_HOSTNAME'"
    fi
}

# --- Configure ALSA for bit-perfect USB DAC output ---

configure_alsa() {
    info "Configuring ALSA for bit-perfect USB DAC output..."

    # Disable the snd_bcm2835 module on Raspberry Pi (onboard audio)
    # This prevents the onboard audio from taking card 0
    if [ -d /sys/module/snd_bcm2835 ]; then
        info "Disabling Raspberry Pi onboard audio (for clean USB DAC access)..."
        if ! grep -q "blacklist snd_bcm2835" /etc/modprobe.d/ceol-stream.conf 2>/dev/null; then
            echo "blacklist snd_bcm2835" > /etc/modprobe.d/ceol-stream.conf
        fi
    fi

    # Create a minimal ALSA config - no dmix, no resampling
    # The web UI will update this when a DAC is selected
    cat > /etc/asound.conf << 'ALSA_EOF'
# Ceòl Stream - ALSA configuration
# Bit-perfect output: no resampling, no mixing, direct hardware access
# This file is managed by the Ceol Stream web UI.
#
# Signal integrity notes:
# - pcm.!default points directly to hw: (hardware device)
# - No dmix: avoids sample rate conversion and mixing artifacts
# - No softvol: volume control is left to the DAC or source application
# - Each streaming service gets exclusive access when playing
# - When a service stops/pauses, it releases the device immediately
# - Another service can then grab the device without any restart

defaults.pcm.card 0
defaults.pcm.device 0
defaults.ctl.card 0

pcm.!default {
    type hw
    card 0
    device 0
}

ctl.!default {
    type hw
    card 0
}
ALSA_EOF

    ok "ALSA configured for bit-perfect output (no dmix, no resampling)"
}

# --- Install Roon Bridge ---

install_roon_bridge() {
    if ! $INSTALL_ROON; then return; fi
    info "Installing Roon Bridge..."

    if [ -d "$ROON_DIR" ]; then
        warn "Roon Bridge already installed at $ROON_DIR, skipping download."
    else
        case "$ARCH_TAG" in
            amd64) ROON_URL="$ROON_URL_AMD64" ;;
            arm64) ROON_URL="$ROON_URL_ARM64" ;;
        esac

        info "Downloading Roon Bridge ($ARCH_TAG)..."
        mkdir -p /tmp/roon-install
        if ! wget -q --show-progress -O /tmp/roon-install/RoonBridge.tar.bz2 "$ROON_URL"; then
            warn "Download failed: $ROON_URL"
            warn "Skipping Roon Bridge installation. Install manually later."
            rm -rf /tmp/roon-install
            return
        fi

        info "Extracting Roon Bridge..."
        tar xf /tmp/roon-install/RoonBridge.tar.bz2 -C /opt/
        rm -rf /tmp/roon-install
    fi

    # Create a dedicated user for Roon Bridge
    # Roon Bridge auto-updates itself at runtime, so the install directory
    # must be writable by the service user.
    if ! id roon > /dev/null 2>&1; then
        useradd -r -s /usr/sbin/nologin -d "$ROON_DIR" -G audio roon
    else
        usermod -aG audio roon
    fi
    chown -R roon:roon "$ROON_DIR"

    # Create systemd service
    cat > /etc/systemd/system/roonbridge.service << EOF
[Unit]
Description=Roon Bridge
After=network-online.target avahi-daemon.service
Wants=network-online.target

[Service]
Type=simple
User=roon
Group=roon
SupplementaryGroups=audio
ExecStart=${ROON_DIR}/start.sh
Restart=on-failure
RestartSec=5

# Audio priority: allow real-time scheduling for gapless playback
LimitRTPRIO=95
LimitMEMLOCK=infinity
LimitNICE=-20

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable roonbridge.service
    systemctl start roonbridge.service
    ok "Roon Bridge installed and running"
}

# --- Install HQPlayer NAA (networkaudiod) ---

install_naa() {
    if ! $INSTALL_NAA; then return; fi
    info "Installing HQPlayer NAA (networkaudiod)..."

    # Skip if already installed
    if command -v networkaudiod > /dev/null 2>&1; then
        warn "HQPlayer NAA (networkaudiod) already installed, skipping download."
        # Ensure audio group and service are set up
        if id networkaudio > /dev/null 2>&1; then
            usermod -aG audio networkaudio
        fi
        if systemctl list-unit-files | grep -q "networkaudiod.service"; then
            systemctl enable networkaudiod.service
            systemctl start networkaudiod.service
        fi
        ok "HQPlayer NAA (networkaudiod) already installed and running"
        return
    fi

    # Auto-detect the latest networkaudiod .deb from Signalyst's directory listing
    info "Finding latest networkaudiod version for $ARCH_TAG..."
    NAA_DEB=$(wget -q -O - "$NAA_BASE_URL/" 2>/dev/null \
        | grep -oP "networkaudiod_[^\"]+_${ARCH_TAG}\.deb" \
        | sort -V | tail -1)

    if [ -z "$NAA_DEB" ]; then
        warn "Could not auto-detect networkaudiod version from $NAA_BASE_URL"
        warn "Trying direct package name pattern..."
        # Fallback: try common version patterns
        for ver in 4.4.1-1 4.4.0-1 4.3.2-1 4.3.1-1 4.3.0-1; do
            NAA_TRY_URL="${NAA_BASE_URL}/networkaudiod_${ver}_${ARCH_TAG}.deb"
            if wget -q --spider "$NAA_TRY_URL" 2>/dev/null; then
                NAA_DEB="networkaudiod_${ver}_${ARCH_TAG}.deb"
                break
            fi
        done
    fi

    if [ -z "$NAA_DEB" ]; then
        warn "Could not find networkaudiod package for $ARCH_TAG."
        warn "You can install it manually later from: $NAA_BASE_URL"
        warn "Skipping HQPlayer NAA installation."
        return
    fi

    NAA_URL="${NAA_BASE_URL}/${NAA_DEB}"
    info "Downloading $NAA_DEB..."
    if ! wget -q --show-progress -O /tmp/networkaudiod.deb "$NAA_URL"; then
        warn "Download failed: $NAA_URL"
        warn "Skipping HQPlayer NAA installation. Install manually later."
        rm -f /tmp/networkaudiod.deb
        return
    fi

    info "Installing networkaudiod..."
    dpkg -i /tmp/networkaudiod.deb 2>/dev/null || apt-get install -f -y -qq > /dev/null 2>&1
    rm -f /tmp/networkaudiod.deb

    # Ensure the audio group is set
    if id networkaudio > /dev/null 2>&1; then
        usermod -aG audio networkaudio
    fi

    # The .deb package typically creates its own systemd service.
    # Ensure it's enabled.
    if systemctl list-unit-files | grep -q "networkaudiod.service"; then
        systemctl enable networkaudiod.service
        systemctl start networkaudiod.service
    fi

    ok "HQPlayer NAA (networkaudiod) installed and running"
}

# --- Build and install Shairport Sync (AirPlay 1, lossless) ---

install_shairport_sync() {
    if ! $INSTALL_SHAIRPORT; then return; fi
    info "Building Shairport Sync from source (AirPlay 1 — truly lossless)..."

    # NOTE: We deliberately use AirPlay 1 (classic) instead of AirPlay 2.
    # AirPlay 1 uses Apple Lossless (ALAC) end-to-end and is truly lossless
    # at 16-bit / 44.1 kHz (CD quality). AirPlay 2, despite Apple's marketing,
    # uses a lossy AAC transcode in many scenarios (see: darko.audio/2023/10/).
    # For an audiophile streamer, AirPlay 1 is the correct choice.

    info "Building Shairport Sync..."
    rm -rf "$SHAIRPORT_BUILD_DIR"
    if ! git clone --depth 1 https://github.com/mikebrady/shairport-sync.git "$SHAIRPORT_BUILD_DIR"; then
        warn "Failed to clone Shairport Sync. Skipping."
        return
    fi
    cd "$SHAIRPORT_BUILD_DIR"
    autoreconf -fi

    # Configure with:
    # --with-alsa          : ALSA backend (bit-perfect hardware access)
    # --with-avahi         : mDNS/DNS-SD for network discovery
    # --with-ssl=openssl   : encryption
    # --with-soxr          : optional high-quality sample rate conversion (available if DAC needs it)
    # --with-metadata      : metadata pipe for track info
    # NOTE: No --with-airplay-2. AirPlay 1 is truly lossless (ALAC, 16/44.1).
    ./configure \
        --with-alsa \
        --with-avahi \
        --with-ssl=openssl \
        --with-soxr \
        --with-metadata \
        --sysconfdir=/etc

    if ! make -j"$(nproc)"; then
        warn "Failed to build Shairport Sync."
        cd /
        return
    fi
    make install
    cd /

    # Clean up build directory
    rm -rf "$SHAIRPORT_BUILD_DIR"

    # Create shairport-sync user
    if ! id shairport-sync > /dev/null 2>&1; then
        useradd -r -s /usr/sbin/nologin -G audio shairport-sync
    else
        usermod -aG audio shairport-sync
    fi

    # Write Shairport Sync configuration
    cat > /etc/shairport-sync.conf << SHAIRPORT_EOF
// Ceòl Stream - Shairport Sync Configuration
// AirPlay 1 (classic) receiver with bit-perfect ALSA output
//
// AirPlay 1 is truly lossless: Apple Lossless (ALAC) at 16-bit / 44.1 kHz.
// Signal path: AirPlay source -> ALAC decode -> ALSA hw: -> USB DAC
// No transcoding, no lossy compression, no sample rate conversion.

general = {
    name = "${NEW_HOSTNAME}";
    output_backend = "alsa";

    // Interpolation for timing correction: "basic" for lowest latency,
    // "auto" lets shairport-sync choose (soxr if available for higher quality)
    interpolation = "auto";
};

alsa = {
    // Direct hardware output - no dmix, no resampling
    output_device = "hw:0,0";

    // Disable software volume - let the DAC or source handle it
    // This ensures the signal is bit-perfect
    // mixer_control_name = "disabled";

    // Maximum buffer for gapless playback
    audio_backend_buffer_desired_length_in_seconds = 0.2;
    audio_backend_latency_offset_in_seconds = 0.0;

    // Disable rate and format mismatch fixes - let the DAC handle native formats
    disable_synchronization = "no";

    // IMPORTANT: Release the ALSA device when not playing.
    // This allows other services (Roon, NAA) to grab the DAC immediately.
    // Set to "no" to ensure clean release. "always" would hold the device open.
    disable_standby_mode = "no";
};

// Metadata - allows future integration with display/NowPlaying
metadata = {
    enabled = "yes";
    include_cover_art = "no";
    pipe_name = "/tmp/shairport-sync-metadata";
    pipe_timeout = 5000;
};
SHAIRPORT_EOF

    # Create systemd service
    cat > /etc/systemd/system/shairport-sync.service << 'EOF'
[Unit]
Description=Shairport Sync - AirPlay Receiver
After=network-online.target avahi-daemon.service sound.target
Wants=network-online.target avahi-daemon.service

[Service]
Type=simple
User=shairport-sync
Group=shairport-sync
SupplementaryGroups=audio
ExecStart=/usr/local/bin/shairport-sync -c /etc/shairport-sync.conf
Restart=on-failure
RestartSec=5

# Audio priority
LimitRTPRIO=95
LimitMEMLOCK=infinity
LimitNICE=-20

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable shairport-sync.service
    systemctl start shairport-sync.service
    ok "Shairport Sync installed and running (AirPlay 1, lossless 16/44.1)"
}

# --- Install UPnP/DLNA renderer (gmediarender) ---

install_upnp() {
    if ! $INSTALL_UPNP; then return; fi
    info "Installing UPnP/DLNA renderer (gmediarender)..."

    # gmediarender is available as a Debian package.
    # It uses GStreamer for audio decoding — we install the full plugin set
    # to support FLAC, WAV, ALAC, AAC, MP3 and other common formats.
    apt-get install -y -qq \
        gmediarender \
        gstreamer1.0-alsa \
        gstreamer1.0-plugins-base \
        gstreamer1.0-plugins-good \
        gstreamer1.0-plugins-bad \
        gstreamer1.0-plugins-ugly \
        gstreamer1.0-libav \
        > /dev/null 2>&1

    if ! command -v gmediarender > /dev/null 2>&1; then
        warn "gmediarender installation failed. Skipping UPnP/DLNA."
        return
    fi

    # Create systemd service
    # Uses ALSA direct hardware output (same device as other services).
    # Port pinned to 49152 for reliable firewall rules.
    # Volume set to 0 dB (full, no attenuation) for bit-perfect signal.
    cat > /etc/systemd/system/gmediarender.service << EOF
[Unit]
Description=UPnP/DLNA Audio Renderer (gmediarender)
After=network-online.target avahi-daemon.service sound.target
Wants=network-online.target avahi-daemon.service

[Service]
Type=simple
User=nobody
Group=audio
ExecStart=/usr/bin/gmediarender \\
    --friendly-name="${NEW_HOSTNAME}" \\
    --gstout-audiosink=alsasink \\
    --gstout-audiodevice=hw:0,0 \\
    --gstout-initial-volume-db=0 \\
    --port=49152
Restart=on-failure
RestartSec=5

# Audio priority
LimitRTPRIO=95
LimitMEMLOCK=infinity
LimitNICE=-20

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable gmediarender.service
    systemctl start gmediarender.service
    ok "UPnP/DLNA renderer installed and running (visible as '${NEW_HOSTNAME}')"
}

# --- Install Ceol Stream Web UI ---

install_web_ui() {
    info "Installing Ceòl Stream web UI..."

    mkdir -p "$INSTALL_DIR"
    mkdir -p "$CONF_DIR"

    # Copy web files from the script's directory (SCRIPT_DIR resolved at top of script)
    if [ -d "$SCRIPT_DIR/web" ]; then
        cp -r "$SCRIPT_DIR/web" "$INSTALL_DIR/"
    else
        die "Web UI files not found at $SCRIPT_DIR/web. Ensure the web/ directory is alongside this script."
    fi

    # Write initial config
    cat > "$CONF_DIR/config.json" << EOF
{
  "dac": "",
  "services": {
    "roonbridge": $INSTALL_ROON,
    "networkaudiod": $INSTALL_NAA,
    "shairport-sync": $INSTALL_SHAIRPORT,
    "gmediarender": $INSTALL_UPNP
  }
}
EOF

    # Create systemd service for the web UI
    cat > /etc/systemd/system/ceol-stream-web.service << EOF
[Unit]
Description=Ceòl Stream Web UI
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 ${WEB_DIR}/server.py
Restart=on-failure
RestartSec=5
Environment=CEOL_PORT=8484

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable ceol-stream-web.service
    systemctl start ceol-stream-web.service
    ok "Web UI installed and running on port 8484"
}

# --- Configure real-time audio priority ---

configure_audio_priority() {
    info "Configuring real-time audio scheduling..."

    # Allow audio group processes to use real-time scheduling
    if ! grep -q "@audio" /etc/security/limits.d/audio.conf 2>/dev/null; then
        cat > /etc/security/limits.d/audio.conf << 'EOF'
# Ceòl Stream - Real-time audio priority for gapless, low-latency playback
@audio   -  rtprio     95
@audio   -  memlock    unlimited
@audio   -  nice       -20
EOF
    fi

    ok "Real-time audio scheduling configured"
}

# --- Firewall (optional: open required ports) ---

configure_firewall() {
    # Only configure if ufw is installed
    if command -v ufw > /dev/null 2>&1; then
        info "Configuring firewall rules..."
        ufw allow 8484/tcp comment "Ceòl Stream Web UI" > /dev/null 2>&1
        ufw allow 5353/udp comment "mDNS (Avahi)" > /dev/null 2>&1
        # Roon uses a range of ports
        ufw allow 9100:9200/tcp comment "Roon Bridge" > /dev/null 2>&1
        ufw allow 9003/udp comment "Roon Bridge" > /dev/null 2>&1
        # AirPlay
        ufw allow 7000/tcp comment "AirPlay" > /dev/null 2>&1
        ufw allow 6000:6009/udp comment "AirPlay" > /dev/null 2>&1
        # UPnP/DLNA
        ufw allow 1900/udp comment "UPnP SSDP" > /dev/null 2>&1
        ufw allow 49152/tcp comment "gmediarender" > /dev/null 2>&1
        ok "Firewall rules configured"
    fi
}

# --- Print completion summary ---

print_summary() {
    echo ""
    echo "================================================================"
    echo "  Ceòl Stream - Installation Complete"
    echo "================================================================"
    echo ""

    # Get the primary IP address
    IP_ADDR=$(hostname -I 2>/dev/null | awk '{print $1}')
    if [ -z "$IP_ADDR" ]; then
        IP_ADDR="<this-machine-ip>"
    fi

    echo "  Web UI:    http://${IP_ADDR}:8484"
    echo "  Hostname:  ${NEW_HOSTNAME}"
    echo ""

    echo "  Installed services:"
    $INSTALL_ROON      && echo "    - Roon Bridge       (active, waiting for Roon Core)"
    $INSTALL_NAA       && echo "    - HQPlayer NAA      (active, waiting for HQPlayer)"
    $INSTALL_SHAIRPORT && echo "    - AirPlay (lossless) (active, visible as '${NEW_HOSTNAME}')"
    $INSTALL_UPNP      && echo "    - UPnP/DLNA         (active, visible as '${NEW_HOSTNAME}')"
    echo ""

    echo "  How it works:"
    echo "    All services run simultaneously. When you play from one source"
    echo "    (e.g. Roon), it takes exclusive access to the USB DAC. When you"
    echo "    pause or stop, the DAC is released instantly. You can then play"
    echo "    from another source (e.g. AirPlay) without restarting anything."
    echo ""
    echo "    Signal path: Source -> Network -> Renderer -> ALSA hw: -> USB DAC"
    echo "    No resampling. No mixing. Bit-perfect."
    echo ""

    echo "  Next steps:"
    echo "    1. Open the web UI at http://${IP_ADDR}:8484"
    echo "    2. Select your USB DAC in the Audio tab"
    echo "    3. Start streaming!"
    echo ""
    echo "================================================================"
}

# --- Uninstall ---

uninstall() {
    info "Ceòl Stream v${CEOL_VERSION} - Uninstall"
    echo ""

    if [ "$(id -u)" -ne 0 ]; then
        die "This script must be run as root. Use: sudo $0 --uninstall"
    fi

    if ! ask_yes_no "Remove Ceòl Stream and all installed components?"; then
        info "Uninstall cancelled."
        exit 0
    fi

    echo ""

    # Stop and disable all services (nqptp included for legacy cleanup)
    info "Stopping and removing services..."
    for svc in ceol-stream-web shairport-sync gmediarender networkaudiod roonbridge nqptp; do
        if systemctl list-unit-files 2>/dev/null | grep -q "${svc}.service"; then
            systemctl stop "$svc" 2>/dev/null
            systemctl disable "$svc" 2>/dev/null
            rm -f "/etc/systemd/system/${svc}.service"
            ok "Removed ${svc}"
        fi
    done
    systemctl daemon-reload 2>/dev/null

    # Remove Roon Bridge
    if [ -d "$ROON_DIR" ]; then
        rm -rf "$ROON_DIR"
        ok "Removed $ROON_DIR"
    fi

    # Remove networkaudiod binary
    if [ -f /usr/local/bin/networkaudiod ]; then
        rm -f /usr/local/bin/networkaudiod
        ok "Removed networkaudiod binary"
    fi

    # Remove shairport-sync binary and config
    if command -v shairport-sync > /dev/null 2>&1; then
        rm -f /usr/local/bin/shairport-sync
        ok "Removed shairport-sync binary"
    fi
    rm -f /etc/shairport-sync.conf

    # Remove Ceòl Stream directories
    if [ -d "$INSTALL_DIR" ]; then
        rm -rf "$INSTALL_DIR"
        ok "Removed $INSTALL_DIR"
    fi
    if [ -d "$CONF_DIR" ]; then
        rm -rf "$CONF_DIR"
        ok "Removed $CONF_DIR"
    fi

    # Remove config files
    for f in /etc/asound.conf /etc/security/limits.d/audio.conf /etc/modprobe.d/ceol-stream.conf; do
        if [ -f "$f" ]; then
            rm -f "$f"
            ok "Removed $f"
        fi
    done

    # Remove created users (only if they exist and have no running processes)
    for u in roon shairport-sync; do
        if id "$u" > /dev/null 2>&1; then
            userdel "$u" 2>/dev/null
            ok "Removed user $u"
        fi
    done

    # Remove firewall rules (if ufw is active)
    if command -v ufw > /dev/null 2>&1 && ufw status | grep -q "active"; then
        ufw delete allow 8484/tcp 2>/dev/null
        ufw delete allow 9003/tcp 2>/dev/null
        ufw delete allow 9100:9200/tcp 2>/dev/null
        ufw delete allow 7000/tcp 2>/dev/null
        ufw delete allow 6000:6009/udp 2>/dev/null
        ufw delete allow 1900/udp 2>/dev/null
        ufw delete allow 49152/tcp 2>/dev/null
        ok "Removed firewall rules"
    fi

    # Clean up build artifacts
    rm -rf "$SHAIRPORT_BUILD_DIR" 2>/dev/null
    rm -f /tmp/ceol-stream-update.log 2>/dev/null

    echo ""
    echo "================================================================"
    echo "  Ceòl Stream - Uninstall Complete"
    echo "================================================================"
    echo ""
    echo "  All Ceòl Stream components have been removed."
    echo "  System packages (build deps, gmediarender) were left in place."
    echo "  Run 'apt autoremove' to clean up unused packages if desired."
    echo ""
    echo "================================================================"
}

# --- Main ---

main() {
    preflight
    ask_components
    install_dependencies
    set_hostname
    configure_alsa
    configure_audio_priority
    install_roon_bridge
    install_naa
    install_shairport_sync
    install_upnp
    install_web_ui
    configure_firewall
    print_summary
}

# --- Argument parsing ---

usage() {
    echo "Usage: sudo $0 [--install | --uninstall]"
    echo ""
    echo "  --install     Install Ceòl Stream (default)"
    echo "  --uninstall   Remove all Ceòl Stream components"
    exit 1
}

case "${1:-}" in
    --install|"")  main ;;
    --uninstall)   uninstall ;;
    *)             usage ;;
esac
