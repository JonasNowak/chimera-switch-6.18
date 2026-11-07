#!/usr/bin/env bash
# ==============================================================================
# scripts/fetch-enigma.sh — Reconstruct Patched Enigma Linux-NX Kernel Tree
# ==============================================================================
# License: MIT (script) / GPL-2.0-only (kernel & patches)
# Clones Garyu-tt/x1SteamOS for reference verification, fetches l4t-community/
# linux-nx at the pinned commit from VERSIONS into the case-sensitive build
# volume, and applies the pinned Enigma patch series (r20 or r21) in order.
# ==============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../VERSIONS
source "${ROOT_DIR}/VERSIONS"

export PATH="/opt/homebrew/opt/coreutils/libexec/gnubin:/opt/homebrew/bin:/opt/homebrew/sbin:${PATH}"

REV="${1:-${ENIGMA_REVISION}}"
FORCE_RESET="${ENIGMA_FORCE_RESET:-0}"
if [[ "${2:-}" == "--reset" || "${1:-}" == "--reset" ]]; then
  FORCE_RESET=1
  [[ "${1:-}" == "--reset" ]] && REV="${ENIGMA_REVISION}"
fi

case "$REV" in
  r20|r21) ;;
  *)
    echo "Usage: $0 [r20|r21] [--reset]" >&2
    exit 2
    ;;
esac

log() { printf "\033[1;34m[fetch-enigma]\033[0m %s\n" "$*"; }
ok()  { printf "\033[1;32m  [OK]\033[0m %s\n" "$*"; }
err() { printf "\033[1;31m  [ERR]\033[0m %s\n" "$*" >&2; }

# 1. Clone / verify upstream x1SteamOS reference repository
X1_DIR="${ROOT_DIR}/work/x1SteamOS"
mkdir -p "${ROOT_DIR}/work"
if [[ ! -d "${X1_DIR}/.git" ]]; then
  log "Cloning upstream reference repo ${X1STEAMOS_GIT_URL}..."
  git clone --quiet "${X1STEAMOS_GIT_URL}" "${X1_DIR}"
fi
git -C "${X1_DIR}" fetch --quiet origin "${X1STEAMOS_COMMIT}" 2>/dev/null || true
git -C "${X1_DIR}" checkout --quiet --detach "${X1STEAMOS_COMMIT}"
ACTUAL_X1_SHA="$(git -C "${X1_DIR}" rev-parse HEAD)"
if [[ "${ACTUAL_X1_SHA}" != "${X1STEAMOS_COMMIT}" ]]; then
  err "x1SteamOS commit mismatch: expected ${X1STEAMOS_COMMIT}, got ${ACTUAL_X1_SHA}"
  exit 1
fi
ok "Verified upstream x1SteamOS at ${ACTUAL_X1_SHA}"

# 2. Verify SHA256 of pinned patch files
PATCHES=(
  "${ROOT_DIR}/${ENIGMA_PATCH_1_FILE}:${ENIGMA_PATCH_1_SHA256}"
  "${ROOT_DIR}/${ENIGMA_PATCH_2_FILE}:${ENIGMA_PATCH_2_SHA256}"
)
if [[ "${REV}" == "r21" ]]; then
  PATCHES+=("${ROOT_DIR}/${ENIGMA_PATCH_R21_FILE}:${ENIGMA_PATCH_R21_SHA256}")
fi

for entry in "${PATCHES[@]}"; do
  pfile="${entry%%:*}"
  psha="${entry##*:}"
  if [[ ! -f "${pfile}" ]]; then
    err "Missing patch file: ${pfile}"
    exit 1
  fi
  actual_sha="$(sha256sum "${pfile}" | awk '{print $1}')"
  if [[ "${actual_sha}" != "${psha}" ]]; then
    err "SHA256 mismatch for ${pfile}: expected ${psha}, got ${actual_sha}"
    exit 1
  fi
  ok "Verified patch ${pfile##*/} (${actual_sha:0:16}...)"
done

# 3. Determine case-sensitive worktree path
DEFAULT_WORKTREE="/Volumes/${APFS_VOLUME_NAME}/linux-enigma"
if [[ ! -d "/Volumes/${APFS_VOLUME_NAME}" ]]; then
  DEFAULT_WORKTREE="${ROOT_DIR}/work/linux-enigma"
fi
DST="${ENIGMA_WORKTREE:-${DEFAULT_WORKTREE}}"
MARKER_FILE="${DST}/.enigma-applied-revision"

# 4. Clone or reuse linux-nx at LINUX_NX_COMMIT
if [[ -d "${DST}/.git" ]]; then
  CURRENT_HEAD="$(git -C "${DST}" rev-parse HEAD 2>/dev/null || echo "")"
  CURRENT_MARKER="$(cat "${MARKER_FILE}" 2>/dev/null || echo "")"
  if [[ "${FORCE_RESET}" == "0" && "${CURRENT_HEAD}" == "${LINUX_NX_COMMIT}" && "${CURRENT_MARKER}" == "${REV}:${LINUX_NX_COMMIT}" ]]; then
    ok "Reusing verified Enigma ${REV} kernel tree at ${DST} (base ${LINUX_NX_COMMIT:0:12})"
    exit 0
  fi
  log "Resetting existing kernel worktree at ${DST} to ${LINUX_NX_COMMIT}..."
  git -C "${DST}" reset --hard --quiet "${LINUX_NX_COMMIT}" || {
    git -C "${DST}" fetch --depth 1 origin "${LINUX_NX_COMMIT}"
    git -C "${DST}" checkout --detach -f "${LINUX_NX_COMMIT}"
  }
  git -C "${DST}" clean -fd --quiet
else
  log "Fetching linux-nx (${LINUX_NX_GIT_URL}) at commit ${LINUX_NX_COMMIT} into ${DST}..."
  mkdir -p "${DST}"
  git -C "${DST}" init --quiet
  git -C "${DST}" remote add origin "${LINUX_NX_GIT_URL}"
  if git -C "${DST}" fetch --depth 1 origin "${LINUX_NX_COMMIT}"; then
    git -C "${DST}" checkout --detach --quiet FETCH_HEAD
  else
    log "Shallow commit fetch unsupported by remote; falling back to blobless clone..."
    rm -rf "${DST}"
    git clone --filter=blob:none "${LINUX_NX_GIT_URL}" "${DST}"
    git -C "${DST}" checkout --detach "${LINUX_NX_COMMIT}"
  fi
fi

ACTUAL_KERNEL_SHA="$(git -C "${DST}" rev-parse HEAD)"
if [[ "${ACTUAL_KERNEL_SHA}" != "${LINUX_NX_COMMIT}" ]]; then
  err "linux-nx HEAD (${ACTUAL_KERNEL_SHA}) does not match pinned LINUX_NX_COMMIT (${LINUX_NX_COMMIT})"
  exit 1
fi
ok "Checked out linux-nx base commit ${ACTUAL_KERNEL_SHA}"

# 5. Apply Enigma patches in documented order
for entry in "${PATCHES[@]}"; do
  pfile="${entry%%:*}"
  log "Applying ${pfile##*/}..."
  git -C "${DST}" apply --check "${pfile}"
  git -C "${DST}" apply "${pfile}"
done

echo "${REV}:${LINUX_NX_COMMIT}" > "${MARKER_FILE}"
ok "Enigma ${REV} kernel sources reconstructed at ${DST}"
git -C "${DST}" diff --stat
