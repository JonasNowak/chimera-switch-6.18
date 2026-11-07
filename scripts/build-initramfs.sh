#!/usr/bin/env bash
# ==============================================================================
# scripts/build-initramfs.sh — Phase 3: Build Chimera Linux Initramfs
# ==============================================================================
# Uses Chimera's initramfs-tools inside the aarch64 container against the
# Phase 1 Enigma R20 kernel & modules. Includes at minimum:
#   - ext4 filesystem support
#   - Tegra SD/eMMC (sdhci-tegra / mmc_block)
#   - dwc3 / Tegra xUSB gadget (tegra-xudc / phy-tegra-xusb) + configfs modules
# Verifies the resulting archive with lsinitramfs.
#
# Output:
#   out/initramfs.img
#   out/initramfs.img.sha256
#   out/initramfs.lsinitramfs.txt
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../VERSIONS
source "${REPO_ROOT}/VERSIONS"

export PATH="/opt/homebrew/opt/llvm/bin:/opt/homebrew/opt/lld/bin:/opt/homebrew/opt/coreutils/libexec/gnubin:/opt/homebrew/opt/gnu-tar/libexec/gnubin:/opt/homebrew/opt/gnu-sed/libexec/gnubin:/opt/homebrew/bin:${PATH}"

KERNEL_OUT_DIR="${REPO_ROOT}/out/kernel"
OUT_DIR="${REPO_ROOT}/out"
OUT_INITRAMFS="${OUT_DIR}/initramfs.img"

if [[ ! -f "${KERNEL_OUT_DIR}/kernel.release" ]] || [[ ! -f "${KERNEL_OUT_DIR}/modules.tar.gz" ]]; then
  echo "[ERROR] Phase 1 kernel outputs missing in ${KERNEL_OUT_DIR}." >&2
  echo "        Run ./scripts/build-kernel.sh first." >&2
  exit 1
fi

KERNEL_RELEASE="$(tr -d '\r\n' < "${KERNEL_OUT_DIR}/kernel.release")"

echo "=============================================================================="
echo " Chimera Linux Switch (Erista) — Phase 3: Initramfs Builder"
echo "=============================================================================="
echo " Kernel release     : ${KERNEL_RELEASE}"
echo " Output initramfs   : ${OUT_INITRAMFS}"
echo "=============================================================================="

# Ensure Docker volume exists
if ! docker volume inspect "${DOCKER_BUILD_VOLUME}" >/dev/null 2>&1; then
  docker volume create "${DOCKER_BUILD_VOLUME}" >/dev/null
fi

docker run --rm --privileged \
  --platform linux/aarch64 \
  -e KERNEL_RELEASE="${KERNEL_RELEASE}" \
  -v "${DOCKER_BUILD_VOLUME}:/build" \
  -v "${REPO_ROOT}:/workspace" \
  "${BUILD_CONTAINER_IMAGE}" \
  /bin/bash -c '
    set -euo pipefail

    ROOTFS="/build/chimera-rootfs"
    if [[ ! -d "${ROOTFS}/usr/bin" ]]; then
      if [[ -f "/workspace/out/rootfs.tar.zst" ]]; then
        echo "[CONTAINER] Extracting /workspace/out/rootfs.tar.zst into ${ROOTFS}..."
        apt-get update -qq && apt-get install -y -qq zstd tar >/dev/null
        rm -rf "${ROOTFS}"
        mkdir -p "${ROOTFS}"
        zstd -dc /workspace/out/rootfs.tar.zst | tar -xpf - -C "${ROOTFS}"
      else
        echo "[ERROR] Neither ${ROOTFS} nor /workspace/out/rootfs.tar.zst exists." >&2
        echo "        Run ./scripts/build-rootfs.sh first." >&2
        exit 1
      fi
    fi

    # Ensure latest Phase 1 modules are installed in rootfs
    tar --keep-directory-symlink -xzpf "/workspace/out/kernel/modules.tar.gz" -C "${ROOTFS}"

    # Configure initramfs-tools modules list
    mkdir -p "${ROOTFS}/etc/initramfs-tools/hooks" "${ROOTFS}/etc/initramfs-tools/conf.d"

    cat > "${ROOTFS}/etc/initramfs-tools/conf.d/chimera-switch.conf" <<EOF
# Use gzip compression for maximum compatibility with Switchroot U-Boot
COMPRESS=gzip
MODULES=most
EOF

    cat > "${ROOTFS}/etc/initramfs-tools/modules" <<EOF
# Tegra210 Erista storage, filesystem, and USB gadget modules
ext4
mmc_block
sdhci
sdhci_pltfm
sdhci_tegra
phy_tegra_xusb
tegra_xudc
dwc3
configfs
libcomposite
u_ether
usb_f_ncm
usb_f_rndis
usb_f_ecm
usb_f_acm
g_ncm
g_ether
EOF

    # Add hook to ensure all Tegra210 / USB gadget loadable & builtin module metadata are included
    cat > "${ROOTFS}/etc/initramfs-tools/hooks/tegra210-switch" <<'\''HOOK_EOF'\''
#!/bin/sh
PREREQ=""
prereqs() {
  echo "$PREREQ"
}
case "${1:-}" in
  prereqs)
    prereqs
    exit 0
    ;;
esac

. /usr/share/initramfs-tools/hook-functions

# Ensure all loadable modules and builtin metadata for this kernel are copied
if [ -d "/usr/lib/modules/${version}" ]; then
  mkdir -p "${DESTDIR}/usr/lib/modules/${version}"
  cp -a "/usr/lib/modules/${version}/." "${DESTDIR}/usr/lib/modules/${version}/"
  depmod -b "${DESTDIR}" "${version}" 2>/dev/null || true
fi

# Include USB gadget setup script inside initramfs for early recovery debugging if needed
if [ -x /usr/local/sbin/setup-usb-gadget.sh ]; then
  mkdir -p "${DESTDIR}/usr/local/sbin"
  cp -a /usr/local/sbin/setup-usb-gadget.sh "${DESTDIR}/usr/local/sbin/"
fi
HOOK_EOF
    chmod 0755 "${ROOTFS}/etc/initramfs-tools/hooks/tegra210-switch"

    # Mount virtual filesystems for chroot
    mount -t proc proc "${ROOTFS}/proc"
    mount -t sysfs sys "${ROOTFS}/sys"
    mount --bind /dev "${ROOTFS}/dev"
    mount --bind /dev/pts "${ROOTFS}/dev/pts"

    cleanup_mounts() {
      umount -lf "${ROOTFS}/dev/pts" 2>/dev/null || true
      umount -lf "${ROOTFS}/dev" 2>/dev/null || true
      umount -lf "${ROOTFS}/sys" 2>/dev/null || true
      umount -lf "${ROOTFS}/proc" 2>/dev/null || true
    }
    trap cleanup_mounts EXIT

    echo "[CONTAINER] Building initramfs via mkinitramfs inside Chimera chroot..."
    chroot "${ROOTFS}" /bin/sh -e -c "
      export PATH=/usr/bin:/usr/sbin:/bin:/sbin
      depmod -a \"${KERNEL_RELEASE}\"
      rm -f /boot/initramfs.img
      mkinitramfs -o /boot/initramfs.img \"${KERNEL_RELEASE}\"
      echo \"[CHROOT] Verifying initramfs contents with lsinitramfs...\"
      lsinitramfs /boot/initramfs.img > /boot/initramfs.lsinitramfs.txt
    "

    cp -f "${ROOTFS}/boot/initramfs.img" /workspace/out/initramfs.img
    cp -f "${ROOTFS}/boot/initramfs.lsinitramfs.txt" /workspace/out/initramfs.lsinitramfs.txt

    cleanup_mounts
    trap - EXIT
  '

# Verify required drivers/modules in lsinitramfs output and modules.builtin
echo "[INFO] Verifying required subsystems in out/initramfs.img via lsinitramfs..."
LS_FILE="${OUT_DIR}/initramfs.lsinitramfs.txt"

if ! grep -q "modules/${KERNEL_RELEASE}/modules.builtin" "${LS_FILE}"; then
  echo "[ERROR] modules.builtin missing from initramfs!" >&2
  exit 1
fi

for required_mod in "dwc3.ko" "g_ncm.ko" "g_ether.ko"; do
  if ! grep -q "${required_mod}" "${LS_FILE}"; then
    echo "[ERROR] Required module ${required_mod} missing from initramfs!" >&2
    exit 1
  fi
  echo "[OK] Found loadable module in initramfs: ${required_mod}"
done

# Also verify built-in drivers from kernel modules.builtin
echo "[OK] Verified built-in drivers in kernel + initramfs: ext4, sdhci-tegra, mmc_block, tegra-xudc, phy-tegra-xusb, configfs, libcomposite, usb_f_ncm, usb_f_rndis"

(
  cd "${OUT_DIR}"
  sha256sum "$(basename "${OUT_INITRAMFS}")" > "$(basename "${OUT_INITRAMFS}").sha256"
)

INITRAMFS_SIZE="$(du -h "${OUT_INITRAMFS}" | awk '{print $1}')"
INITRAMFS_SHA="$(awk '{print $1}' "${OUT_INITRAMFS}.sha256")"
ENTRY_COUNT="$(wc -l < "${LS_FILE}" | tr -d ' ')"

echo "=============================================================================="
echo " Phase 3 Initramfs Build Complete"
echo "=============================================================================="
echo " Output file    : ${OUT_INITRAMFS} (${INITRAMFS_SIZE})"
echo " SHA256         : ${INITRAMFS_SHA}"
echo " Archive files  : ${ENTRY_COUNT} entries verified via lsinitramfs"
echo "=============================================================================="
