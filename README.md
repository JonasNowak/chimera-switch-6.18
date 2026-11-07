# Chimera Linux (aarch64) on Nintendo Switch v1 "Erista" — Linux 6.18 (Enigma R20)

[![CI — macOS Environment & Kernel Build](https://github.com/JonasNowak/chimera-switch-6.18/actions/workflows/ci.yml/badge.svg)](https://github.com/JonasNowak/chimera-switch-6.18/actions/workflows/ci.yml)
[![Upstream Tracker & Auto-Rebuild Bot](https://github.com/JonasNowak/chimera-switch-6.18/actions/workflows/upstream-tracker.yml/badge.svg)](https://github.com/JonasNowak/chimera-switch-6.18/actions/workflows/upstream-tracker.yml)

Reproducible **macOS (Apple Silicon)** toolchain, rootfs/initramfs builder, Switchroot/Hekate boot packager, and automated upstream-tracking pipeline for booting **Chimera Linux (`aarch64`)** on an unpatched **Nintendo Switch v1 "Erista" (NVIDIA Tegra X1 T210 / `icosa`)** with the **Enigma R20 kernel (Linux 6.18-based `linux-nx`)**.

The primary milestone of this project is a **headless Linux 6.18 system reachable over USB-C Ethernet (`usb0`, SSH)** that coexists safely alongside an existing Switchroot L4T 4.9 installation on the microSD card without ever touching internal eMMC.

---

## Hardware & Subsystem Status Matrix

> **Honesty about hardware:** The build pipeline, cross-compiled Linux 6.18 (`6.18.0-enigma-r20-erista+`) kernel, Erista Device Tree (`tegra210-odin.dtb`), Chimera Linux `aarch64` rootfs, `initramfs`, and two-partition SD image are verified end-to-end on Apple Silicon macOS. **Physical boot on a Switch v1 Erista console is currently `UNTESTED`** — producing and filing that first Erista hardware bring-up report is a core goal of this repository (see [`docs/TEST-REPORT.md`](docs/TEST-REPORT.md)).

| Subsystem / Feature | Switch Lite "Mariko" (T210B01) Upstream R20 Baseline | Switch v1 "Erista" (T210 / `icosa`) This Project | Notes |
| :--- | :--- | :--- | :--- |
| **Boot Chain** (`Hekate → bl31 → U-Boot → uImage`) | Verified (`tegra210b01-vali.dtb`) | **UNTESTED on hardware** (`tegra210-odin.dtb` / `nx-plat.dtimg`) | Uses official Switchroot L4T loader (`l4t=1`, `mainline=1`, `emmc=0`) |
| **Kernel (`linux-nx` 6.18 + Enigma R20)** | Boots to userspace | **Built & verified (`6.18.0-enigma-r20-erista+`); boot UNTESTED** | Cross-compiled with LLVM/LLD (`ARCH=arm64 LLVM=1`) |
| **microSD Storage (`sdhci-tegra` / `ext4`)** | Working | **Expected ✓** (built-in `CONFIG_MMC_SDHCI_TEGRA=y`, `CONFIG_EXT4_FS=y`) | Targets `mmcblk0p1` (FAT32) + `mmcblk0p2` (`LABEL=SWR-CHI` ext4) |
| **USB-C Gadget Networking (`usb0` CDC-NCM / RNDIS)** | Working | **Expected ✓** (`tegra-xudc` + ConfigFS + `dnsmasq` DHCP on `10.42.0.2/24`) | Zero-driver CDC-NCM support on macOS, Linux, and Windows 11 |
| **Headless SSH (`openssh` via `dinit`)** | Working | **Expected ✓** (`sshd` + `usb-gadget` enabled in `/etc/dinit.d/boot.d/`) | Default credentials: `chimera` / `chimera` (`root` / `chimera`) |
| **Userland (`Chimera Linux aarch64`)** | N/A (Arch/SteamOS tested upstream) | **Expected ✓** (ARMv8.0 baseline without LSE atomics; `musl` + `dinit` + `chimerautils`) | Compatible with Cortex-A57 (no ARMv8.1 LSE instructions required) |
| **UART-B Serial Console (Right Joy-Con Rail)** | Working | **Expected ✓** (dedicated Hekate entry with `uart_port=2`, 115200 8N1) | Early boot (`earlycon`) and kernel console logging |
| **3D GPU Acceleration (GM20B Nouveau / Mesa)** | ✗ Blocked upstream | **✗ Blocked upstream (Out of Scope)** | Nouveau disabled (`# CONFIG_DRM_NOUVEAU is not set`) per Enigma R20 stability |
| **PCIe Wi-Fi (Broadcom `brcmfmac` / Tegra PCIe)** | ✗ Blocked upstream (LTSSM timeout) | **✗ Blocked upstream (Out of Scope)** | Tracked upstream in Enigma R20/R21 (`enigma-r20-ltssm.patch`) |
| **Audio / Dock / Wayland Desktop** | ✗ Out of scope | **✗ Out of scope** | Scope is strictly headless USB-SSH |

---

## Architecture & Boot Chain

```text
[RCM / Fusée-Gélée] (Switch v1 Erista unpatched BootROM exploit)
        │
        ▼
[Hekate Bootloader] reads SD p1 (FAT32): /bootloader/ini/CHIMERA.ini
        │           (l4t=1, boot_prefixes=/switchroot/chimera/, emmc=0, mainline=1)
        ▼
[Switchroot L4T Loader & ATF] loads /switchroot/chimera/bl31.bin (ARM Trusted Firmware)
        │
        ▼
[Switchroot U-Boot] loads /switchroot/chimera/bl33.bin -> executes /switchroot/chimera/boot.scr
        │           - Loads /switchroot/chimera/uImage       (Linux 6.18.0-enigma-r20-erista+)
        │           - Loads /switchroot/chimera/initramfs    (initramfs-tools gzip cpio)
        │           - Loads /switchroot/chimera/nx-plat.dtimg (SKU 0x4F44494E "ODIN" -> tegra210-odin.dtb)
        ▼
[Linux 6.18 Kernel + Chimera Initramfs]
        │           - Mounts SD p2 (ext4, LABEL=SWR-CHI, /dev/mmcblk0p2) as /
        ▼
[Chimera Linux Userland (dinit PID 1)]
                    - Starts /etc/dinit.d/usb-gadget -> /usr/local/sbin/setup-usb-gadget.sh
                      (ConfigFS CDC-NCM + ACM on tegra-xudc, 10.42.0.2/24 on usb0, dnsmasq DHCP)
                    - Starts /usr/lib/dinit.d/sshd on port 22
```

---

## Ground Rules & Safety Design

1. **Never Touch eMMC:** Every configuration (`emmc=0` in `CHIMERA.ini`, `/etc/fstab` referencing only `LABEL=SWR-CHI` and `/dev/mmcblk0p1`) strictly targets the external microSD card (`mmcblk0`). Internal eMMC (`mmcblk1`) is never mounted or written.
2. **Preserve the L4T 4.9 Rescue Path:** `scripts/make-boot-files.sh` writes exclusively to `bootloader/ini/CHIMERA.ini` and `switchroot/chimera/`. Existing Switchroot L4T 4.9 entries (`bootloader/ini/L4T.ini`, `switchroot/ubuntu/`, etc.) are preserved, and overwriting an existing Chimera staging directory requires an explicit `--force` flag.
3. **Single Source of Truth ([`VERSIONS`](VERSIONS)):** Every upstream git repository, commit hash, Enigma patch revision, Chimera rootfs URL, Switchroot chain binary URL, and SHA256 checksum is pinned in [`VERSIONS`](VERSIONS). No build script hardcodes versions or URLs.
4. **Zero Nintendo Proprietary Artifacts:** This repository contains only scripts, kernel configuration, open-source patches, and documentation. Bootloader chain binaries (`bl31.bin`, `bl33.bin`) are fetched at build time from official Switchroot L4S CI artifacts and verified by SHA256.

---

## Quick Links

- **[Physical Console Quickstart (`docs/QUICKSTART.md`)](docs/QUICKSTART.md):** Step-by-step guide from RCM jig + Hekate to SD card flashing, macOS USB-Ethernet setup, and `ssh chimera@10.42.0.2`.
- **[Reproducible macOS Build Guide (`docs/BUILD.md`)](docs/BUILD.md):** How to run Phases 0–5 from a clean clone on Apple Silicon macOS.
- **[SD Card Partition & File Layout (`docs/SD-LAYOUT.md`)](docs/SD-LAYOUT.md):** Complete annotated file tree of the FAT32 (`SWITCHBOOT`) and ext4 (`SWR-CHI`) partitions.
- **[Troubleshooting & UART Debugging (`docs/TROUBLESHOOTING.md`)](docs/TROUBLESHOOTING.md):** No-boot checklist, Right Joy-Con rail UART-B capture (`115200 8N1`), USB gadget diagnostics, and common Hekate INI pitfalls.
- **[Erista Hardware Bring-Up Report Template (`docs/TEST-REPORT.md`)](docs/TEST-REPORT.md):** Structured report template ready to be filled on first Erista boot and filed upstream at `Garyu-tt/x1SteamOS`.
- **[Automated Upstream Tracking & Merge Policy (`docs/UPDATES.md`)](docs/UPDATES.md):** How `scripts/check-upstream.sh` and `.github/workflows/upstream-tracker.yml` monitor upstream, rebase patches, rebuild the pipeline, and publish releases.

---

## Five-Command Build Summary (macOS Apple Silicon)

```bash
# Phase 0: Install/verify Homebrew dependencies, Colima aarch64 VM & case-sensitive volumes
./scripts/setup-macos.sh
./scripts/verify-env.sh

# Phase 1: Reconstruct Enigma R20 linux-nx 6.18 tree & cross-compile Image, DTBs, modules
./scripts/build-kernel.sh

# Phase 2: Build Chimera Linux aarch64 rootfs with 6.18 modules, dinit sshd & USB gadget
./scripts/build-rootfs.sh

# Phase 3: Build & verify initramfs.img via initramfs-tools inside Chimera chroot
./scripts/build-initramfs.sh

# Phase 4 & 5: Package Hekate/Switchroot boot files and assemble flashable SD image
./scripts/make-boot-files.sh --force
./scripts/make-sd.sh
```

---

## Credits & Upstream Projects

- **[`Garyu-tt/x1SteamOS`](https://github.com/Garyu-tt/x1SteamOS):** Enigma R20/R21 Linux 6.18 patch series (`enigma-r20-base.patch`, `enigma-r20-ltssm.patch`), kernel configuration baseline, and Mariko (T210B01) hardware bring-up documentation.
- **[`l4t-community/kernel/linux-nx`](https://gitlab.com/l4t-community/kernel/linux-nx):** Mainline-tracking Nintendo Switch Linux 6.18 kernel tree (`nx/v6.18-oled`).
- **[Switchroot & `l4t-community/gnu-linux/l4s-pipeline`](https://gitlab.com/l4t-community/gnu-linux/l4s-pipeline):** Official L4T loader chain (`bl31.bin`), Switchroot U-Boot (`bl33.bin`), `boot.txt` script architecture, and Hekate boot configuration standards.
- **[Chimera Linux](https://chimera-linux.org/):** Modern, `musl`-based, FreeBSD-userland (`chimerautils`), `dinit`-powered Linux distribution with first-class `aarch64` (ARMv8.0 baseline) support.
- **[CTCaer / Hekate](https://github.com/CTCaer/hekate):** Custom Nintendo Switch bootloader and L4T loader implementation.

---

## Licensing

This repository uses a split license model matching its components (see [`LICENSES.md`](LICENSES.md) for full details):

- **Kernel Patches & Kernel Configurations (`patches/`, `configs/`, `scripts/macos-host-include/elf.h`):** Licensed under **[GPL-2.0-only](LICENSE-GPL-2.0)**, matching the Linux kernel.
- **Build, Packaging, Verification & Automation Scripts (`scripts/`, `.github/workflows/`, `docs/`):** Licensed under the **[MIT License](LICENSE-MIT)**.
