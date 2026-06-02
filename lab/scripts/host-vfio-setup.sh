#!/usr/bin/env bash
# host-vfio-setup.sh — configure VFIO on the LXD host so a discrete PCIe GPU can
# be passed through to a VM.
#
# IMPORTANT: This DOES NOT WORK on NVIDIA Grace-Blackwell (GB10 / DGX Spark) or
# other systems where the GPU's firmware requests a 1:1 (identity) IOMMU mapping.
# On those platforms `vfio-pci` will load and bind, but `qemu` will fail with:
#   "Firmware has requested this device have a 1:1 IOMMU mapping, rejecting
#    configuring the device without a 1:1 mapping."
# Use an LXD CONTAINER with `nvidia.runtime=true` instead (see lab project 004).
#
# Modes:
#   check  (default) read-only: prints the target GPU's PCI BDF, IOMMU group,
#                    all devices in that group, vfio module status, current
#                    cmdline, and a SAFE / RISKY / UNSAFE verdict.
#   apply           (root) writes /etc/modules-load.d/vfio.conf and
#                    /etc/modprobe.d/vfio-pci.conf, updates GRUB cmdline
#                    (iommu.passthrough=1 + vfio-pci.ids=<vendor:device>),
#                    runs update-grub + update-initramfs, prints the diff and
#                    explicit rollback steps. Does NOT reboot.
#   rollback        (root) reverts the files this script wrote (best effort).
#
# Env: PCI_BDF (default 000f:01:00.0 — GB10 GPU on this host).
set -euo pipefail

PCI_BDF="${PCI_BDF:-000f:01:00.0}"
GRUB_CFG="/etc/default/grub"
MODLOAD="/etc/modules-load.d/vfio.conf"
MODPROBE="/etc/modprobe.d/vfio-pci.conf"
BACKUP_DIR="/etc/host-vfio-setup.bak"
mode="${1:-check}"

# Critical PCI classes — if any device in the GPU's IOMMU group has one of these
# classes, passthrough would steal it from the host (network, storage, USB host,
# system peripheral). PCIe bridges (0604) are fine to share.
_critical_classes='0200|0107|0c03|0880|0805|0106'   # net/scsi/usb/sys-periph/sata
_safe_classes='0604|0300|0302|0380'                  # bridge + display/3d/other-display

_color() {  # _color RED|GREEN|YELLOW|RESET
  case "$1" in RED) printf '\033[31m';; GREEN) printf '\033[32m';; YELLOW) printf '\033[33m';; *) printf '\033[0m';; esac
}

cmd_check() {
  echo "== host-vfio-setup check (GPU PCI BDF = $PCI_BDF) =="
  if [[ ! -d "/sys/bus/pci/devices/$PCI_BDF" ]]; then
    echo "FATAL: /sys/bus/pci/devices/$PCI_BDF not found; set PCI_BDF=<dom:bus:dev.fn>" >&2
    exit 2
  fi
  local group_link="/sys/bus/pci/devices/$PCI_BDF/iommu_group"
  if [[ ! -L "$group_link" ]]; then
    echo "FATAL: $PCI_BDF has no iommu_group (kernel IOMMU not enabled? cmdline iommu=?)" >&2
    grep -oE 'iommu[._a-zA-Z]*=[^ ]+' /proc/cmdline 2>/dev/null || true
    exit 2
  fi
  local group; group=$(basename "$(readlink -f "$group_link")")
  echo "GPU is in IOMMU group: $group"
  echo
  echo "Devices in IOMMU group $group:"
  local risky=0 unsafe=0
  for dev in /sys/kernel/iommu_groups/$group/devices/*; do
    local bdf; bdf=$(basename "$dev")
    local class_hex; class_hex=$(cut -c3-6 < "$dev/class" 2>/dev/null || echo "????")
    local desc; desc=$(lspci -s "$bdf" 2>/dev/null | head -1)
    local label="(safe)" col=GREEN
    if grep -qiE "^($_critical_classes)$" <<< "$class_hex"; then
      label="(CRITICAL — host would lose this)"; col=RED; unsafe=1
    elif grep -qiE "^($_safe_classes)$" <<< "$class_hex"; then :
    else label="(unknown class — review manually)"; col=YELLOW; risky=1
    fi
    printf '  %s  class=%s  %s ' "$bdf" "$class_hex" "$desc"
    _color "$col"; echo "$label"; _color RESET
  done
  echo
  echo "vendor:device of the GPU itself:"
  awk '{print $1":"$2}' <(printf '%s %s\n' "$(cat /sys/bus/pci/devices/$PCI_BDF/vendor | sed 's/^0x//')" "$(cat /sys/bus/pci/devices/$PCI_BDF/device | sed 's/^0x//')")
  echo
  echo "Current driver on GPU: $(basename "$(readlink -f /sys/bus/pci/devices/$PCI_BDF/driver 2>/dev/null)" 2>/dev/null || echo none)"
  echo "vfio modules loaded?  $(lsmod 2>/dev/null | awk '/^vfio/ {print $1}' | xargs -r || echo none)"
  echo "Current /proc/cmdline:"
  echo "  $(cat /proc/cmdline)"
  echo
  if (( unsafe )); then _color RED; echo "VERDICT: UNSAFE — IOMMU group contains a critical device; do not pass through."; _color RESET; exit 1
  elif (( risky )); then _color YELLOW; echo "VERDICT: RISKY — review the unknown-class devices above before applying."; _color RESET; exit 0
  else _color GREEN; echo "VERDICT: SAFE — IOMMU group is clean for vfio-pci binding."; _color RESET; exit 0
  fi
}

cmd_apply() {
  [[ $EUID -eq 0 ]] || { echo "apply requires sudo (run: sudo bash $0 apply)" >&2; exit 2; }
  local vendor device; vendor=$(cat "/sys/bus/pci/devices/$PCI_BDF/vendor" | sed 's/^0x//')
  device=$(cat "/sys/bus/pci/devices/$PCI_BDF/device" | sed 's/^0x//')
  local ids="${vendor}:${device}"
  mkdir -p "$BACKUP_DIR"; cp -an "$GRUB_CFG" "$BACKUP_DIR/grub.bak" 2>/dev/null || true
  echo "== apply ==  GPU ids=$ids"
  echo "1) /etc/modules-load.d/vfio.conf"
  printf 'vfio\nvfio_pci\nvfio_iommu_type1\n' > "$MODLOAD"
  echo "   wrote: $(cat $MODLOAD | tr '\n' ' ')"
  echo "2) /etc/modprobe.d/vfio-pci.conf"
  printf 'options vfio-pci ids=%s disable_vga=1\nsoftdep nvidia pre: vfio-pci\n' "$ids" > "$MODPROBE"
  echo "   wrote: $(cat $MODPROBE | tr '\n' ' ')"
  echo "3) GRUB cmdline (iommu.passthrough=1, vfio-pci.ids=$ids)"
  if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_CFG"; then
    sed -i.bak -E \
      -e 's/iommu\.passthrough=[01]/iommu.passthrough=1/' \
      -e 's/vfio-pci\.ids=[^"[:space:]]*/vfio-pci.ids='"$ids"'/' "$GRUB_CFG"
    grep -q 'iommu.passthrough=' "$GRUB_CFG" || sed -i -E 's/^(GRUB_CMDLINE_LINUX_DEFAULT=")/\1iommu.passthrough=1 /' "$GRUB_CFG"
    grep -q 'vfio-pci.ids=' "$GRUB_CFG" || sed -i -E 's/^(GRUB_CMDLINE_LINUX_DEFAULT=")/\1vfio-pci.ids='"$ids"' /' "$GRUB_CFG"
    echo "   $(grep ^GRUB_CMDLINE_LINUX_DEFAULT= $GRUB_CFG)"
  else
    echo "   WARN: GRUB_CMDLINE_LINUX_DEFAULT not found in $GRUB_CFG — edit manually."
  fi
  echo "4) update-grub + update-initramfs"
  update-grub
  update-initramfs -u
  echo
  echo "DONE. To activate: sudo reboot"
  echo "Rollback at any time: sudo bash $0 rollback"
}

cmd_rollback() {
  [[ $EUID -eq 0 ]] || { echo "rollback requires sudo" >&2; exit 2; }
  rm -f "$MODLOAD" "$MODPROBE"
  [[ -f "$BACKUP_DIR/grub.bak" ]] && cp "$BACKUP_DIR/grub.bak" "$GRUB_CFG" && update-grub
  update-initramfs -u
  echo "Rolled back. Reboot to return to non-VFIO state."
}

case "$mode" in
  check)    cmd_check ;;
  apply)    cmd_apply ;;
  rollback) cmd_rollback ;;
  *) echo "usage: $0 {check|apply|rollback}" >&2; exit 2 ;;
esac
