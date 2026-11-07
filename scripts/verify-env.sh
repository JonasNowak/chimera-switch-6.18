#!/usr/bin/env bash
# ==============================================================================
# scripts/verify-env.sh — Dependency & Environment Verification Matrix
# ==============================================================================
# License: MIT
# Verifies all macOS host tools, cross-compilation toolchain, case-sensitive
# volumes, container runtime, and pinned VERSIONS file integrity.
# Exits 0 if all required checks pass; exits 1 otherwise.
# ==============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ ! -f "${ROOT_DIR}/VERSIONS" ]]; then
  echo "FATAL: ${ROOT_DIR}/VERSIONS not found." >&2
  exit 1
fi
# shellcheck source=../VERSIONS
source "${ROOT_DIR}/VERSIONS"

export PATH="/opt/homebrew/opt/llvm/bin:/opt/homebrew/opt/lld/bin:/opt/homebrew/opt/cpio/bin:/opt/homebrew/bin:/opt/homebrew/sbin:${PATH}"

SKIP_DOCKER="${VERIFY_SKIP_DOCKER:-0}"
for arg in "$@"; do
  case "$arg" in
    --skip-docker) SKIP_DOCKER=1 ;;
    -h|--help)
      echo "Usage: $0 [--skip-docker]"
      exit 0
      ;;
  esac
done

PASS_COUNT=0
FAIL_COUNT=0

print_row() {
  local component="$1"
  local status="$2"
  local details="$3"
  if [[ "$status" == "PASS" ]]; then
    printf "| %-28s | \033[1;32m%-6s\033[0m | %-50s |\n" "$component" "PASS" "$details"
    PASS_COUNT=$((PASS_COUNT + 1))
  elif [[ "$status" == "SKIP" ]]; then
    printf "| %-28s | \033[1;33m%-6s\033[0m | %-50s |\n" "$component" "SKIP" "$details"
  else
    printf "| %-28s | \033[1;31m%-6s\033[0m | %-50s |\n" "$component" "FAIL" "$details"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

check_cmd() {
  local label="$1"
  local cmd="$2"
  local ver_cmd="${3:-$cmd --version}"
  if command -v "$cmd" >/dev/null 2>&1; then
    local ver
    ver="$( (eval "$ver_cmd" </dev/null 2>&1 || true) | head -n 1 | tr -d '\r\n' | cut -c1-48 )"
    [[ -z "$ver" ]] && ver="installed"
    print_row "$label" "PASS" "$ver"
  else
    print_row "$label" "FAIL" "Command '$cmd' not found in PATH"
  fi
}

echo "=============================================================================================="
echo " Chimera-Switch (${TARGET_BOARD}/${TARGET_SOC}) — macOS Environment Verification Matrix"
echo "=============================================================================================="
printf "| %-28s | %-6s | %-50s |\n" "Component" "Status" "Details / Version"
echo "|------------------------------|--------|----------------------------------------------------|"

# 1. Host OS & Architecture
if [[ "$(uname -s)" == "Darwin" && "$(uname -m)" == "arm64" ]]; then
  print_row "macOS Apple Silicon (arm64)" "PASS" "macOS $(sw_vers -productVersion) ($(uname -m))"
else
  print_row "macOS Apple Silicon (arm64)" "FAIL" "$(uname -s) $(uname -m)"
fi

# 2. Xcode CLT
if xcode-select -p >/dev/null 2>&1; then
  print_row "Xcode Command Line Tools" "PASS" "$(xcode-select -p)"
else
  print_row "Xcode Command Line Tools" "FAIL" "Missing (xcode-select --install)"
fi

# 3. Core tools & Homebrew packages
check_cmd "Homebrew (brew)" "brew" "brew --version"
check_cmd "Git (git)" "git" "git --version"
check_cmd "LLVM Clang (clang)" "clang" "/opt/homebrew/opt/llvm/bin/clang --version"
check_cmd "LLVM Linker (ld.lld)" "ld.lld" "ld.lld --version"
check_cmd "LLVM Archiver (llvm-ar)" "llvm-ar" "llvm-ar --version"
check_cmd "LLVM Objcopy (llvm-objcopy)" "llvm-objcopy" "llvm-objcopy --version"
check_cmd "Device Tree Compiler (dtc)" "dtc" "dtc --version"
check_cmd "U-Boot mkimage" "mkimage" "mkimage -V"
check_cmd "GNU cpio" "cpio" "/opt/homebrew/opt/cpio/bin/cpio --version"
check_cmd "GNU sed (gsed)" "gsed" "gsed --version"
check_cmd "GNU tar (gtar)" "gtar" "gtar --version"
check_cmd "GNU find (gfind)" "gfind" "gfind --version"
check_cmd "GNU coreutils (sha256sum)" "sha256sum" "sha256sum --version"
check_cmd "Parallel gzip (pigz)" "pigz" "pigz --version"
check_cmd "XZ Utils (xz)" "xz" "xz --version"
check_cmd "Zstandard (zstd)" "zstd" "zstd --version"
check_cmd "GitHub CLI (gh)" "gh" "gh --version"

# 4. Verify VERSIONS file pins & local Enigma patches
if [[ -f "${ROOT_DIR}/${ENIGMA_PATCH_1_FILE}" && -f "${ROOT_DIR}/${ENIGMA_PATCH_2_FILE}" ]]; then
  p1_sha="$(sha256sum "${ROOT_DIR}/${ENIGMA_PATCH_1_FILE}" | awk '{print $1}')"
  p2_sha="$(sha256sum "${ROOT_DIR}/${ENIGMA_PATCH_2_FILE}" | awk '{print $1}')"
  if [[ "$p1_sha" == "$ENIGMA_PATCH_1_SHA256" && "$p2_sha" == "$ENIGMA_PATCH_2_SHA256" ]]; then
    print_row "VERSIONS & Enigma Patches" "PASS" "Enigma ${ENIGMA_REVISION} patches SHA256 verified"
  else
    print_row "VERSIONS & Enigma Patches" "FAIL" "Patch SHA256 mismatch against VERSIONS"
  fi
else
  print_row "VERSIONS & Enigma Patches" "FAIL" "Missing patch files in patches/"
fi

# 5. Case-sensitive APFS Volume Probe
APFS_MOUNT="/Volumes/${APFS_VOLUME_NAME}"
if [[ -d "${APFS_MOUNT}" ]]; then
  probe_dir="$(mktemp -d "${APFS_MOUNT}/.cs-probe.XXXXXX")"
  echo "upper" > "${probe_dir}/CaseTest"
  echo "lower" > "${probe_dir}/casetest"
  if [[ "$(cat "${probe_dir}/CaseTest")" == "upper" && "$(cat "${probe_dir}/casetest")" == "lower" ]]; then
    print_row "Case-Sensitive APFS Vol" "PASS" "${APFS_MOUNT} (verified case-sensitive)"
  else
    print_row "Case-Sensitive APFS Vol" "FAIL" "${APFS_MOUNT} is case-insensitive!"
  fi
  rm -rf "${probe_dir}"
else
  print_row "Case-Sensitive APFS Vol" "FAIL" "${APFS_MOUNT} not mounted (run setup-macos.sh)"
fi

# 6. Docker / Colima aarch64 Container Runtime & Named Volume
if [[ "${SKIP_DOCKER}" == "1" ]]; then
  print_row "Docker Engine (aarch64)" "SKIP" "Skipped via --skip-docker"
  print_row "Docker Build Volume" "SKIP" "Skipped via --skip-docker"
else
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    d_arch="$(docker info --format '{{.OSType}}/{{.Architecture}}')"
    if [[ "$d_arch" == "linux/aarch64" || "$d_arch" == "linux/arm64" ]]; then
      print_row "Docker Engine (aarch64)" "PASS" "Active ($d_arch)"
    else
      print_row "Docker Engine (aarch64)" "FAIL" "Unexpected arch: $d_arch"
    fi
    if docker volume inspect "${DOCKER_BUILD_VOLUME}" >/dev/null 2>&1; then
      print_row "Docker Build Volume" "PASS" "Volume '${DOCKER_BUILD_VOLUME}' ready"
    else
      print_row "Docker Build Volume" "FAIL" "Volume '${DOCKER_BUILD_VOLUME}' missing"
    fi
  else
    print_row "Docker Engine (aarch64)" "FAIL" "Docker daemon not reachable"
    print_row "Docker Build Volume" "FAIL" "Requires running Docker daemon"
  fi
fi

echo "=============================================================================================="
echo " Summary: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
echo "=============================================================================================="

if [[ ${FAIL_COUNT} -gt 0 ]]; then
  exit 1
fi
exit 0
