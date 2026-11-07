# Erista (Nintendo Switch v1 / T210 `icosa`) Hardware Bring-Up Report Template

> **Purpose:** The upstream [`Garyu-tt/x1SteamOS`](https://github.com/Garyu-tt/x1SteamOS) Enigma R20 kernel patch set (`Linux 6.18`, `linux-nx` base `80f1e68e163ac77d688f0244b03cf05f791b4781`) was brought up and verified on a **Nintendo Switch Lite ("Mariko" / `T210B01` / `vali`)**, while **Switch v1 ("Erista" / `T210` / `icosa`) remains UNTESTED**.
>
> Copy and complete this template after testing `out/chimera-switch-erista.img` (or `out/sd-boot/` + `out/rootfs.tar.zst`) on a physical Switch v1 Erista console, then file it as an Issue/PR upstream at [`Garyu-tt/x1SteamOS`](https://github.com/Garyu-tt/x1SteamOS) and in this repository.

---

## 1. Environment & Artifact Metadata

| Field | Value |
| :--- | :--- |
| **Date Tested (UTC)** | `YYYY-MM-DD` |
| **Tester GitHub Handle** | `@...` |
| **Console Model & SoC** | Nintendo Switch v1 `HAC-001` ("Erista", NVIDIA Tegra X1 `T210`, codename `icosa` / `odin`) |
| **DRAM Vendor / Size** | `4 GB LPDDR4` (Samsung / Hynix / Micron: `...`) |
| **Hekate Version** | `v6.x.x` |
| **Boot Chain (`bl31.bin` / `bl33.bin`)** | Official Switchroot `l4s-pipeline` (`61cdea92af70`) / `u-boot` (`12d711634520`) |
| **Kernel Commit & Patch Revision** | `linux-nx` `80f1e68e163ac77d688f0244b03cf05f791b4781` + Enigma `r20` (`enigma-r20-base.patch`, `enigma-r20-ltssm.patch`) |
| **Kernel Release String** | `6.18.0-enigma-r20-erista+` |
| **Device Tree Used** | `tegra210-odin.dtb` (`SHA256: e3b2fde1a68f4fda5b69553aadb54adf8ff1ed12a7172834e29fcddb392c4fcc`) via `nx-plat.dtimg` (`SKU 0x4F44494E`) |
| **Userland Distribution** | Chimera Linux `aarch64` (`20261103` full rootfs, `musl` + `dinit` + `chimerautils`) |
| **SD Image SHA256** | `9e085f96c785e2911ad23b238ac2f2fe405a58175b4d0e5bf6390eb15e954f15` |

---

## 2. Erista (`T210`) vs. Mariko (`T210B01`) R20 Baseline Comparison Matrix

Replace `[ ] UNTESTED` with `[x] PASS`, `[!] PARTIAL`, or `[✗] FAIL` during hardware bring-up:

| Subsystem | Mariko (`T210B01` / Switch Lite) Upstream R20 Baseline | Erista (`T210` / Switch v1 `icosa`) Observed Status | Observations / Kernel Log Notes |
| :--- | :--- | :--- | :--- |
| **Hekate L4T Handoff (`bl31` → `bl33`)** | `[x] PASS` | `[ ] UNTESTED` | |
| **U-Boot `dtimg` SKU Selection (`0x4F44494E` `ODIN`)** | `[x] PASS` (`0x56414C49` `VALI`) | `[ ] UNTESTED` | |
| **Linux 6.18 Early Boot (`earlycon` / SMP 4× Cortex-A57)** | `[x] PASS` | `[ ] UNTESTED` | |
| **Tegra210 Clock / Regulator / PMC Init** | `[x] PASS` | `[ ] UNTESTED` | |
| **microSD Card (`sdhci-tegra` `mmcblk0` UHS-I)** | `[x] PASS` | `[ ] UNTESTED` | |
| **Initramfs Root Mount (`ext4` `LABEL=SWR-CHI`)** | `[x] PASS` | `[ ] UNTESTED` | |
| **Chimera `dinit` PID 1 & `musl` Userspace (No LSE)** | N/A | `[ ] UNTESTED` | |
| **Tegra210 xUSB Device Mode (`tegra-xudc` `700d0000.usb`)** | `[x] PASS` | `[ ] UNTESTED` | |
| **ConfigFS USB-Ethernet (`usb0` CDC-NCM `10.42.0.2/24`)** | `[x] PASS` | `[ ] UNTESTED` | |
| **OpenSSH (`sshd`) Login over USB-C from macOS** | `[x] PASS` | `[ ] UNTESTED` | |
| **UART-B Serial Console (Right Joy-Con Rail `115200 8N1`)** | `[x] PASS` | `[ ] UNTESTED` | |
| **Internal Panel Backlight / SimpleFB Console (`tty1`)** | `[!] PARTIAL` | `[ ] UNTESTED` | |
| **Battery Gauge (`bq27441`) & Charger (`bq24190`) I2C** | `[x] PASS` | `[ ] UNTESTED` | |
| **PCIe Controller (`tegra-pcie` LTSSM Link Training)** | `[✗] FAIL` (LTSSM timeout on R20) | `[ ] UNTESTED` | Note: Erista uses standard T210 PEX pads (differs from Mariko B01 UPEX calibration!) |
| **Broadcom Wi-Fi (`brcmfmac` over PCIe)** | `[✗] FAIL` (Blocked by PCIe) | `[ ] UNTESTED` | |
| **GM20B GPU (`nouveau` 3D)** | `[✗] FAIL` (Disabled in config) | `[ ] UNTESTED` | Disabled intentionally (`# CONFIG_DRM_NOUVEAU is not set`) |

---

## 3. Captured Outputs (Fill In After Boot)

### 3.1 `uname -a` & `/proc/cpuinfo`
```text
# Paste output of:
# uname -a
# cat /proc/cpuinfo
```

### 3.2 `dinitctl list` & `ip addr show`
```text
# Paste output of:
# dinitctl list
# ip addr show
```

### 3.3 Full `dmesg` / Right Joy-Con Rail UART-B Boot Log
```text
# Paste full dmesg or switch-erista-uart.log output here:
```

### 3.4 PCIe & xUSB Specific Filtered Log (`dmesg | grep -E -i 'tegra-pcie|pci|xusb|xudc|mmc0'`)
```text
# Particularly valuable for upstream x1SteamOS: does Erista T210 PCIe train
# with enigma-r20-ltssm.patch, or does it exhibit the same LTSSM timeout as Mariko T210B01?
```
