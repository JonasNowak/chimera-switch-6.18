#!/usr/bin/env bash
# ==============================================================================
# scripts/build-kernel.sh — Build Enigma 6.18 Kernel, Modules & DTBs for Erista
# ==============================================================================
# License: MIT (script) / GPL-2.0-only (kernel & config)
# Reconstructs the patched Linux-NX 6.18 kernel tree on the case-sensitive build
# volume, cross-compiles Image, modules, and Tegra210 Erista/icosa DTBs with
# LLVM/Clang (LLVM=1), installs modules into a staging tree, verifies artifacts,
# and outputs:
#   out/kernel/Image
#   out/kernel/tegra210-odin.dtb (canonical Linux-NX Erista/icosa DTB)
#   out/kernel/tegra210-icosa.dtb (alias copy for Erista/icosa)
#   out/kernel/tegra210b01-*.dtb (for Switchroot multi-SKU nx-plat.dtimg packing)
#   out/kernel/modules.tar.gz
#   out/kernel/kernel.release
#   out/kernel/BUILD-INFO.txt
#   out/kernel/SHA256SUMS
# ==============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../VERSIONS
source "${ROOT_DIR}/VERSIONS"

export PATH="/opt/homebrew/opt/llvm/bin:/opt/homebrew/opt/lld/bin:/opt/homebrew/opt/cpio/bin:/opt/homebrew/opt/gnu-sed/libexec/gnubin:/opt/homebrew/opt/gnu-tar/libexec/gnubin:/opt/homebrew/opt/findutils/libexec/gnubin:/opt/homebrew/opt/coreutils/libexec/gnubin:/opt/homebrew/bin:/opt/homebrew/sbin:${PATH}"

BUILD_MODE="${KERNEL_BUILD_MODE:-macos-llvm}"
REV="${ENIGMA_REVISION}"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"

for arg in "$@"; do
  case "$arg" in
    --container) BUILD_MODE="container-llvm" ;;
    --macos)     BUILD_MODE="macos-llvm" ;;
    r20|r21)     REV="$arg" ;;
    -h|--help)
      echo "Usage: $0 [r20|r21] [--macos|--container]"
      exit 0
      ;;
  esac
done

log()  { printf "\033[1;34m[build-kernel]\033[0m %s\n" "$*"; }
ok()   { printf "\033[1;32m  [OK]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m  [WARN]\033[0m %s\n" "$*"; }
err()  { printf "\033[1;31m  [ERR]\033[0m %s\n" "$*" >&2; }

OUT_KERNEL="${ROOT_DIR}/out/kernel"
mkdir -p "${OUT_KERNEL}"

# Ensure case-sensitive APFS volume is mounted if on macOS
APFS_MOUNT="/Volumes/${APFS_VOLUME_NAME}"
SPARSE_IMG="${ROOT_DIR}/.build-vol/${APFS_VOLUME_NAME}.sparseimage"
if [[ ! -d "${APFS_MOUNT}" && -f "${SPARSE_IMG}" ]]; then
  hdiutil attach "${SPARSE_IMG}" -mountpoint "${APFS_MOUNT}" -nobrowse >/dev/null
fi

if [[ -d "${APFS_MOUNT}" ]]; then
  WORK_BASE="${APFS_MOUNT}"
else
  WORK_BASE="${ROOT_DIR}/work/cs-build"
  mkdir -p "${WORK_BASE}"
fi

export ENIGMA_WORKTREE="${WORK_BASE}/linux-enigma"
BUILD_DIR="${WORK_BASE}/build-${REV}-erista"
STAGING_MOD="${WORK_BASE}/staging-modules-${REV}"

# 1. Reconstruct / verify patched Enigma kernel source tree
log "Step 1/5: Preparing Enigma ${REV} kernel tree at ${ENIGMA_WORKTREE}..."
"${ROOT_DIR}/scripts/fetch-enigma.sh" "${REV}"

# 2. Seed kernel .config
CONFIG_FILE="${ROOT_DIR}/configs/chimera-erista-r20.config"
if [[ ! -f "${CONFIG_FILE}" ]]; then
  err "Missing kernel config: ${CONFIG_FILE}"
  exit 1
fi
mkdir -p "${BUILD_DIR}"
cp "${CONFIG_FILE}" "${BUILD_DIR}/.config"

# 3. Compile Image, modules, and DTBs (macOS LLVM=1 first, container fallback)
build_macos_llvm() {
  log "Step 2/5: Cross-compiling Linux ${LINUX_KERNEL_SERIES} (${REV}) for Erista (${TARGET_SOC}) on macOS with LLVM..."
  local host_cflags="-I${ROOT_DIR}/scripts/macos-host-include -I/opt/homebrew/opt/openssl@3/include -include ${ROOT_DIR}/scripts/macos-host-include/macos_compat.h"
  local host_ldflags="-L/opt/homebrew/opt/openssl@3/lib"

  make -C "${ENIGMA_WORKTREE}" O="${BUILD_DIR}" ARCH=arm64 LLVM=1 \
    HOSTCFLAGS="${host_cflags}" HOSTLDFLAGS="${host_ldflags}" \
    olddefconfig

  make -C "${ENIGMA_WORKTREE}" O="${BUILD_DIR}" ARCH=arm64 LLVM=1 \
    HOSTCFLAGS="${host_cflags}" HOSTLDFLAGS="${host_ldflags}" \
    -j"${JOBS}" \
    Image modules

  make -C "${ENIGMA_WORKTREE}" O="${BUILD_DIR}" ARCH=arm64 LLVM=1 \
    HOSTCFLAGS="${host_cflags}" HOSTLDFLAGS="${host_ldflags}" \
    -j"${JOBS}" \
    nvidia/tegra210-odin.dtb \
    nvidia/tegra210b01-odin.dtb \
    nvidia/tegra210b01-vali.dtb \
    nvidia/tegra210b01-fric.dtb

  log "Step 3/5: Installing kernel modules into staging directory..."
  rm -rf "${STAGING_MOD}"
  mkdir -p "${STAGING_MOD}"
  make -C "${ENIGMA_WORKTREE}" O="${BUILD_DIR}" ARCH=arm64 LLVM=1 \
    HOSTCFLAGS="${host_cflags}" HOSTLDFLAGS="${host_ldflags}" \
    INSTALL_MOD_PATH="${STAGING_MOD}" DEPMOD=/usr/bin/true \
    modules_install
}

build_container_llvm() {
  log "Step 2/5: Building Linux ${LINUX_KERNEL_SERIES} (${REV}) inside aarch64 container (${BUILD_CONTAINER_IMAGE})..."
  docker run --rm \
    -v "${ROOT_DIR}:/workspace" \
    -v "${DOCKER_BUILD_VOLUME}:/build" \
    "${BUILD_CONTAINER_IMAGE}" \
    bash -e -c "
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq
      apt-get install -y -qq git make clang lld llvm bc flex bison libelf-dev libssl-dev cpio kmod rsync xz-utils zstd python3 >/dev/null
      export ENIGMA_WORKTREE=/build/linux-enigma
      /workspace/scripts/fetch-enigma.sh ${REV}
      mkdir -p /build/out-build /build/staging-mods
      cp /workspace/configs/chimera-erista-r20.config /build/out-build/.config
      make -C /build/linux-enigma O=/build/out-build ARCH=arm64 LLVM=1 olddefconfig
      make -C /build/linux-enigma O=/build/out-build ARCH=arm64 LLVM=1 -j${JOBS} Image modules
      make -C /build/linux-enigma O=/build/out-build ARCH=arm64 LLVM=1 -j${JOBS} \
        nvidia/tegra210-odin.dtb \
        nvidia/tegra210b01-odin.dtb \
        nvidia/tegra210b01-vali.dtb \
        nvidia/tegra210b01-fric.dtb
      rm -rf /build/staging-mods/*
      make -C /build/linux-enigma O=/build/out-build ARCH=arm64 LLVM=1 \
        INSTALL_MOD_PATH=/build/staging-mods modules_install
    "
  mkdir -p "${BUILD_DIR}/arch/arm64/boot/dts/nvidia" "${STAGING_MOD}"
  docker run --rm \
    -v "${DOCKER_BUILD_VOLUME}:/build:ro" \
    -v "${BUILD_DIR}:/host-build" \
    -v "${STAGING_MOD}:/host-mods" \
    "${BUILD_CONTAINER_IMAGE}" \
    bash -e -c "
      cp -f /build/out-build/arch/arm64/boot/Image /host-build/arch/arm64/boot/Image
      cp -f /build/out-build/arch/arm64/boot/dts/nvidia/tegra210*.dtb /host-build/arch/arm64/boot/dts/nvidia/
      cp -f /build/out-build/.config /host-build/.config
      cp -f /build/out-build/include/config/kernel.release /host-build/kernel.release
      cp -a /build/staging-mods/. /host-mods/
    "
}

if [[ "${BUILD_MODE}" == "macos-llvm" ]]; then
  if ! build_macos_llvm; then
    warn "macOS host LLVM build encountered an error; falling back to aarch64 container LLVM build..."
    BUILD_MODE="container-llvm"
    build_container_llvm
  fi
else
  build_container_llvm
fi

# 4. Stage outputs into out/kernel/
log "Step 4/5: Packaging kernel artifacts into ${OUT_KERNEL}..."
KREL="$(cat "${BUILD_DIR}/include/config/kernel.release" 2>/dev/null || cat "${BUILD_DIR}/kernel.release")"
echo "${KREL}" > "${OUT_KERNEL}/kernel.release"

cp -f "${BUILD_DIR}/arch/arm64/boot/Image" "${OUT_KERNEL}/Image"
cp -f "${BUILD_DIR}/arch/arm64/boot/dts/nvidia/${TARGET_DTB_BASENAME}" "${OUT_KERNEL}/${TARGET_DTB_BASENAME}"
cp -f "${BUILD_DIR}/arch/arm64/boot/dts/nvidia/${TARGET_DTB_BASENAME}" "${OUT_KERNEL}/${TARGET_DTB_ALIAS}"
for b01_dtb in tegra210b01-odin.dtb tegra210b01-vali.dtb tegra210b01-fric.dtb; do
  if [[ -f "${BUILD_DIR}/arch/arm64/boot/dts/nvidia/${b01_dtb}" ]]; then
    cp -f "${BUILD_DIR}/arch/arm64/boot/dts/nvidia/${b01_dtb}" "${OUT_KERNEL}/${b01_dtb}"
  fi
done
cp -f "${BUILD_DIR}/.config" "${OUT_KERNEL}/kernel.config"

# Clean host build/source symlinks in staging modules directory
rm -f "${STAGING_MOD}/lib/modules/${KREL}/build" "${STAGING_MOD}/lib/modules/${KREL}/source"

# Package modules.tar.gz with root:root ownership (contains lib/modules/<krel>/...)
gtar --owner=0 --group=0 -C "${STAGING_MOD}" -czf "${OUT_KERNEL}/modules.tar.gz" lib/modules/"${KREL}"

# 5. Verify Image file type, DTB presence, and module count
log "Step 5/5: Verifying kernel artifacts..."
IMAGE_TYPE="$(/usr/bin/file -b "${OUT_KERNEL}/Image")"
if [[ "${IMAGE_TYPE}" != *"Linux kernel ARM64 boot executable Image"* ]]; then
  err "Unexpected Image file type: ${IMAGE_TYPE}"
  exit 1
fi
ok "Image verified: ${IMAGE_TYPE}"

for req_dtb in "${OUT_KERNEL}/${TARGET_DTB_BASENAME}" "${OUT_KERNEL}/${TARGET_DTB_ALIAS}"; do
  if [[ ! -s "${req_dtb}" ]]; then
    err "Missing or empty Erista DTB: ${req_dtb}"
    exit 1
  fi
  dtb_type="$(/usr/bin/file -b "${req_dtb}")"
  if [[ "${dtb_type}" != *"Device Tree Blob"* ]]; then
    err "Invalid DTB format for ${req_dtb}: ${dtb_type}"
    exit 1
  fi
  ok "DTB verified: ${req_dtb##*/} (${dtb_type})"
done

KO_COUNT="$(find "${STAGING_MOD}/lib/modules/${KREL}" -name '*.ko' | wc -l | tr -d ' ')"
BUILTIN_COUNT="$(wc -l < "${STAGING_MOD}/lib/modules/${KREL}/modules.builtin" | tr -d ' ')"
if [[ "${KO_COUNT}" -lt 1 || "${BUILTIN_COUNT}" -lt 50 ]]; then
  err "Module verification failed: ${KO_COUNT} loadable .ko modules, ${BUILTIN_COUNT} built-in modules"
  exit 1
fi
ok "Modules verified: ${KO_COUNT} loadable (.ko), ${BUILTIN_COUNT} built-in (release: ${KREL})"

# Record build metadata and SHA256SUMS
LLVM_VER="$(clang --version | head -n 1)"
cat <<EOF > "${OUT_KERNEL}/BUILD-INFO.txt"
PROJECT_VERSION=${PROJECT_VERSION}
BUILD_TIMESTAMP_UTC=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
BUILD_MODE=${BUILD_MODE}
TARGET_BOARD=${TARGET_BOARD} (${TARGET_CODENAME} / ${TARGET_SOC})
LINUX_NX_COMMIT=${LINUX_NX_COMMIT}
ENIGMA_REVISION=${REV}
KERNEL_RELEASE=${KREL}
TOOLCHAIN=${LLVM_VER}
IMAGE_FILE_TYPE=${IMAGE_TYPE}
ERISTA_DTB=${TARGET_DTB_BASENAME} (alias: ${TARGET_DTB_ALIAS})
LOADABLE_MODULE_COUNT=${KO_COUNT}
BUILTIN_MODULE_COUNT=${BUILTIN_COUNT}
EOF

(
  cd "${OUT_KERNEL}"
  sha256sum Image tegra210-*.dtb modules.tar.gz kernel.config > SHA256SUMS
)
ok "Recorded ${OUT_KERNEL}/BUILD-INFO.txt and ${OUT_KERNEL}/SHA256SUMS"
cat "${OUT_KERNEL}/SHA256SUMS"
