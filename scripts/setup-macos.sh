#!/usr/bin/env bash
# ==============================================================================
# scripts/setup-macos.sh — Idempotent macOS (Apple Silicon) Environment Setup
# ==============================================================================
# License: MIT
# Sets up all host dependencies, container runtime (Docker Desktop or Colima),
# and case-sensitive build volumes (both Case-sensitive APFS sparse image and
# Docker named volume) required to build the Enigma 6.18 kernel, Chimera Linux
# aarch64 rootfs, initramfs, Hekate boot files, and flashable SD card image.
# ==============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../VERSIONS
source "${ROOT_DIR}/VERSIONS"

export PATH="/opt/homebrew/opt/llvm/bin:/opt/homebrew/opt/lld/bin:/opt/homebrew/opt/cpio/bin:/opt/homebrew/bin:/opt/homebrew/sbin:${PATH}"
export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_INSTALL_CLEANUP=1
export HOMEBREW_NO_ENV_HINTS=1

log()  { printf "\033[1;34m[setup-macos]\033[0m %s\n" "$*"; }
ok()   { printf "\033[1;32m  [OK]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m  [WARN]\033[0m %s\n" "$*"; }
err()  { printf "\033[1;31m  [FAIL]\033[0m %s\n" "$*" >&2; }

SKIP_DOCKER="${SETUP_SKIP_DOCKER:-0}"
for arg in "$@"; do
  case "$arg" in
    --skip-docker) SKIP_DOCKER=1 ;;
    -h|--help)
      echo "Usage: $0 [--skip-docker]"
      exit 0
      ;;
  esac
done

log "Phase 0: Setting up macOS build environment for ${TARGET_BOARD} (${TARGET_SOC})..."

# 1. Verify macOS on Apple Silicon (arm64)
if [[ "$(uname -s)" != "Darwin" ]]; then
  err "This setup script requires macOS (Darwin). Found: $(uname -s)"
  exit 1
fi
if [[ "$(uname -m)" != "arm64" ]]; then
  err "Apple Silicon (arm64) is required for native aarch64 container execution. Found: $(uname -m)"
  exit 1
fi
ok "Host OS: macOS $(sw_vers -productVersion) ($(uname -m))"

# 2. Verify Xcode Command Line Tools
if ! xcode-select -p >/dev/null 2>&1; then
  err "Xcode Command Line Tools not found. Run: xcode-select --install"
  exit 1
fi
ok "Xcode CLT: $(xcode-select -p)"

# 3. Verify Homebrew
if ! command -v brew >/dev/null 2>&1; then
  err "Homebrew not found in PATH. Install from https://brew.sh"
  exit 1
fi
ok "Homebrew: $(command -v brew)"

# 4. Install required Homebrew formulae (idempotent)
FORMULAE=(
  llvm
  lld
  dtc
  cpio
  gnu-sed
  gnu-tar
  findutils
  coreutils
  pigz
  xz
  zstd
  u-boot-tools
  gh
)
if [[ "${SKIP_DOCKER}" != "1" ]] && ! command -v docker >/dev/null 2>&1; then
  FORMULAE+=(docker colima)
fi

MISSING_FORMULAE=()
for pkg in "${FORMULAE[@]}"; do
  if ! brew list --formula "$pkg" >/dev/null 2>&1; then
    MISSING_FORMULAE+=("$pkg")
  fi
done

if [[ ${#MISSING_FORMULAE[@]} -gt 0 ]]; then
  log "Installing missing Homebrew packages: ${MISSING_FORMULAE[*]}"
  NONINTERACTIVE=1 brew install "${MISSING_FORMULAE[@]}" </dev/null
else
  ok "All required Homebrew formulae already installed."
fi

# 5. Provision Case-Sensitive Build Volume — Option B: Case-sensitive APFS Sparse Image
SPARSE_DIR="${ROOT_DIR}/.build-vol"
SPARSE_IMG="${SPARSE_DIR}/${APFS_VOLUME_NAME}.sparseimage"
MOUNT_POINT="/Volumes/${APFS_VOLUME_NAME}"

mkdir -p "${SPARSE_DIR}"
if [[ ! -f "${SPARSE_IMG}" ]]; then
  log "Creating Case-sensitive APFS sparse image at ${SPARSE_IMG} (${APFS_SPARSE_SIZE})..."
  hdiutil create -type SPARSE -fs "Case-sensitive APFS" -size "${APFS_SPARSE_SIZE}" -volname "${APFS_VOLUME_NAME}" "${SPARSE_IMG}" >/dev/null
fi

if [[ ! -d "${MOUNT_POINT}" ]]; then
  log "Mounting Case-sensitive APFS sparse image at ${MOUNT_POINT}..."
  hdiutil attach "${SPARSE_IMG}" -mountpoint "${MOUNT_POINT}" -nobrowse >/dev/null
fi
ok "Case-sensitive APFS volume mounted at ${MOUNT_POINT}"

# 6. Verify / Start Container Runtime & Option A: Docker Named Volume
if [[ "${SKIP_DOCKER}" != "1" ]]; then
  if ! docker info >/dev/null 2>&1; then
    if command -v colima >/dev/null 2>&1; then
      log "Attempting to start Colima aarch64 VM..."
      if ! colima start --cpus 6 --memory 8 --disk 60; then
        if [[ "${CI:-}" == "true" || "${GITHUB_ACTIONS:-}" == "true" ]]; then
          warn "Colima / nested virtualization unavailable on CI runner; falling back to --skip-docker."
          SKIP_DOCKER="1"
        else
          err "Failed to start Colima VM."
          exit 1
        fi
      fi
    else
      if [[ "${CI:-}" == "true" || "${GITHUB_ACTIONS:-}" == "true" ]]; then
        warn "Docker daemon not available on CI runner; falling back to --skip-docker."
        SKIP_DOCKER="1"
      else
        err "Docker daemon is not running and Colima is not installed. Start Docker Desktop or install colima."
        exit 1
      fi
    fi
  fi
fi

if [[ "${SKIP_DOCKER}" != "1" ]]; then
  ok "Docker daemon active ($(docker info --format '{{.OSType}}/{{.Architecture}}'))"

  if ! docker volume inspect "${DOCKER_BUILD_VOLUME}" >/dev/null 2>&1; then
    log "Creating case-sensitive Docker named volume: ${DOCKER_BUILD_VOLUME}..."
    docker volume create "${DOCKER_BUILD_VOLUME}" >/dev/null
  fi
  ok "Docker case-sensitive volume ready: ${DOCKER_BUILD_VOLUME}"
else
  warn "Skipping Docker daemon & volume setup (--skip-docker)."
fi

log "Running environment verification matrix..."
"${ROOT_DIR}/scripts/verify-env.sh" $( [[ "${SKIP_DOCKER}" == "1" ]] && echo "--skip-docker" || true )
