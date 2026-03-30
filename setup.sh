#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# piyano setup — turn a Raspberry Pi 5 into a headless Pianoteq instrument
# https://github.com/piyano/piyano
# =============================================================================

PIANOTEQ_INSTALL_DIR="/opt/pianoteq"
PIANOTEQ_USER="pianoteq"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${SCRIPT_DIR}/config"

# -----------------------------------------------------------------------------
# Output helpers
# -----------------------------------------------------------------------------

info() { printf '\033[1;34m[info]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
error() {
  printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2
  exit 1
}
success() { printf '\033[1;32m[ok]\033[0m %s\n' "$*"; }

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------

PIANOTEQ_ARCHIVE=""
WITH_TWEAKS=false
DISABLE_WIFI=false

usage() {
  cat <<USAGE
Usage: sudo ./setup.sh [OPTIONS]

Options:
  --pianoteq-archive PATH     Path to a Pianoteq archive (.7z/.tar.xz/.tar.gz/.zip)
  --with-tweaks               Apply CPU isolation tweaks (experimental)
  --disable-wifi              Disable wifi (only if using ethernet)
  -h, --help                  Show this help

USAGE
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pianoteq-archive)
      PIANOTEQ_ARCHIVE="${2:-}"
      [[ -z "${PIANOTEQ_ARCHIVE}" ]] && error "--pianoteq-archive requires a path"
      shift 2
      ;;
    --with-tweaks)
      WITH_TWEAKS=true
      shift
      ;;
    --disable-wifi)
      DISABLE_WIFI=true
      shift
      ;;
    -h | --help)
      usage
      ;;
    *)
      error "Unknown option: $1 (try --help)"
      ;;
  esac
done

# -----------------------------------------------------------------------------
# Preflight checks
# -----------------------------------------------------------------------------

[[ "$(id -u)" -eq 0 ]] || error "This script must be run as root (try: sudo ./setup.sh)"

REAL_USER="${SUDO_USER:-root}"
REAL_HOME=$(eval echo "~${REAL_USER}")

if [[ "$(uname -m)" != "aarch64" ]]; then
  error "This script requires a 64-bit ARM system (aarch64). Detected: $(uname -m)"
fi

if [[ -f /proc/device-tree/model ]]; then
  PI_MODEL=$(tr -d '\0' </proc/device-tree/model)
  info "Detected: ${PI_MODEL}"
  if [[ "${PI_MODEL}" != *"Raspberry Pi 5"* ]]; then
    warn "This script is designed for Raspberry Pi 5. Detected: ${PI_MODEL}"
    warn "Continuing anyway — things might get interesting."
  fi
else
  warn "Cannot detect Pi model (/proc/device-tree/model not found). Continuing anyway."
fi

CONFIG_TXT="/boot/firmware/config.txt"
if [[ ! -f "${CONFIG_TXT}" ]]; then
  CONFIG_TXT="/boot/config.txt"
  [[ -f "${CONFIG_TXT}" ]] || error "Cannot find config.txt in /boot/firmware/ or /boot/"
fi
info "Using config: ${CONFIG_TXT}"

# -----------------------------------------------------------------------------
# Helper: idempotent config.txt editing
# -----------------------------------------------------------------------------

config_set() {
  local key="$1" value="$2"
  if grep -q "^${key}=" "${CONFIG_TXT}" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${value}|" "${CONFIG_TXT}"
  elif grep -q "^#.*${key}=" "${CONFIG_TXT}" 2>/dev/null; then
    sed -i "s|^#.*${key}=.*|${key}=${value}|" "${CONFIG_TXT}"
  else
    echo "${key}=${value}" >>"${CONFIG_TXT}"
  fi
}

config_ensure_line() {
  local line="$1"
  grep -qxF "${line}" "${CONFIG_TXT}" 2>/dev/null || echo "${line}" >>"${CONFIG_TXT}"
}

# -----------------------------------------------------------------------------
# 1. Install dependencies
# -----------------------------------------------------------------------------

info "Installing dependencies..."
apt-get update -qq
apt-get install -y -qq \
  alsa-utils curl p7zip-full xz-utils \
  libfreetype6 libfontconfig1 libgl1 libx11-6 libxext6 libxi6 libxkbcommon0 \
  libxrender1 >/dev/null
success "Dependencies installed"

info "Ensuring locale en_US.UTF-8 is available..."
if ! locale -a 2>/dev/null | grep -qi 'en_US\.utf.*8'; then
  sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen 2>/dev/null || true
  locale-gen en_US.UTF-8 >/dev/null 2>&1 || true
  update-locale LANG=en_US.UTF-8 >/dev/null 2>&1 || true
  success "Locale en_US.UTF-8 generated"
else
  info "Locale en_US.UTF-8 already available"
fi

# -----------------------------------------------------------------------------
# 2. Pianoteq acquisition
# -----------------------------------------------------------------------------

PIANOTEQ_PKG_DIR="${REAL_HOME}/pianoteq-pkg"

if [[ -z "${PIANOTEQ_ARCHIVE}" ]]; then
  info "Looking for Pianoteq archive in ${PIANOTEQ_PKG_DIR}..."
  PIANOTEQ_ARCHIVE=$(find "${PIANOTEQ_PKG_DIR}" -maxdepth 1 \
    \( -name '*.7z' -o -name '*.tar.xz' -o -name '*.tar.gz' -o -name '*.zip' \) \
    -print -quit 2>/dev/null || true)
  [[ -n "${PIANOTEQ_ARCHIVE}" ]] || error "No Pianoteq archive found in ${PIANOTEQ_PKG_DIR}. Place your archive there or use --pianoteq-archive"
fi

[[ -f "${PIANOTEQ_ARCHIVE}" ]] || error "Archive not found: ${PIANOTEQ_ARCHIVE}"
info "Using archive: ${PIANOTEQ_ARCHIVE}"

EXTRACT_DIR=$(mktemp -d)
trap 'rm -rf "${EXTRACT_DIR}"' EXIT

case "${PIANOTEQ_ARCHIVE}" in
  *.tar.xz)
    tar -xf "${PIANOTEQ_ARCHIVE}" -C "${EXTRACT_DIR}"
    ;;
  *.tar.gz | *.tgz)
    tar -xzf "${PIANOTEQ_ARCHIVE}" -C "${EXTRACT_DIR}"
    ;;
  *.7z)
    7z x -o"${EXTRACT_DIR}" "${PIANOTEQ_ARCHIVE}" >/dev/null
    ;;
  *.zip)
    unzip -q "${PIANOTEQ_ARCHIVE}" -d "${EXTRACT_DIR}"
    ;;
  *)
    error "Unsupported archive format: ${PIANOTEQ_ARCHIVE}"
    ;;
esac

# Search strategies for finding the binary (handles v8 and v9 archive layouts):
#   1. Executable inside arm-64bit/ subdirectory (standard full package)
#   2. File named "Pianoteq*" inside arm-64bit/ (if not marked executable in archive)
#   3. Top-level "Pianoteq*" executable (trial/flat layout)
PIANOTEQ_BIN=""
if [[ -d "${EXTRACT_DIR}" ]]; then
  PIANOTEQ_BIN=$(find "${EXTRACT_DIR}" -path '*/arm-64bit/*' -type f -executable -print -quit 2>/dev/null || true)
  if [[ -z "${PIANOTEQ_BIN}" ]]; then
    PIANOTEQ_BIN=$(find "${EXTRACT_DIR}" -path '*/arm-64bit/Pianoteq*' -type f -print -quit 2>/dev/null || true)
  fi
  if [[ -z "${PIANOTEQ_BIN}" ]]; then
    PIANOTEQ_BIN=$(find "${EXTRACT_DIR}" -name 'Pianoteq*' -type f \( -executable -o -name '*.bin' \) -print -quit 2>/dev/null || true)
  fi
fi

[[ -n "${PIANOTEQ_BIN}" ]] || error "Could not find Pianoteq binary in extracted archive. Check the archive contents."
info "Found binary: ${PIANOTEQ_BIN}"

mkdir -p "${PIANOTEQ_INSTALL_DIR}"
cp "${PIANOTEQ_BIN}" "${PIANOTEQ_INSTALL_DIR}/Pianoteq"
chmod +x "${PIANOTEQ_INSTALL_DIR}/Pianoteq"

PTQ_VERSION=$("${PIANOTEQ_INSTALL_DIR}/Pianoteq" --version 2>/dev/null || echo "unknown")
success "Pianoteq ${PTQ_VERSION} installed to ${PIANOTEQ_INSTALL_DIR}/Pianoteq"

# -----------------------------------------------------------------------------
# 3. System prep — config.txt
# -----------------------------------------------------------------------------

info "Configuring system..."

config_set "gpu_mem" "16"
config_set "dtparam=audio" "off"
config_set_dac_overlay() {
  local overlay="$1"
  local known_dac_overlays=(hifiberry-dacplus iqaudio-dacplus)
  for existing in "${known_dac_overlays[@]}"; do
    if grep -q "^dtoverlay=${existing}" "${CONFIG_TXT}" 2>/dev/null; then
      if [[ "${existing}" == "${overlay}" ]]; then
        return 0
      fi
      sed -i "s|^dtoverlay=${existing}|dtoverlay=${overlay}|" "${CONFIG_TXT}"
      return 0
    fi
  done
  echo "dtoverlay=${overlay}" >>"${CONFIG_TXT}"
}

DAC_OVERLAY="iqaudio-dacplus"
if [[ -f /proc/device-tree/hat/product ]] 2>/dev/null; then
  HAT_PRODUCT=$(tr -d '\0' </proc/device-tree/hat/product 2>/dev/null || true)
  info "Detected HAT: ${HAT_PRODUCT}"
  case "${HAT_PRODUCT,,}" in
    *hifiberry*) DAC_OVERLAY="hifiberry-dacplus" ;;
    *iqaudio* | *raspberry*pi*dac*) DAC_OVERLAY="iqaudio-dacplus" ;;
  esac
fi
config_set_dac_overlay "${DAC_OVERLAY}"
info "DAC overlay: ${DAC_OVERLAY}"

config_ensure_line "dtoverlay=disable-bt"

success "config.txt updated"

# -----------------------------------------------------------------------------
# 4. System prep — services and governor
# -----------------------------------------------------------------------------

info "Setting CPU governor to performance..."
for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
  [[ -f "${gov}" ]] && echo "performance" >"${gov}" 2>/dev/null || true
done
# Persist across reboots via systemd-tmpfiles
mkdir -p /etc/tmpfiles.d
echo 'w /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor - - - - performance' \
  >/etc/tmpfiles.d/cpu-governor.conf
success "CPU governor set to performance (persistent via tmpfiles.d)"

systemctl disable --now bluetooth 2>/dev/null || true
info "Bluetooth disabled"

if [[ "${DISABLE_WIFI}" == true ]]; then
  rfkill block wifi 2>/dev/null || true
  config_ensure_line "dtoverlay=disable-wifi"
  info "Wifi disabled"
else
  info "Wifi left enabled (use --disable-wifi to disable)"
fi

for svc in pulseaudio pipewire pipewire-pulse wireplumber; do
  systemctl --user disable --now "${svc}" 2>/dev/null || true
  systemctl disable --now "${svc}" 2>/dev/null || true
done
apt-get remove -y -qq pulseaudio pipewire 2>/dev/null || true
info "PulseAudio/PipeWire removed (direct ALSA only)"

success "System prep complete"

# -----------------------------------------------------------------------------
# 5. ALSA configuration
# -----------------------------------------------------------------------------

info "Configuring ALSA..."

DAC_CARD="0"
if command -v aplay &>/dev/null; then
  DETECTED_CARD=$(aplay -l 2>/dev/null | grep -i 'hifiberry\|dacplus\|dac+\|iqaudio\|rpi.*dac' | head -1 | sed -n 's/^card \([0-9]*\).*/\1/p' || true)
  if [[ -n "${DETECTED_CARD}" ]]; then
    DAC_CARD="${DETECTED_CARD}"
    info "DAC detected on card ${DAC_CARD}"
  else
    warn "DAC not detected yet (may appear after reboot). Defaulting to card 0."
  fi
fi

sed "s/PIYANO_CARD_NUM/${DAC_CARD}/g" "${CONFIG_DIR}/asound.conf" >/etc/asound.conf
success "ALSA configured (/etc/asound.conf)"

# -----------------------------------------------------------------------------
# 6. Pianoteq user and systemd service
# -----------------------------------------------------------------------------

info "Setting up pianoteq user and service..."

if ! id "${PIANOTEQ_USER}" &>/dev/null; then
  useradd --system --home-dir "${PIANOTEQ_INSTALL_DIR}" --shell /usr/sbin/nologin "${PIANOTEQ_USER}"
  info "Created user: ${PIANOTEQ_USER}"
fi

usermod -aG audio "${PIANOTEQ_USER}" 2>/dev/null || true

chown -R "${PIANOTEQ_USER}:${PIANOTEQ_USER}" "${PIANOTEQ_INSTALL_DIR}"

cp "${CONFIG_DIR}/pianoteq.service" /etc/systemd/system/pianoteq.service
systemctl daemon-reload
systemctl enable pianoteq.service
success "pianoteq.service installed and enabled"

# -----------------------------------------------------------------------------
# 7. Pianoteq audio & MIDI preferences
# -----------------------------------------------------------------------------

info "Configuring Pianoteq audio and MIDI preferences..."

PTQ_MAJOR_MINOR=$("${PIANOTEQ_INSTALL_DIR}/Pianoteq" --version 2>/dev/null |
  grep -oP '^\d+\.\d+' | tr -d '.' || echo "84")
PTQ_PREFS_DIR="${PIANOTEQ_INSTALL_DIR}/.config/Modartt"
PTQ_PREFS_FILE="${PTQ_PREFS_DIR}/Pianoteq${PTQ_MAJOR_MINOR}.prefs"

PIANOTEQ_AUDIO_DEVICE=""
if command -v aplay &>/dev/null; then
  while IFS= read -r line; do
    if [[ "${line}" =~ ^hw:CARD= ]]; then
      IFS= read -r desc1 || true
      IFS= read -r desc2 || true
      desc1="${desc1#"${desc1%%[![:space:]]*}"}"
      desc2="${desc2#"${desc2%%[![:space:]]*}"}"
      if [[ "${desc1,,}" =~ dac\+|dacplus|hifiberry ]]; then
        PIANOTEQ_AUDIO_DEVICE="${desc1}; ${desc2}"
        break
      fi
    fi
  done < <(aplay -L 2>/dev/null)
fi

if [[ -z "${PIANOTEQ_AUDIO_DEVICE}" ]]; then
  PIANOTEQ_AUDIO_DEVICE="Default ALSA Output"
  warn "DAC not yet visible to ALSA (may need reboot). Using fallback: ${PIANOTEQ_AUDIO_DEVICE}"
else
  info "Pianoteq audio device: ${PIANOTEQ_AUDIO_DEVICE}"
fi

mkdir -p "${PTQ_PREFS_DIR}"

inject_pianoteq_prefs() {
  local prefs_file="$1" device_name="$2"
  local audio_setup_xml
  audio_setup_xml=$(
    cat <<PXML
  <VALUE name="audio-setup">
    <DEVICESETUP deviceType="ALSA" audioOutputDeviceName="${device_name}"
                 audioInputDeviceName="" audioDeviceRate="48000.0" audioDeviceBufferSize="256"
                 forceStereo="0"/>
  </VALUE>
PXML
  )

  if [[ ! -f "${prefs_file}" ]]; then
    cat >"${prefs_file}" <<PXML
<?xml version="1.0" encoding="UTF-8"?>

<PROPERTIES>
  <VALUE name="multicore" val="2"/>
${audio_setup_xml}
  <VALUE name="midi-setup">
    <midi-setup listen-all="1"/>
  </VALUE>
</PROPERTIES>
PXML
    info "Created ${prefs_file}"
    return
  fi

  if ! grep -q 'name="audio-setup"' "${prefs_file}"; then
    local close_line
    close_line=$(grep -n '</PROPERTIES>' "${prefs_file}" | head -1 | cut -d: -f1)
    if [[ -n "${close_line}" ]]; then
      {
        head -n "$((close_line - 1))" "${prefs_file}"
        printf '%s\n' "${audio_setup_xml}"
        tail -n +"${close_line}" "${prefs_file}"
      } >"${prefs_file}.tmp" && mv "${prefs_file}.tmp" "${prefs_file}"
      info "Injected audio-setup into existing prefs"
    else
      warn "Could not find </PROPERTIES> in ${prefs_file}, skipping audio-setup injection"
    fi
  else
    info "audio-setup already present in prefs (not overwriting)"
  fi

  if grep -q 'listen-all="0"' "${prefs_file}"; then
    sed -i 's/listen-all="0"/listen-all="1"/' "${prefs_file}"
    info "Enabled listen-all for MIDI"
  fi
}

inject_pianoteq_prefs "${PTQ_PREFS_FILE}" "${PIANOTEQ_AUDIO_DEVICE}"
chown -R "${PIANOTEQ_USER}:${PIANOTEQ_USER}" "${PTQ_PREFS_DIR}"
success "Pianoteq preferences configured"

# -----------------------------------------------------------------------------
# 8. Optional CPU isolation tweaks
# -----------------------------------------------------------------------------

if [[ "${WITH_TWEAKS}" == true ]]; then
  info "Applying CPU isolation tweaks..."
  if [[ -x "${SCRIPT_DIR}/tweaks/isolcpus.sh" ]]; then
    bash "${SCRIPT_DIR}/tweaks/isolcpus.sh"
  else
    warn "tweaks/isolcpus.sh not found or not executable, skipping"
  fi
fi

# Clean up VNC/Xvfb if a previous debug session left them running
for stale_proc in Xvfb x11vnc openbox; do
  pkill "${stale_proc}" 2>/dev/null || true
done

git -C "${SCRIPT_DIR}" config pull.rebase true

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------

echo ""
echo "============================================="
echo "  piyano setup complete!"
echo "============================================="
echo ""
info "What happens next:"
echo "  1. Reboot:  sudo reboot"
echo "  2. Pianoteq starts automatically on boot"
echo "  3. Plug in your USB MIDI keyboard and play"
echo ""
info "First boot with internet required for Pianoteq licence activation."
info "JSON-RPC remote control available at http://<this-pi>:8081/"
echo ""

info "Manage presets: Pianoteq --list-presets"
info "Service status: systemctl status pianoteq"
info "Service logs:   journalctl -u pianoteq -f"
