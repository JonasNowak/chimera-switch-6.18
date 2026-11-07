# Automated Upstream Tracking & Rebuild Architecture (Phase 8)

This repository is designed as a self-maintaining pipeline: no human hand-edits version strings inside build scripts. Every upstream source, commit, patch hash, rootfs URL, and toolchain version is pinned in [`VERSIONS`](../VERSIONS) and monitored by [`scripts/check-upstream.sh`](../scripts/check-upstream.sh) and [`.github/workflows/upstream-tracker.yml`](../.github/workflows/upstream-tracker.yml).

---

## 1. How `VERSIONS` Works (Single Source of Truth)

All scripts (`setup-macos.sh`, `verify-env.sh`, `fetch-enigma.sh`, `build-kernel.sh`, `build-rootfs.sh`, `build-initramfs.sh`, `make-boot-files.sh`, `make-sd.sh`, `check-upstream.sh`) start with:

```bash
source "${REPO_ROOT}/VERSIONS"
```

[`VERSIONS`](../VERSIONS) holds five categories of pins:
1. **Upstream Kernel (`linux-nx`):** `LINUX_NX_GIT_URL`, `LINUX_NX_BRANCH` (`nx/v6.18-oled`), `LINUX_NX_COMMIT`, `TARGET_DTB_BASENAME` (`tegra210-odin.dtb`).
2. **Enigma Patch Series (`x1SteamOS`):** `X1STEAMOS_COMMIT`, `ENIGMA_REVISION` (`r20`), and SHA256 hashes of `patches/enigma-r20-base.patch` and `patches/enigma-r20-ltssm.patch`.
3. **Chimera Linux Rootfs:** `CHIMERA_IMAGE_DATE` (`20261103`), `CHIMERA_ROOTFS_URL`, and `CHIMERA_ROOTFS_SHA256`.
4. **Switchroot L4T Boot Chain:** `L4S_PIPELINE_COMMIT`, `L4S_BOOT_ASSETS_URL`, `L4S_BL33_URL`, and individual SHA256 hashes for `bl31.bin`, `bl33.bin`, `boot.txt`, `ini`, and icons.
5. **macOS Homebrew Toolchain Pins:** `HOMEBREW_LLVM_PIN`, `HOMEBREW_DTC_PIN`, `HOMEBREW_UBOOT_TOOLS_PIN`.

---

## 2. Running the Read-Only Upstream Probe Locally (`scripts/check-upstream.sh`)

You can probe all upstream sources at any time without modifying a single file in your working tree:

```bash
./scripts/check-upstream.sh
```

Example JSON output when all pins match upstream:

```json
{
  "checked_at": "2026-11-07T15:00:00Z",
  "has_updates": false,
  "auto_merge_eligible": false,
  "requires_manual_review": false,
  "review_reasons": [],
  "components": {
    "linux_nx": {
      "changed": false,
      "branch": "nx/v6.18-oled",
      "pinned_commit": "80f1e68e163ac77d688f0244b03cf05f791b4781",
      "latest_commit": "80f1e68e163ac77d688f0244b03cf05f791b4781"
    },
    "x1steamos_enigma": {
      "changed": false,
      "pinned_commit": "743408bbcbd26f091ad0772fd862d2079e2efa3e",
      "latest_commit": "743408bbcbd26f091ad0772fd862d2079e2efa3e",
      "pinned_revision": "r20",
      "latest_revision": "r20"
    },
    "chimera_rootfs": {
      "changed": false,
      "pinned_date": "20261103",
      "latest_date": "20261103"
    }
  }
}
```

### Testing / Simulating an Upstream Movement

To test the tracker and JSON diff logic locally or in CI without waiting for upstream to push a new commit:

```bash
# Simulate a Chimera rootfs release bump:
./scripts/check-upstream.sh --simulate chimera

# Simulate a linux-nx kernel commit bump:
./scripts/check-upstream.sh --simulate kernel

# Simulate an Enigma revision / patch change:
./scripts/check-upstream.sh --simulate enigma
```

You can also trigger the GitHub Actions workflow manually via `gh`:

```bash
gh workflow run upstream-tracker.yml
# Or with a simulated upstream bump:
gh workflow run upstream-tracker.yml -f simulate_component=chimera
```

---

## 3. Scheduled Workflow Behavior (`.github/workflows/upstream-tracker.yml`)

The tracker workflow runs daily at **04:15 UTC** (`cron: "15 4 * * *"`) and on manual `workflow_dispatch`:

1. **Probe & Artifact Upload:** Runs `./scripts/check-upstream.sh --output upstream-status.json` and publishes `upstream-status.json` both in the GitHub Actions Step Summary and as a downloadable workflow artifact.
2. **Branch Creation:** If `has_updates` is `true`, checks out `bot/upstream-sync` and rewrites `VERSIONS` with `./scripts/check-upstream.sh --write-versions VERSIONS`.
3. **3-Way Patch Rebase Handling:**
   - Runs `./scripts/fetch-enigma.sh` against the new `LINUX_NX_COMMIT`.
   - If direct `git apply` fails because `linux-nx` moved, the workflow automatically attempts a **3-way git rebase (`git apply -3`)**.
   - **On clean 3-way rebase:** Exports the rebased patch diffs back to `patches/`, updates `ENIGMA_PATCH_*_SHA256` in `VERSIONS`, and includes the updated patch files in the Pull Request.
   - **On rebase conflict:** Stops immediately, leaves `main` untouched, and opens a GitHub Issue (`[Upstream Tracker] Patch rebase conflict against new linux-nx commit`) containing the `VERSIONS` diff and conflicted hunks.
4. **Full End-to-End Pipeline Verification:**
   - Runs Phases 1–5 (`build-kernel.sh` → `build-rootfs.sh` → `build-initramfs.sh` → `make-boot-files.sh --force` → `make-sd.sh`).
   - If any phase fails, opens a GitHub Issue with the build log tail and refuses to merge.

---

## 4. Merge Policy & Release Automation

| Update Category | PR Label Applied | Merge Policy |
| :--- | :--- | :--- |
| New Chimera Linux rootfs image date (`CHIMERA_IMAGE_DATE`) | `automerge` | Auto-merges (`gh pr merge --auto --squash`) once CI passes |
| Homebrew toolchain version bump (`llvm`, `dtc`, `u-boot-tools`) | `automerge` | Auto-merges once CI passes |
| Clean `linux-nx` fast-forward / 3-way patch rebase (same `r20` revision, unchanged `.config` and DTB) | `automerge` | Auto-merges once CI passes |
| New Enigma revision (`r21+`), modified `configs/`, DTB changes, or Switchroot `l4s-pipeline` boot-chain updates | `needs-review` | **Waits for human review and physical console test** |

When an update PR merges to `main` (modifying `VERSIONS`), [`.github/workflows/release.yml`](../.github/workflows/release.yml) automatically builds the full SD image, tags `v<PROJECT_VERSION>-<CHIMERA_IMAGE_DATE>-erista`, and attaches `chimera-switch-erista.img.zst`, `chimera-switch-erista-sd-boot.tar.gz`, `rootfs.tar.zst`, and `SHA256SUMS-RELEASE.txt` to a GitHub Release.

---

## 5. How to Pin or Hold a Version When an Upstream Update Breaks

If an upstream kernel commit or Chimera package update introduces a runtime regression on Erista hardware:

1. **Revert or Hold the Pin in `VERSIONS`:**
   Edit `VERSIONS` on `main` to restore the last known-good commit/date/SHA256.
2. **Temporarily Pause Auto-Updates for a Specific Component:**
   - Close any open `bot/upstream-sync` PR and add the label `hold-upstream` (or disable the scheduled cron in GitHub Actions → **Upstream Tracker & Auto-Rebuild Bot** → **Disable workflow** while investigating).
   - To step between Enigma revisions (e.g., testing `r20` vs `r21`), change `ENIGMA_REVISION="r20"` in `VERSIONS` and run `./scripts/build-kernel.sh`.
