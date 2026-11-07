#!/usr/bin/env bash
# ==============================================================================
# scripts/check-upstream.sh — Phase 8: Read-Only Upstream Movement Probe
# ==============================================================================
# Queries all upstream sources pinned in VERSIONS and prints a structured JSON
# diff describing any upstream movement:
#   1. linux-nx kernel git repository (branch nx/v6.18-oled)
#   2. x1SteamOS Enigma patch repository & patch revisions (r20, r21+, hashes)
#   3. Chimera Linux live aarch64 rootfs image set (date + SHA256)
#   4. Switchroot L4S bootstack repository
#   5. macOS Homebrew toolchain versions (llvm, dtc, u-boot-tools)
#
# By default, this script is 100% READ-ONLY and modifies zero files.
#
# Flags:
#   --json                        Print JSON report to stdout (default)
#   --output <file>               Also write JSON report to <file>
#   --versions-file <file>        Read pins from custom VERSIONS file
#   --simulate <component>        Simulate an upstream bump (chimera|kernel|enigma|toolchain)
#                                 to test/demonstrate the Phase 8 tracker pipeline
#   --write-versions <file>       Update the target VERSIONS file with detected pins
#                                 (used ONLY by .github/workflows/upstream-tracker.yml)
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

export PATH="/opt/homebrew/opt/coreutils/libexec/gnubin:/opt/homebrew/opt/gnu-sed/libexec/gnubin:/opt/homebrew/bin:${PATH}"

VERSIONS_FILE="${REPO_ROOT}/VERSIONS"
OUT_JSON=""
SIMULATE_COMPONENT=""
WRITE_VERSIONS_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)
      shift
      ;;
    --output|-o)
      OUT_JSON="$2"
      shift 2
      ;;
    --versions-file)
      VERSIONS_FILE="$2"
      shift 2
      ;;
    --simulate)
      SIMULATE_COMPONENT="$2"
      shift 2
      ;;
    --write-versions)
      WRITE_VERSIONS_FILE="$2"
      shift 2
      ;;
    --help|-h)
      cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --json                    Print JSON diff to stdout (default, read-only)
  --output <file>           Write JSON diff to <file>
  --versions-file <file>    Read current pins from <file> (default: ./VERSIONS)
  --simulate <component>    Simulate movement in: chimera | kernel | enigma | toolchain
  --write-versions <file>   Rewrite <file> with new upstream pins (used by CI bot)
EOF
      exit 0
      ;;
    *)
      echo "[ERROR] Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ ! -f "${VERSIONS_FILE}" ]]; then
  echo "[ERROR] VERSIONS file not found: ${VERSIONS_FILE}" >&2
  exit 1
fi

# shellcheck source=../VERSIONS
source "${VERSIONS_FILE}"

CHECKED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# --- 1. Probe linux-nx --------------------------------------------------------
LATEST_LINUX_NX_COMMIT="$(
  git ls-remote "${LINUX_NX_GIT_URL}" "refs/heads/${LINUX_NX_BRANCH}" 2>/dev/null \
    | awk '{print $1}' | head -n 1 || true
)"
if [[ -z "${LATEST_LINUX_NX_COMMIT}" ]]; then
  LATEST_LINUX_NX_COMMIT="${LINUX_NX_COMMIT}"
fi

PINNED_LINUX_NX_COMMIT="${LINUX_NX_COMMIT}"
if [[ "${SIMULATE_COMPONENT}" == "kernel" ]]; then
  PINNED_LINUX_NX_COMMIT="0000000000000000000000000000000000000000"
fi

LINUX_NX_CHANGED="false"
if [[ "${LATEST_LINUX_NX_COMMIT}" != "${PINNED_LINUX_NX_COMMIT}" ]]; then
  LINUX_NX_CHANGED="true"
fi

# --- 2. Probe x1SteamOS (Enigma patches) --------------------------------------
LATEST_X1STEAMOS_COMMIT="$(
  git ls-remote "${X1STEAMOS_GIT_URL}" "refs/heads/${X1STEAMOS_BRANCH}" 2>/dev/null \
    | awk '{print $1}' | head -n 1 || true
)"
if [[ -z "${LATEST_X1STEAMOS_COMMIT}" ]]; then
  LATEST_X1STEAMOS_COMMIT="${X1STEAMOS_COMMIT}"
fi

PINNED_X1STEAMOS_COMMIT="${X1STEAMOS_COMMIT}"
PINNED_ENIGMA_REVISION="${ENIGMA_REVISION}"
LATEST_ENIGMA_REVISION="${ENIGMA_REVISION}"
LATEST_PATCH_1_SHA256="${ENIGMA_PATCH_1_SHA256}"
LATEST_PATCH_2_SHA256="${ENIGMA_PATCH_2_SHA256}"

# If x1SteamOS commit moved, inspect remote patch revisions via shallow sparse clone in temp dir
if [[ "${LATEST_X1STEAMOS_COMMIT}" != "${PINNED_X1STEAMOS_COMMIT}" ]]; then
  TMP_X1="$(mktemp -d)"
  if git clone --quiet --depth 1 "${X1STEAMOS_GIT_URL}" "${TMP_X1}" 2>/dev/null; then
    # Detect highest rXX base patch present in patches/
    detected_rev="$(
      find "${TMP_X1}/patches" -maxdepth 1 -name 'enigma-r*-base.patch' 2>/dev/null \
        | sed -E 's/.*enigma-(r[0-9]+)-base\.patch/\1/' \
        | sort -V | tail -n 1 || true
    )"
    if [[ -n "${detected_rev}" ]]; then
      LATEST_ENIGMA_REVISION="${detected_rev}"
    fi
    if [[ -f "${TMP_X1}/patches/enigma-${LATEST_ENIGMA_REVISION}-base.patch" ]]; then
      LATEST_PATCH_1_SHA256="$(sha256sum "${TMP_X1}/patches/enigma-${LATEST_ENIGMA_REVISION}-base.patch" | awk '{print $1}')"
    fi
    if [[ -f "${TMP_X1}/patches/enigma-${LATEST_ENIGMA_REVISION}-ltssm.patch" ]]; then
      LATEST_PATCH_2_SHA256="$(sha256sum "${TMP_X1}/patches/enigma-${LATEST_ENIGMA_REVISION}-ltssm.patch" | awk '{print $1}')"
    fi
  fi
  rm -rf "${TMP_X1}"
fi

if [[ "${SIMULATE_COMPONENT}" == "enigma" ]]; then
  PINNED_X1STEAMOS_COMMIT="0000000000000000000000000000000000000000"
fi

ENIGMA_CHANGED="false"
if [[ "${LATEST_X1STEAMOS_COMMIT}" != "${PINNED_X1STEAMOS_COMMIT}" ]] || \
   [[ "${LATEST_ENIGMA_REVISION}" != "${PINNED_ENIGMA_REVISION}" ]] || \
   [[ "${LATEST_PATCH_1_SHA256}" != "${ENIGMA_PATCH_1_SHA256}" ]] || \
   [[ "${LATEST_PATCH_2_SHA256}" != "${ENIGMA_PATCH_2_SHA256}" ]]; then
  ENIGMA_CHANGED="true"
fi

# --- 3. Probe Chimera Linux Live Rootfs Images --------------------------------
LATEST_CHIMERA_DATE="$(
  curl -fsSL --retry 2 "${CHIMERA_LIVE_BASE_URL}/" 2>/dev/null \
    | grep -Eo '[0-9]{8}/' | tr -d '/' | sort -n | tail -n 1 || true
)"
if [[ -z "${LATEST_CHIMERA_DATE}" ]]; then
  LATEST_CHIMERA_DATE="${CHIMERA_IMAGE_DATE}"
fi

LATEST_CHIMERA_FILENAME="chimera-linux-aarch64-ROOTFS-${LATEST_CHIMERA_DATE}-${CHIMERA_ROOTFS_FLAVOR}.tar.gz"
LATEST_CHIMERA_URL="${CHIMERA_LIVE_BASE_URL}/${LATEST_CHIMERA_DATE}/${LATEST_CHIMERA_FILENAME}"
LATEST_CHIMERA_SHA256="${CHIMERA_ROOTFS_SHA256}"

if [[ "${LATEST_CHIMERA_DATE}" != "${CHIMERA_IMAGE_DATE}" ]]; then
  fetched_sha="$(
    curl -fsSL --retry 2 "${CHIMERA_LIVE_BASE_URL}/${LATEST_CHIMERA_DATE}/sha256sums.txt" 2>/dev/null \
      | awk -v fname="${LATEST_CHIMERA_FILENAME}" '$2 == fname {print $1}' | head -n 1 || true
  )"
  if [[ -n "${fetched_sha}" ]]; then
    LATEST_CHIMERA_SHA256="${fetched_sha}"
  fi
fi

PINNED_CHIMERA_DATE="${CHIMERA_IMAGE_DATE}"
PINNED_CHIMERA_SHA256="${CHIMERA_ROOTFS_SHA256}"
if [[ "${SIMULATE_COMPONENT}" == "chimera" ]]; then
  PINNED_CHIMERA_DATE="20261001"
  PINNED_CHIMERA_SHA256="0000000000000000000000000000000000000000000000000000000000000000"
fi

CHIMERA_CHANGED="false"
if [[ "${LATEST_CHIMERA_DATE}" != "${PINNED_CHIMERA_DATE}" ]] || \
   [[ "${LATEST_CHIMERA_SHA256}" != "${PINNED_CHIMERA_SHA256}" ]]; then
  CHIMERA_CHANGED="true"
fi

# --- 4. Probe Switchroot L4S Pipeline -----------------------------------------
LATEST_L4S_COMMIT="$(
  git ls-remote "${L4S_PIPELINE_GIT_URL}" "HEAD" 2>/dev/null \
    | awk '{print $1}' | head -n 1 || true
)"
if [[ -z "${LATEST_L4S_COMMIT}" ]]; then
  LATEST_L4S_COMMIT="${L4S_PIPELINE_COMMIT}"
fi

LATEST_L4S_ASSETS_URL="https://gitlab.com/l4t-community/gnu-linux/l4s-pipeline/-/archive/${LATEST_L4S_COMMIT}/l4s-pipeline-${LATEST_L4S_COMMIT}.tar.gz?path=scripts/bootloader/assets"
LATEST_L4S_ASSETS_SHA256="${L4S_BOOT_ASSETS_SHA256}"

L4S_CHANGED="false"
if [[ "${LATEST_L4S_COMMIT}" != "${L4S_PIPELINE_COMMIT}" ]]; then
  L4S_CHANGED="true"
  tmp_l4s_sha="$(curl -fsSL --retry 2 "${LATEST_L4S_ASSETS_URL}" 2>/dev/null | sha256sum | awk '{print $1}' || true)"
  if [[ -n "${tmp_l4s_sha}" ]]; then
    LATEST_L4S_ASSETS_SHA256="${tmp_l4s_sha}"
  fi
fi

# --- 5. Probe Homebrew Toolchain Versions -------------------------------------
LATEST_LLVM_PIN="${HOMEBREW_LLVM_PIN}"
LATEST_DTC_PIN="${HOMEBREW_DTC_PIN}"
LATEST_UBOOT_PIN="${HOMEBREW_UBOOT_TOOLS_PIN}"

if command -v brew >/dev/null 2>&1; then
  brew_llvm="$(brew info --json=v2 llvm 2>/dev/null | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["formulae"][0]["versions"]["stable"])' 2>/dev/null || true)"
  brew_dtc="$(brew info --json=v2 dtc 2>/dev/null | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["formulae"][0]["versions"]["stable"])' 2>/dev/null || true)"
  brew_uboot="$(brew info --json=v2 u-boot-tools 2>/dev/null | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["formulae"][0]["versions"]["stable"])' 2>/dev/null || true)"
  [[ -n "${brew_llvm}" ]] && LATEST_LLVM_PIN="${brew_llvm}"
  [[ -n "${brew_dtc}" ]] && LATEST_DTC_PIN="${brew_dtc}"
  [[ -n "${brew_uboot}" ]] && LATEST_UBOOT_PIN="${brew_uboot}"
fi

PINNED_LLVM_PIN="${HOMEBREW_LLVM_PIN}"
if [[ "${SIMULATE_COMPONENT}" == "toolchain" ]]; then
  PINNED_LLVM_PIN="22.1.0"
fi

TOOLCHAIN_CHANGED="false"
if [[ "${LATEST_LLVM_PIN}" != "${PINNED_LLVM_PIN}" ]] || \
   [[ "${LATEST_DTC_PIN}" != "${HOMEBREW_DTC_PIN}" ]] || \
   [[ "${LATEST_UBOOT_PIN}" != "${HOMEBREW_UBOOT_TOOLS_PIN}" ]]; then
  TOOLCHAIN_CHANGED="true"
fi

# --- 6. Evaluate Merge Policy -------------------------------------------------
# Per Phase 8 rules:
# - Routine rebuilds (new Chimera image set, toolchain bumps, clean patch rebase)
#   can auto-merge once CI passes.
# - Any change that touches kernel config, DTB, or boot chain (or new Enigma
#   major revision r21+) is labeled needs-review and waits for a human.
HAS_UPDATES="false"
if [[ "${LINUX_NX_CHANGED}" == "true" ]] || \
   [[ "${ENIGMA_CHANGED}" == "true" ]] || \
   [[ "${CHIMERA_CHANGED}" == "true" ]] || \
   [[ "${L4S_CHANGED}" == "true" ]] || \
   [[ "${TOOLCHAIN_CHANGED}" == "true" ]]; then
  HAS_UPDATES="true"
fi

REQUIRES_MANUAL_REVIEW="false"
REVIEW_REASONS=()
if [[ "${LATEST_ENIGMA_REVISION}" != "${PINNED_ENIGMA_REVISION}" ]]; then
  REQUIRES_MANUAL_REVIEW="true"
  REVIEW_REASONS+=("enigma_revision_bump:${PINNED_ENIGMA_REVISION}->${LATEST_ENIGMA_REVISION}")
fi
if [[ "${L4S_CHANGED}" == "true" ]]; then
  REQUIRES_MANUAL_REVIEW="true"
  REVIEW_REASONS+=("boot_chain_l4s_pipeline_updated")
fi

AUTO_MERGE_ELIGIBLE="false"
if [[ "${HAS_UPDATES}" == "true" ]] && [[ "${REQUIRES_MANUAL_REVIEW}" == "false" ]]; then
  AUTO_MERGE_ELIGIBLE="true"
fi

REVIEW_REASONS_JSON="[]"
if [[ ${#REVIEW_REASONS[@]} -gt 0 ]]; then
  REVIEW_REASONS_JSON="$(printf '%s\n' "${REVIEW_REASONS[@]}" | python3 -c 'import sys,json; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')"
fi

# --- 7. Optionally write updated VERSIONS (CI bot mode only) ------------------
if [[ -n "${WRITE_VERSIONS_FILE}" ]]; then
  cp "${VERSIONS_FILE}" "${WRITE_VERSIONS_FILE}.tmp"
  gsed -i "s|^LINUX_NX_COMMIT=.*|LINUX_NX_COMMIT=\"${LATEST_LINUX_NX_COMMIT}\"|" "${WRITE_VERSIONS_FILE}.tmp"
  gsed -i "s|^X1STEAMOS_COMMIT=.*|X1STEAMOS_COMMIT=\"${LATEST_X1STEAMOS_COMMIT}\"|" "${WRITE_VERSIONS_FILE}.tmp"
  gsed -i "s|^ENIGMA_REVISION=.*|ENIGMA_REVISION=\"${LATEST_ENIGMA_REVISION}\"|" "${WRITE_VERSIONS_FILE}.tmp"
  gsed -i "s|^ENIGMA_PATCH_1_SHA256=.*|ENIGMA_PATCH_1_SHA256=\"${LATEST_PATCH_1_SHA256}\"|" "${WRITE_VERSIONS_FILE}.tmp"
  gsed -i "s|^ENIGMA_PATCH_2_SHA256=.*|ENIGMA_PATCH_2_SHA256=\"${LATEST_PATCH_2_SHA256}\"|" "${WRITE_VERSIONS_FILE}.tmp"
  gsed -i "s|^CHIMERA_IMAGE_DATE=.*|CHIMERA_IMAGE_DATE=\"${LATEST_CHIMERA_DATE}\"|" "${WRITE_VERSIONS_FILE}.tmp"
  gsed -i "s|^CHIMERA_ROOTFS_FILENAME=.*|CHIMERA_ROOTFS_FILENAME=\"${LATEST_CHIMERA_FILENAME}\"|" "${WRITE_VERSIONS_FILE}.tmp"
  gsed -i "s|^CHIMERA_ROOTFS_URL=.*|CHIMERA_ROOTFS_URL=\"${LATEST_CHIMERA_URL}\"|" "${WRITE_VERSIONS_FILE}.tmp"
  gsed -i "s|^CHIMERA_ROOTFS_SHA256=.*|CHIMERA_ROOTFS_SHA256=\"${LATEST_CHIMERA_SHA256}\"|" "${WRITE_VERSIONS_FILE}.tmp"
  gsed -i "s|^L4S_PIPELINE_COMMIT=.*|L4S_PIPELINE_COMMIT=\"${LATEST_L4S_COMMIT}\"|" "${WRITE_VERSIONS_FILE}.tmp"
  gsed -i "s|^L4S_BOOT_ASSETS_URL=.*|L4S_BOOT_ASSETS_URL=\"${LATEST_L4S_ASSETS_URL}\"|" "${WRITE_VERSIONS_FILE}.tmp"
  gsed -i "s|^L4S_BOOT_ASSETS_SHA256=.*|L4S_BOOT_ASSETS_SHA256=\"${LATEST_L4S_ASSETS_SHA256}\"|" "${WRITE_VERSIONS_FILE}.tmp"
  gsed -i "s|^HOMEBREW_LLVM_PIN=.*|HOMEBREW_LLVM_PIN=\"${LATEST_LLVM_PIN}\"|" "${WRITE_VERSIONS_FILE}.tmp"
  gsed -i "s|^HOMEBREW_DTC_PIN=.*|HOMEBREW_DTC_PIN=\"${LATEST_DTC_PIN}\"|" "${WRITE_VERSIONS_FILE}.tmp"
  gsed -i "s|^HOMEBREW_UBOOT_TOOLS_PIN=.*|HOMEBREW_UBOOT_TOOLS_PIN=\"${LATEST_UBOOT_PIN}\"|" "${WRITE_VERSIONS_FILE}.tmp"
  mv "${WRITE_VERSIONS_FILE}.tmp" "${WRITE_VERSIONS_FILE}"
fi

# --- 8. Format and emit JSON output -------------------------------------------
JSON_REPORT="$(cat <<EOF
{
  "checked_at": "${CHECKED_AT}",
  "has_updates": ${HAS_UPDATES},
  "auto_merge_eligible": ${AUTO_MERGE_ELIGIBLE},
  "requires_manual_review": ${REQUIRES_MANUAL_REVIEW},
  "review_reasons": ${REVIEW_REASONS_JSON},
  "components": {
    "linux_nx": {
      "changed": ${LINUX_NX_CHANGED},
      "branch": "${LINUX_NX_BRANCH}",
      "pinned_commit": "${PINNED_LINUX_NX_COMMIT}",
      "latest_commit": "${LATEST_LINUX_NX_COMMIT}"
    },
    "x1steamos_enigma": {
      "changed": ${ENIGMA_CHANGED},
      "pinned_commit": "${PINNED_X1STEAMOS_COMMIT}",
      "latest_commit": "${LATEST_X1STEAMOS_COMMIT}",
      "pinned_revision": "${PINNED_ENIGMA_REVISION}",
      "latest_revision": "${LATEST_ENIGMA_REVISION}",
      "pinned_base_patch_sha256": "${ENIGMA_PATCH_1_SHA256}",
      "latest_base_patch_sha256": "${LATEST_PATCH_1_SHA256}",
      "pinned_ltssm_patch_sha256": "${ENIGMA_PATCH_2_SHA256}",
      "latest_ltssm_patch_sha256": "${LATEST_PATCH_2_SHA256}"
    },
    "chimera_rootfs": {
      "changed": ${CHIMERA_CHANGED},
      "pinned_date": "${PINNED_CHIMERA_DATE}",
      "latest_date": "${LATEST_CHIMERA_DATE}",
      "pinned_sha256": "${PINNED_CHIMERA_SHA256}",
      "latest_sha256": "${LATEST_CHIMERA_SHA256}",
      "latest_url": "${LATEST_CHIMERA_URL}"
    },
    "l4s_bootstack": {
      "changed": ${L4S_CHANGED},
      "pinned_commit": "${L4S_PIPELINE_COMMIT}",
      "latest_commit": "${LATEST_L4S_COMMIT}"
    },
    "toolchain": {
      "changed": ${TOOLCHAIN_CHANGED},
      "llvm": {
        "pinned": "${PINNED_LLVM_PIN}",
        "latest": "${LATEST_LLVM_PIN}"
      },
      "dtc": {
        "pinned": "${HOMEBREW_DTC_PIN}",
        "latest": "${LATEST_DTC_PIN}"
      },
      "u_boot_tools": {
        "pinned": "${HOMEBREW_UBOOT_TOOLS_PIN}",
        "latest": "${LATEST_UBOOT_PIN}"
      }
    }
  }
}
EOF
)"

if [[ -n "${OUT_JSON}" ]]; then
  mkdir -p "$(dirname "${OUT_JSON}")"
  printf '%s\n' "${JSON_REPORT}" > "${OUT_JSON}"
fi

printf '%s\n' "${JSON_REPORT}"
