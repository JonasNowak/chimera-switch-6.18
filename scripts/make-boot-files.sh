#!/usr/bin/env bash
# ==============================================================================
# scripts/make-boot-files.sh — Phase 4: Hekate & Switchroot L4T Boot Packaging
# ==============================================================================
# Populates out/sd-boot/ (or a custom --dest directory) with the standard
# Switchroot L4T / Hekate FAT32 partition layout for Chimera Linux on Erista:
#
#   bootloader/ini/CHIMERA.ini
#   switchroot/chimera/
#     ├── bl31.bin              (ARM Trusted Firmware / L4T Monitor, pinned SHA256)
#     ├── bl33.bin              (Switchroot U-Boot payload, pinned SHA256)
#     ├── boot.txt              (U-Boot boot script source)
#     ├── boot.scr              (Compiled U-Boot script image via mkimage)
#     ├── uImage                (Phase 1 Linux 6.18 Image wrapped via mkimage)
#     ├── initramfs             (Phase 3 Chimera initramfs.img)
#     ├── nx-plat.dtimg         (Tegra210 Android DT image with ODIN/Erista entry)
#     ├── tegra210-odin.dtb     (Standalone Erista DTB)
#     ├── tegra210-icosa.dtb    (Alias Erista DTB)
#     ├── icon_chimera_hue.bmp  (Hekate menu icon)
#     ├── logo_chimera.bmp      (Boot splash logo)
#     └── README_CONFIG.txt     (Upstream Switchroot Hekate INI key reference)
#
# Ground rules enforced:
#   - Never touches eMMC (emmc=0 in CHIMERA.ini).
#   - Preserves existing L4T 4.9 / rescue boot entries (writes ONLY under
#     bootloader/ini/CHIMERA.ini and switchroot/chimera/, and refuses to
#     overwrite an existing install without --force).
#   - Never commits binary boot artifacts to git (downloaded & verified at build).
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../VERSIONS
source "${REPO_ROOT}/VERSIONS"

export PATH="/opt/homebrew/opt/u-boot-tools/bin:/opt/homebrew/opt/coreutils/libexec/gnubin:/opt/homebrew/opt/gnu-tar/libexec/gnubin:/opt/homebrew/opt/gnu-sed/libexec/gnubin:/opt/homebrew/bin:${PATH}"

FORCE_OVERWRITE=0
DEST_DIR="${REPO_ROOT}/out/sd-boot"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force|-f)
      FORCE_OVERWRITE=1
      shift
      ;;
    --dest)
      DEST_DIR="$2"
      shift 2
      ;;
    --help|-h)
      cat <<EOF
Usage: $(basename "$0") [--force] [--dest <path>]

Options:
  --force, -f     Allow overwriting existing files in the target boot directory
  --dest <path>   Output directory (default: out/sd-boot)
EOF
      exit 0
      ;;
    *)
      echo "[ERROR] Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

DOWNLOAD_DIR="${REPO_ROOT}/work/downloads"
KERNEL_OUT_DIR="${REPO_ROOT}/out/kernel"
INITRAMFS_IMG="${REPO_ROOT}/out/initramfs.img"
DISTRO_PATH="${DEST_DIR}/switchroot/${SWITCHROOT_DISTRO_DIR}"
INI_PATH="${DEST_DIR}/bootloader/ini/${HEKATE_INI_NAME}"

mkdir -p "${DOWNLOAD_DIR}"

echo "=============================================================================="
echo " Chimera Linux Switch (Erista) — Phase 4: Hekate Boot Packaging"
echo "=============================================================================="
echo " Target directory   : ${DEST_DIR}"
echo " Distro prefix      : /switchroot/${SWITCHROOT_DISTRO_DIR}/"
echo " Hekate INI         : bootloader/ini/${HEKATE_INI_NAME}"
echo " Filesystem label   : ${HEKATE_FS_LABEL}"
echo "=============================================================================="

# 1. Rescue-path protection check
if [[ -e "${INI_PATH}" ]] || [[ -d "${DISTRO_PATH}" ]] || [[ -d "${DEST_DIR}/bootloader/ini" ]]; then
  # Check if any existing L4T / rescue entries exist
  if [[ -d "${DEST_DIR}/bootloader/ini" ]]; then
    existing_inis="$(find "${DEST_DIR}/bootloader/ini" -maxdepth 1 -type f -name '*.ini' 2>/dev/null || true)"
    if [[ -n "${existing_inis}" ]]; then
      echo "[WARNING] Existing Hekate INI files detected in ${DEST_DIR}/bootloader/ini:" >&2
      echo "${existing_inis}" | sed 's/^/          - /' >&2
      echo "          Note: L4T 4.9 rescue entries (e.g. L4T.ini) will NOT be deleted," >&2
      echo "          as this script only writes ${HEKATE_INI_NAME} and switchroot/${SWITCHROOT_DISTRO_DIR}/." >&2
    fi
  fi

  if [[ -e "${INI_PATH}" ]] || [[ -d "${DISTRO_PATH}" ]]; then
    if [[ "${FORCE_OVERWRITE}" -ne 1 ]]; then
      echo "==============================================================================" >&2
      echo " [RESCUE PATH PROTECTION] Existing boot files found at:" >&2
      echo "   - ${INI_PATH}" >&2
      echo "   - ${DISTRO_PATH}" >&2
      echo " Refusing to overwrite without explicit confirmation flag." >&2
      echo " Re-run with: ./scripts/make-boot-files.sh --force" >&2
      echo "==============================================================================" >&2
      exit 1
    else
      echo "[WARN] --force specified: overwriting existing ${INI_PATH} and ${DISTRO_PATH}."
    fi
  fi
fi

# 2. Verify Phase 1 (Kernel + DTBs) and Phase 3 (initramfs) inputs exist
for req in "${KERNEL_OUT_DIR}/Image" "${KERNEL_OUT_DIR}/${TARGET_DTB_BASENAME}" "${INITRAMFS_IMG}"; do
  if [[ ! -f "${req}" ]]; then
    echo "[ERROR] Required build artifact missing: ${req}" >&2
    echo "        Ensure Phase 1 (build-kernel.sh) and Phase 3 (build-initramfs.sh) have completed." >&2
    exit 1
  fi
done

# 3. Download and verify official Switchroot L4S bootstack assets
ASSETS_TARBALL="${DOWNLOAD_DIR}/l4s-boot-assets-${L4S_PIPELINE_COMMIT:0:12}.tar.gz"
BL33_FILE="${DOWNLOAD_DIR}/bl33-${L4S_UBOOT_COMMIT:0:12}.bin"

if [[ ! -f "${ASSETS_TARBALL}" ]]; then
  if [[ -f "/tmp/l4s-assets-inspect/l4s-boot-assets.tar.gz" ]]; then
    cp "/tmp/l4s-assets-inspect/l4s-boot-assets.tar.gz" "${ASSETS_TARBALL}"
  else
    echo "[INFO] Downloading official Switchroot L4S boot assets archive..."
    curl -fL --retry 3 -o "${ASSETS_TARBALL}.part" "${L4S_BOOT_ASSETS_URL}"
    mv "${ASSETS_TARBALL}.part" "${ASSETS_TARBALL}"
  fi
fi

ACTUAL_ASSETS_SHA="$(sha256sum "${ASSETS_TARBALL}" | awk '{print $1}')"
if [[ "${ACTUAL_ASSETS_SHA}" != "${L4S_BOOT_ASSETS_SHA256}" ]]; then
  echo "[ERROR] SHA256 mismatch for ${ASSETS_TARBALL}" >&2
  echo "        Expected: ${L4S_BOOT_ASSETS_SHA256}" >&2
  echo "        Actual:   ${ACTUAL_ASSETS_SHA}" >&2
  exit 1
fi
echo "[OK] Verified L4S boot assets archive (${ACTUAL_ASSETS_SHA:0:16}...)"

if [[ ! -f "${BL33_FILE}" ]]; then
  if [[ -f "/tmp/l4s-assets-inspect/bl33.bin" ]]; then
    cp "/tmp/l4s-assets-inspect/bl33.bin" "${BL33_FILE}"
  else
    echo "[INFO] Downloading official Switchroot U-Boot (bl33.bin)..."
    curl -fL --retry 3 -o "${BL33_FILE}.part" "${L4S_BL33_URL}"
    mv "${BL33_FILE}.part" "${BL33_FILE}"
  fi
fi

ACTUAL_BL33_SHA="$(sha256sum "${BL33_FILE}" | awk '{print $1}')"
if [[ "${ACTUAL_BL33_SHA}" != "${L4S_BL33_SHA256}" ]]; then
  echo "[ERROR] SHA256 mismatch for ${BL33_FILE}" >&2
  echo "        Expected: ${L4S_BL33_SHA256}" >&2
  echo "        Actual:   ${ACTUAL_BL33_SHA}" >&2
  exit 1
fi
echo "[OK] Verified Switchroot U-Boot bl33.bin (${ACTUAL_BL33_SHA:0:16}...)"

# 4. Extract and verify individual Switchroot chain files
STAGE_ASSETS_DIR="${REPO_ROOT}/work/l4s-boot-assets-extracted"
rm -rf "${STAGE_ASSETS_DIR}"
mkdir -p "${STAGE_ASSETS_DIR}"
tar -xzf "${ASSETS_TARBALL}" --strip-components=4 -C "${STAGE_ASSETS_DIR}"

verify_chain_file() {
  local file_path="$1"
  local expected_sha="$2"
  local label="$3"
  local actual_sha
  actual_sha="$(sha256sum "${file_path}" | awk '{print $1}')"
  if [[ "${actual_sha}" != "${expected_sha}" ]]; then
    echo "[ERROR] SHA256 mismatch for ${label} (${file_path})" >&2
    echo "        Expected: ${expected_sha}" >&2
    echo "        Actual:   ${actual_sha}" >&2
    exit 1
  fi
  echo "[OK] Verified ${label}: ${actual_sha:0:16}..."
}

verify_chain_file "${STAGE_ASSETS_DIR}/bl31.bin" "${L4S_BL31_SHA256}" "ARM Trusted Firmware (bl31.bin)"
verify_chain_file "${STAGE_ASSETS_DIR}/boot.txt" "${L4S_BOOT_TXT_SHA256}" "Switchroot U-Boot script template (boot.txt)"
verify_chain_file "${STAGE_ASSETS_DIR}/ini" "${L4S_INI_TEMPLATE_SHA256}" "Switchroot Hekate INI template (ini)"
verify_chain_file "${STAGE_ASSETS_DIR}/Hekate-Icons/linux/icon_linux_hue.bmp" "${L4S_ICON_HUE_SHA256}" "Hekate icon BMP"
verify_chain_file "${STAGE_ASSETS_DIR}/Hekate-Icons/linux/logo_linux.bmp" "${L4S_LOGO_BMP_SHA256}" "Boot splash logo BMP"

# 5. Prepare output directory structure
mkdir -p "${DEST_DIR}/bootloader/ini" "${DISTRO_PATH}"

# Copy verified chain binaries and icons
cp -f "${STAGE_ASSETS_DIR}/bl31.bin" "${DISTRO_PATH}/bl31.bin"
cp -f "${BL33_FILE}" "${DISTRO_PATH}/bl33.bin"
cp -f "${STAGE_ASSETS_DIR}/README_CONFIG.txt" "${DISTRO_PATH}/README_CONFIG.txt"
cp -f "${STAGE_ASSETS_DIR}/Hekate-Icons/linux/icon_linux_hue.bmp" "${DISTRO_PATH}/icon_chimera_hue.bmp"
cp -f "${STAGE_ASSETS_DIR}/Hekate-Icons/linux/logo_linux.bmp" "${DISTRO_PATH}/logo_chimera.bmp"

# 6. Wrap Phase 1 Image into U-Boot uImage via mkimage
echo "[INFO] Wrapping Phase 1 kernel Image into U-Boot uImage (load=${UIMAGE_LOAD_ADDR}, entry=${UIMAGE_ENTRY_ADDR})..."
mkimage \
  -A arm64 \
  -O linux \
  -T kernel \
  -C none \
  -a "${UIMAGE_LOAD_ADDR}" \
  -e "${UIMAGE_ENTRY_ADDR}" \
  -n "Chimera-6.18-${ENIGMA_REVISION}-Erista" \
  -d "${KERNEL_OUT_DIR}/Image" \
  "${DISTRO_PATH}/uImage" >/dev/null

# 7. Copy initramfs and Erista DTBs + generate nx-plat.dtimg
echo "[INFO] Staging initramfs and Erista Device Trees..."
cp -f "${INITRAMFS_IMG}" "${DISTRO_PATH}/initramfs"
cp -f "${KERNEL_OUT_DIR}/${TARGET_DTB_BASENAME}" "${DISTRO_PATH}/${TARGET_DTB_BASENAME}"
cp -f "${KERNEL_OUT_DIR}/${TARGET_DTB_BASENAME}" "${DISTRO_PATH}/${TARGET_DTB_ALIAS}"

if [[ -f "${KERNEL_OUT_DIR}/nx-plat.dtimg" ]]; then
  cp -f "${KERNEL_OUT_DIR}/nx-plat.dtimg" "${DISTRO_PATH}/nx-plat.dtimg"
else
  DTIMG_ARGS=(
    "${KERNEL_OUT_DIR}/tegra210-odin.dtb" "--id=0x4F44494E" "--rev=0x0"
  )
  [[ -f "${KERNEL_OUT_DIR}/tegra210b01-odin.dtb" ]] && DTIMG_ARGS+=("${KERNEL_OUT_DIR}/tegra210b01-odin.dtb" "--id=0x4F44494E" "--rev=0x1")
  [[ -f "${KERNEL_OUT_DIR}/tegra210b01-vali.dtb" ]] && DTIMG_ARGS+=("${KERNEL_OUT_DIR}/tegra210b01-vali.dtb" "--id=0x56414C49" "--rev=0x0")
  [[ -f "${KERNEL_OUT_DIR}/tegra210b01-fric.dtb" ]] && DTIMG_ARGS+=("${KERNEL_OUT_DIR}/tegra210b01-fric.dtb" "--id=0x46524947" "--rev=0x0")

  python3 "${SCRIPT_DIR}/mkdtimg.py" create \
    "${DISTRO_PATH}/nx-plat.dtimg" \
    --page_size=1000 \
    "${DTIMG_ARGS[@]}"
fi

# 8. Generate customized U-Boot boot.txt and compile boot.scr
echo "[INFO] Generating U-Boot script (boot.txt -> boot.scr)..."
cp -f "${STAGE_ASSETS_DIR}/boot.txt" "${DISTRO_PATH}/boot.txt"

# Set filesystem label id=SWR-CHI and add rootdev/rootfstype support + standalone Erista DTB fallback
gsed -i "s/setenv id SWR-UBU/setenv id ${HEKATE_FS_LABEL}/g" "${DISTRO_PATH}/boot.txt"

# Allow rootdev and rootfstype fromCHIMERA.ini (defaulting to LABEL=SWR-CHI / ext4) and add fallback to tegra210-odin.dtb if dtimg isn't used
cat >> "${DISTRO_PATH}/boot.txt" <<'UBOOT_APPEND_EOF'

# Note: The script above runs bootm at the end of normal execution.
UBOOT_APPEND_EOF

# Inject fallback to tegra210-odin.dtb if nx-plat.dtimg load ever fails, and honor rootdev/rootfstype keys from CHIMERA.ini
gsed -i '/echo "Failed to load dtimg from SD"; exit/c\echo "Falling back to standalone Erista DTB (${prefix}tegra210-odin.dtb)"; load mmc 0:1 ${fdtraddr} ${prefix}tegra210-odin.dtb; setenv fdtrsize ${filesize}' "${DISTRO_PATH}/boot.txt"
gsed -i 's/setenv bootargs_extra root=LABEL=\${id} rw/if test -n "${rootdev}"; then setenv bootargs_extra root=\/dev\/${rootdev} rootfstype=${rootfstype} rw rootwait; else setenv bootargs_extra root=LABEL=${id} rootfstype=ext4 rw rootwait; fi/g' "${DISTRO_PATH}/boot.txt"

mkimage \
  -A arm64 \
  -O linux \
  -T script \
  -C none \
  -n "Switchroot Chimera Boot Script" \
  -d "${DISTRO_PATH}/boot.txt" \
  "${DISTRO_PATH}/boot.scr" >/dev/null

# 9. Write documented bootloader/ini/CHIMERA.ini
echo "[INFO] Writing Hekate boot configuration: ${INI_PATH}..."
cat > "${INI_PATH}" <<EOF
# ==============================================================================
# bootloader/ini/${HEKATE_INI_NAME} — Hekate L4T Loader Configuration
# Target: Chimera Linux (aarch64) on Nintendo Switch v1 "Erista" (T210 / icosa)
# Kernel: Linux ${LINUX_KERNEL_SERIES} (${ENIGMA_REVISION} linux-nx)
#
# Key Reference (Switchroot L4T Boot Configuration Wiki):
#   l4t=1               Invoke Hekate's built-in L4T loader (loads bl31.bin + bl33.bin)
#   boot_prefixes=...   FAT32 directory containing bl31.bin, bl33.bin, boot.scr, uImage,
#                       initramfs, and nx-plat.dtimg / tegra210-odin.dtb
#   id=${HEKATE_FS_LABEL}          Root filesystem ext4 volume label passed to U-Boot
#   rootdev=mmcblk0p2   SD card partition 2 for Linux rootfs (mmcblk0 = microSD)
#   rootfstype=ext4     Root filesystem type
#   emmc=0              Strictly use microSD (NEVER touch internal eMMC)
#   mainline=1          Enable mainline Linux 6.x boot path in Switchroot U-Boot
#   uart_port=0|2       0 = off; 2 = UART-B (Right Joy-Con rail, 115200 8N1)
# ==============================================================================

[Chimera Linux 6.18 (Erista)]
l4t=1
boot_prefixes=/switchroot/${SWITCHROOT_DISTRO_DIR}/
id=${HEKATE_FS_LABEL}
rootdev=mmcblk0p2
rootfstype=ext4
emmc=0
mainline=1
uart_port=0
icon=/switchroot/${SWITCHROOT_DISTRO_DIR}/icon_chimera_hue.bmp
logopath=/switchroot/${SWITCHROOT_DISTRO_DIR}/logo_chimera.bmp

[Chimera Linux 6.18 (UART-B Joy-Con Debug)]
l4t=1
boot_prefixes=/switchroot/${SWITCHROOT_DISTRO_DIR}/
id=${HEKATE_FS_LABEL}
rootdev=mmcblk0p2
rootfstype=ext4
emmc=0
mainline=1
uart_port=2
earlycon=1
icon=/switchroot/${SWITCHROOT_DISTRO_DIR}/icon_chimera_hue.bmp
logopath=/switchroot/${SWITCHROOT_DISTRO_DIR}/logo_chimera.bmp
EOF

# 10. Generate manifest of all files in out/sd-boot/
(
  cd "${DEST_DIR}"
  find bootloader switchroot -type f | sort | xargs sha256sum > MANIFEST.sha256
)

echo "=============================================================================="
echo " Phase 4 Hekate Boot Packaging Complete"
echo "=============================================================================="
echo " Output directory : ${DEST_DIR}"
echo " Manifest         : ${DEST_DIR}/MANIFEST.sha256"
echo "------------------------------------------------------------------------------"
cat "${DEST_DIR}/MANIFEST.sha256"
echo "=============================================================================="
