#!/usr/bin/env bash
# ==============================================================================
# scripts/make-sd.sh — Phase 5: Flashable Two-Partition SD Image Assembly
# ==============================================================================
# Builds a complete, flashable two-partition microSD disk image from the
# Phase 2–4 outputs:
#   - Partition 1: FAT32 (label: SWITCHBOOT, 256 MiB, MBR type 0x0c)
#                  Contains bootloader/ini/CHIMERA.ini and switchroot/chimera/*
#   - Partition 2: ext4  (label: SWR-CHI, 1536 MiB, MBR type 0x83)
#                  Contains the full Chimera Linux aarch64 rootfs + 6.18 modules
#
# Default output:
#   out/chimera-switch-erista.img
#   out/chimera-switch-erista.img.sha256
#
# Optional direct SD write (requires explicit flag + interactive confirmation):
#   ./scripts/make-sd.sh --device /dev/diskX
#   Never auto-selects a device and refuses internal/system disks via diskutil.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../VERSIONS
source "${REPO_ROOT}/VERSIONS"

export PATH="/opt/homebrew/opt/coreutils/libexec/gnubin:/opt/homebrew/opt/gnu-tar/libexec/gnubin:/opt/homebrew/opt/gnu-sed/libexec/gnubin:/opt/homebrew/bin:${PATH}"

TARGET_DEVICE=""
OUT_IMG="${REPO_ROOT}/out/chimera-switch-erista.img"
BOOT_MB=256
ROOT_MB=2048

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device)
      if [[ -z "${2:-}" ]]; then
        echo "[ERROR] --device requires an explicit disk path (e.g. /dev/disk4)." >&2
        exit 1
      fi
      TARGET_DEVICE="$2"
      shift 2
      ;;
    --output|-o)
      OUT_IMG="$2"
      shift 2
      ;;
    --help|-h)
      cat <<EOF
Usage: $(basename "$0") [--output <path>] [--device /dev/diskX]

Options:
  --output <path>       Output .img file path (default: out/chimera-switch-erista.img)
  --device /dev/diskX   Optional: write image directly to external SD card after
                        strict diskutil safety verification and confirmation prompt.
EOF
      exit 0
      ;;
    *)
      echo "[ERROR] Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

SD_BOOT_DIR="${REPO_ROOT}/out/sd-boot"
ROOTFS_ZST="${REPO_ROOT}/out/rootfs.tar.zst"

# 1. Verify Phase 2–4 inputs exist
if [[ ! -f "${ROOTFS_ZST}" ]]; then
  echo "[ERROR] Phase 2 rootfs archive missing: ${ROOTFS_ZST}" >&2
  echo "        Run ./scripts/build-rootfs.sh first." >&2
  exit 1
fi

for req in \
  "${SD_BOOT_DIR}/bootloader/ini/${HEKATE_INI_NAME}" \
  "${SD_BOOT_DIR}/switchroot/${SWITCHROOT_DISTRO_DIR}/uImage" \
  "${SD_BOOT_DIR}/switchroot/${SWITCHROOT_DISTRO_DIR}/initramfs" \
  "${SD_BOOT_DIR}/switchroot/${SWITCHROOT_DISTRO_DIR}/nx-plat.dtimg" \
  "${SD_BOOT_DIR}/switchroot/${SWITCHROOT_DISTRO_DIR}/${TARGET_DTB_BASENAME}" \
  "${SD_BOOT_DIR}/switchroot/${SWITCHROOT_DISTRO_DIR}/bl31.bin" \
  "${SD_BOOT_DIR}/switchroot/${SWITCHROOT_DISTRO_DIR}/bl33.bin" \
  "${SD_BOOT_DIR}/switchroot/${SWITCHROOT_DISTRO_DIR}/boot.scr"; do
  if [[ ! -f "${req}" ]]; then
    echo "[ERROR] Phase 4 boot artifact missing: ${req}" >&2
    echo "        Run ./scripts/make-boot-files.sh first." >&2
    exit 1
  fi
done

echo "=============================================================================="
echo " Chimera Linux Switch (Erista) — Phase 5: SD Disk Image Builder"
echo "=============================================================================="
echo " Boot partition (p1): ${BOOT_MB} MiB FAT32 (label: SWITCHBOOT)"
echo " Root partition (p2): ${ROOT_MB} MiB ext4  (label: ${HEKATE_FS_LABEL})"
echo " Output image       : ${OUT_IMG}"
echo "=============================================================================="

# Ensure Docker volume exists
if ! docker volume inspect "${DOCKER_BUILD_VOLUME}" >/dev/null 2>&1; then
  docker volume create "${DOCKER_BUILD_VOLUME}" >/dev/null
fi

# 2. Assemble FAT32 + ext4 partitions and MBR disk image inside aarch64 container
docker run --rm --privileged \
  --platform linux/aarch64 \
  -e BOOT_MB="${BOOT_MB}" \
  -e ROOT_MB="${ROOT_MB}" \
  -e HEKATE_FS_LABEL="${HEKATE_FS_LABEL}" \
  -v "${DOCKER_BUILD_VOLUME}:/build" \
  -v "${REPO_ROOT}:/workspace" \
  "${BUILD_CONTAINER_IMAGE}" \
  /bin/bash -c '
    set -euo pipefail

    export DEBIAN_FRONTEND=noninteractive
    if ! command -v mkfs.vfat >/dev/null 2>&1 || ! command -v mcopy >/dev/null 2>&1 || ! command -v sfdisk >/dev/null 2>&1 || ! command -v mkfs.ext4 >/dev/null 2>&1; then
      apt-get update -qq
      apt-get install -y -qq dosfstools mtools fdisk e2fsprogs zstd tar coreutils >/dev/null
    fi

    # Extract clean rootfs tree from out/rootfs.tar.zst for deterministic ext4 creation
    IMG_WORK="/build/sd-image-work"
    ROOTFS_EXTRACT="${IMG_WORK}/rootfs"
    rm -rf "${IMG_WORK}"
    mkdir -p "${ROOTFS_EXTRACT}"

    echo "[CONTAINER] Extracting out/rootfs.tar.zst for ext4 population..."
    zstd -dc /workspace/out/rootfs.tar.zst | tar --numeric-owner -xpf - -C "${ROOTFS_EXTRACT}"

    # Also ensure /boot/initramfs.img is included in rootfs
    cp -f /workspace/out/initramfs.img "${ROOTFS_EXTRACT}/boot/initramfs.img"

    PART1_IMG="${IMG_WORK}/part1-fat32.img"
    PART2_IMG="${IMG_WORK}/part2-ext4.img"

    echo "[CONTAINER] Creating ${BOOT_MB} MiB FAT32 boot partition (SWITCHBOOT)..."
    truncate -s "${BOOT_MB}M" "${PART1_IMG}"
    mkfs.vfat -F 32 -n "SWITCHBOOT" "${PART1_IMG}" >/dev/null
    mcopy -i "${PART1_IMG}" -s /workspace/out/sd-boot/bootloader ::/
    mcopy -i "${PART1_IMG}" -s /workspace/out/sd-boot/switchroot ::/

    echo "[CONTAINER] Creating ${ROOT_MB} MiB ext4 root partition (${HEKATE_FS_LABEL})..."
    truncate -s "${ROOT_MB}M" "${PART2_IMG}"
    mkfs.ext4 -F -q -L "${HEKATE_FS_LABEL}" -O ^metadata_csum_seed -d "${ROOTFS_EXTRACT}" "${PART2_IMG}"

    # Calculate sector geometry (512-byte sectors)
    # 1 MiB alignment = 2048 sectors
    P1_START=2048
    P1_SECTORS=$(( BOOT_MB * 2048 ))
    P2_START=$(( P1_START + P1_SECTORS ))
    P2_SECTORS=$(( ROOT_MB * 2048 ))
    TOTAL_SECTORS=$(( P2_START + P2_SECTORS + 2048 ))
    TOTAL_BYTES=$(( TOTAL_SECTORS * 512 ))

    FINAL_IMG_LOCAL="${IMG_WORK}/chimera-switch-erista.img"
    FINAL_IMG="/workspace/out/chimera-switch-erista.img"
    rm -f "${FINAL_IMG_LOCAL}" "${FINAL_IMG}"
    truncate -s "${TOTAL_BYTES}" "${FINAL_IMG_LOCAL}"

    echo "[CONTAINER] Writing MBR partition table (p1=W95 FAT32 LBA, p2=Linux ext4)..."
    sfdisk --quiet "${FINAL_IMG_LOCAL}" <<EOF
label: dos
unit: sectors

start=${P1_START}, size=${P1_SECTORS}, type=c, bootable
start=${P2_START}, size=${P2_SECTORS}, type=83
EOF

    echo "[CONTAINER] Writing FAT32 partition at sector ${P1_START} (1 MiB offset)..."
    dd if="${PART1_IMG}" of="${FINAL_IMG_LOCAL}" bs=1M seek=1 conv=notrunc status=none

    echo "[CONTAINER] Writing ext4 partition at sector ${P2_START} ($(( 1 + BOOT_MB )) MiB offset)..."
    dd if="${PART2_IMG}" of="${FINAL_IMG_LOCAL}" bs=1M seek="$(( 1 + BOOT_MB ))" conv=notrunc status=none

    echo "[CONTAINER] Verifying partition layout of ${FINAL_IMG}:"
    sfdisk -l "${FINAL_IMG_LOCAL}"

    echo "[CONTAINER] Exporting image to ${FINAL_IMG}..."
    cp -f "${FINAL_IMG_LOCAL}" "${FINAL_IMG}"
    rm -rf "${IMG_WORK}"
  '

# 3. Compute SHA256
(
  cd "$(dirname "${OUT_IMG}")"
  sha256sum "$(basename "${OUT_IMG}")" > "$(basename "${OUT_IMG}").sha256"
)

IMG_SIZE_HUMAN="$(du -h "${OUT_IMG}" | awk '{print $1}')"
IMG_SHA="$(awk '{print $1}' "${OUT_IMG}.sha256")"

echo "=============================================================================="
echo " Phase 5 SD Disk Image Complete"
echo "=============================================================================="
echo " Image file     : ${OUT_IMG} (${IMG_SIZE_HUMAN})"
echo " SHA256         : ${IMG_SHA}"
echo "------------------------------------------------------------------------------"
echo " Flashing Instructions (Recommended — GUI):"
echo "   1. Open balenaEtcher on macOS."
echo "   2. Select image: ${OUT_IMG}"
echo "   3. Select your microSD card reader (NEVER your internal Mac drive)."
echo "   4. Flash, then copy your Hekate payload/bootloader files onto Partition 1"
echo "      (SWITCHBOOT) if flashing a blank card."
echo ""
echo " Co-existing with an Existing L4T 4.9 Rescue Install (Non-Destructive):"
echo "   - Copy out/sd-boot/bootloader/ini/CHIMERA.ini and out/sd-boot/switchroot/chimera/"
echo "     onto your existing FAT32 partition."
echo "   - Extract out/rootfs.tar.zst onto your ext4 Linux partition (labelled SWR-CHI)."
echo "=============================================================================="

# 4. Optional direct write to SD card via --device /dev/diskX
if [[ -n "${TARGET_DEVICE}" ]]; then
  echo ""
  echo "=============================================================================="
  echo " Direct SD Card Flash Requested: ${TARGET_DEVICE}"
  echo "=============================================================================="

  if [[ ! "${TARGET_DEVICE}" =~ ^/dev/disk[0-9]+$ ]]; then
    echo "[ERROR] Invalid device path '${TARGET_DEVICE}'. Must be a whole disk like /dev/disk4." >&2
    exit 1
  fi

  if [[ "${TARGET_DEVICE}" == "/dev/disk0" ]] || [[ "${TARGET_DEVICE}" == "/dev/disk1" ]]; then
    echo "[FATAL] Refusing to touch system disk ${TARGET_DEVICE}!" >&2
    exit 1
  fi

  if ! diskutil info "${TARGET_DEVICE}" >/dev/null 2>&1; then
    echo "[ERROR] Device ${TARGET_DEVICE} not found via diskutil." >&2
    exit 1
  fi

  DISK_INFO="$(diskutil info "${TARGET_DEVICE}")"
  if echo "${DISK_INFO}" | grep -Eqi "Internal:[[:space:]]*Yes"; then
    echo "[FATAL] ${TARGET_DEVICE} is an INTERNAL macOS disk! Aborting immediately." >&2
    exit 1
  fi

  if echo "${DISK_INFO}" | grep -Eqi "Virtual:[[:space:]]*Yes"; then
    echo "[FATAL] ${TARGET_DEVICE} is a virtual disk! Aborting." >&2
    exit 1
  fi

  DISK_BASENAME="$(basename "${TARGET_DEVICE}")"
  RAW_DEVICE="/dev/r${DISK_BASENAME}"

  echo "[WARNING] Full disk write will overwrite the partition table on ${TARGET_DEVICE}."
  echo "          If ${TARGET_DEVICE} currently holds a working L4T 4.9 rescue install"
  echo "          that you want to keep on the SAME card, press Ctrl-C and copy"
  echo "          out/sd-boot/ + out/rootfs.tar.zst instead."
  echo ""
  echo "--- diskutil list ${TARGET_DEVICE} ---"
  diskutil list "${TARGET_DEVICE}"
  echo "--------------------------------------"
  echo ""
  read -r -p "Type 'WRITE-SD-${DISK_BASENAME}' to confirm erasing and flashing ${TARGET_DEVICE}: " CONFIRM_TOKEN
  if [[ "${CONFIRM_TOKEN}" != "WRITE-SD-${DISK_BASENAME}" ]]; then
    echo "[ABORTED] Confirmation token did not match. Disk was NOT modified."
    exit 1
  fi

  echo "[INFO] Unmounting ${TARGET_DEVICE} via diskutil..."
  diskutil unmountDisk "${TARGET_DEVICE}"
  echo "[INFO] Writing ${OUT_IMG} to ${RAW_DEVICE} (sudo required)..."
  sudo dd if="${OUT_IMG}" of="${RAW_DEVICE}" bs=4m status=progress
  sync
  diskutil eject "${TARGET_DEVICE}"
  echo "[OK] Successfully flashed and ejected ${TARGET_DEVICE}."
fi
