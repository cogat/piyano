#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# CPU isolation tweaks for low-latency Pianoteq on Raspberry Pi 5
#
# Isolates cores 1-3 from the kernel scheduler, leaving core 0 for the OS.
# Pianoteq (pinned to cores 1-3 via systemd CPUAffinity) gets near-exclusive
# access to those cores.
#
# This is EXPERIMENTAL. To revert:
#   1. Edit /boot/firmware/cmdline.txt and remove the isolcpus/nohz/rcu params
#   2. sudo systemctl disable --now irq-affinity.service
#   3. Reboot
# =============================================================================

info() { printf '\033[1;34m[info]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
success() { printf '\033[1;32m[ok]\033[0m %s\n' "$*"; }
error() {
  printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2
  exit 1
}

[[ "$(id -u)" -eq 0 ]] || error "This script must be run as root"

CMDLINE="/boot/firmware/cmdline.txt"
if [[ ! -f "${CMDLINE}" ]]; then
  CMDLINE="/boot/cmdline.txt"
  [[ -f "${CMDLINE}" ]] || error "Cannot find cmdline.txt"
fi

# ---- CPU isolation via kernel params ----------------------------------------

ISOL_PARAMS="isolcpus=1-3 nohz_full=1-3 rcu_nocbs=1-3"

CURRENT=$(cat "${CMDLINE}")
if [[ "${CURRENT}" == *"isolcpus=1-3"* ]]; then
  info "CPU isolation params already present in ${CMDLINE}"
else
  info "Adding CPU isolation params to ${CMDLINE}..."
  cp "${CMDLINE}" "${CMDLINE}.bak"
  echo "${CURRENT} ${ISOL_PARAMS}" >"${CMDLINE}"
  success "cmdline.txt updated (backup at ${CMDLINE}.bak)"
fi

# ---- IRQ affinity service ---------------------------------------------------
# Pins audio-related IRQs to the isolated cores after boot.

IRQ_SCRIPT="/usr/local/bin/piyano-irq-affinity.sh"
cat >"${IRQ_SCRIPT}" <<'IRQEOF'
#!/usr/bin/env bash
set -euo pipefail

AUDIO_CORES="e"  # bitmask: cores 1-3 = 0b1110 = 0xe

for irqdir in /proc/irq/*/; do
  irq_num=$(basename "${irqdir}")
  [[ "${irq_num}" =~ ^[0-9]+$ ]] || continue

  actions_file="${irqdir}actions"
  [[ -f "${actions_file}" ]] || continue
  actions=$(cat "${actions_file}" 2>/dev/null || true)

  # Pin USB and I2S/sound IRQs to the isolated cores
  if [[ "${actions}" == *"xhci"* ]] || [[ "${actions}" == *"fe203000"* ]] || [[ "${actions}" == *"sound"* ]] || [[ "${actions}" == *"i2s"* ]]; then
    echo "${AUDIO_CORES}" > "${irqdir}smp_affinity" 2>/dev/null || true
  fi
done
IRQEOF
chmod +x "${IRQ_SCRIPT}"

cat >/etc/systemd/system/irq-affinity.service <<SVCEOF
[Unit]
Description=Pin audio IRQs to isolated cores
After=multi-user.target

[Service]
Type=oneshot
ExecStart=${IRQ_SCRIPT}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable irq-affinity.service
success "IRQ affinity service installed and enabled"

echo ""
warn "CPU isolation tweaks applied. These are EXPERIMENTAL."
warn "Reboot required. If the system misbehaves:"
warn "  1. Edit ${CMDLINE} and remove: ${ISOL_PARAMS}"
warn "  2. sudo systemctl disable --now irq-affinity.service"
warn "  3. Reboot"
