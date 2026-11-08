# microSD Card Partition & File Layout Reference

This document details the exact partition table, filesystem labels, and file trees produced by [`scripts/make-boot-files.sh`](../scripts/make-boot-files.sh) and [`scripts/make-sd.sh`](../scripts/make-sd.sh) for booting Chimera Linux (`6.18.0-enigma-r20-erista+`) on a Nintendo Switch v1 "Erista" (`icosa`).

---

## 1. MBR Partition Table (`out/chimera-switch-erista.img`)

| Partition | Linux Device on Switch | Start Sector | Size | MBR Type | Filesystem | Volume Label | Purpose |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **p1** | `/dev/mmcblk0p1` | `2048` (1 MiB) | `256 MiB` (or larger on existing SD) | `0x0c` (W95 FAT32 LBA) | `FAT32` | `SWITCHBOOT` | Hekate bootloader, `bootloader/ini/CHIMERA.ini`, `/switchroot/chimera/` chain + kernel |
| **p2** | `/dev/mmcblk0p2` | `526336` (257 MiB) | `1536 MiB` (expandable via `resize2fs`) | `0x83` (Linux) | `ext4` | `SWR-CHI` | Chimera Linux `aarch64` root filesystem (`/`) |

> **Ground Rule:** Internal Switch eMMC (`/dev/mmcblk1`, `mmcblk1boot0`, `mmcblk1boot1`) is never referenced, mounted, or modified.

---

## 2. Partition 1 (`FAT32`, `/dev/mmcblk0p1`) File Tree

```text
/ (FAT32 — mounted at /boot/switchroot inside Chimera Linux)
├── bootloader/
│   ├── ini/
│   │   ├── CHIMERA.ini                 # Chimera Linux 6.18 Erista boot entries (normal + UART-B debug)
│   │   └── [L4T.ini]                   # (Preserved if co-existing with an L4T 4.9 rescue install)
│   └── [sys/, res/, hekate_ipl.ini]    # Standard CTCaer Hekate files on user's SD card
└── switchroot/
    ├── [ubuntu/]                       # (Preserved if co-existing with an L4T 4.9 rescue install)
    └── chimera/
        ├── README_CONFIG.txt           # Upstream Switchroot Hekate INI key documentation
        ├── bl31.bin                    # ARM Trusted Firmware / L4T Monitor (loaded by Hekate l4t=1)
        ├── bl33.bin                    # Switchroot U-Boot payload (loaded by bl31.bin)
        ├── boot.txt                    # Human-readable U-Boot boot script source
        ├── boot.scr                    # mkimage-wrapped U-Boot script executed by bl33.bin
        ├── uImage                      # Linux 6.18.0-enigma-r20-erista+ Image wrapped via mkimage
        ├── initramfs                   # Gzip-compressed Chimera initramfs (initramfs-tools)
        ├── nx-plat.dtimg               # Android DT image (SKU 0x4F44494E rev 0x0 -> tegra210-odin.dtb)
        ├── tegra210-odin.dtb           # Standalone Switch v1 Erista Device Tree Blob
        ├── tegra210-icosa.dtb          # Alias copy of tegra210-odin.dtb for Erista/icosa tooling
        ├── icon_chimera_hue.bmp        # Hekate More Configs menu icon
        └── logo_chimera.bmp            # Boot splash logo
```

### Verified Boot Chain Checksums (`out/sd-boot/MANIFEST.sha256`)

| File in `/switchroot/chimera/` | Source | Pinned / Verified SHA256 |
| :--- | :--- | :--- |
| `bl31.bin` | Official Switchroot `l4s-pipeline` (`61cdea92af70`) | `27685b5bfc5f465b561c3bef63a919eb3168823ea417f9ecdabe46174fc8e797` |
| `bl33.bin` | Official Switchroot `u-boot` (`12d711634520`) | `087907c9c04aa6dffe6e2171b9e48b76b026baec623d7e9ba2eb9d7842bc795b` |
| `icon_chimera_hue.bmp` | Official Switchroot `l4s-pipeline` | `ab24f86f26182e3a4b533ca3f44946827ab8ace6d70963a73061c492174cb536` |
| `logo_chimera.bmp` | Official Switchroot `l4s-pipeline` | `4a3ac823c0dbd23f9e5d0ba52164bbd04b1ddd4680ef1f6d8012145cb3541afc` |
| `tegra210-odin.dtb` | Built from `linux-nx` (`80f1e68e163a` + R20) | `e3b2fde1a68f4fda5b69553aadb54adf8ff1ed12a7172834e29fcddb392c4fcc` |
| `tegra210-icosa.dtb` | Built from `linux-nx` (`80f1e68e163a` + R20) | `e3b2fde1a68f4fda5b69553aadb54adf8ff1ed12a7172834e29fcddb392c4fcc` |
| `nx-plat.dtimg` | Built via `scripts/mkdtimg.py` | `4c995afac3dc3cbdfcf5144a1632c967a7230d402956ff32bf63b963d7f214f6` |
| `uImage` | `mkimage` wrapper around `out/kernel/Image` | `25b09de0ae475c4981fc16f5c99f043f8069a18c69faa4dd1c292821b446c76a` |

---

## 3. Hekate INI Semantics (`bootloader/ini/CHIMERA.ini`)

Reference: [Switchroot Boot Configuration Wiki](https://wiki.switchroot.org/) and `switchroot/chimera/README_CONFIG.txt`.

| Key | Value in `CHIMERA.ini` | Meaning in Hekate L4T Loader & Switchroot U-Boot |
| :--- | :--- | :--- |
| `l4t=1` | `1` | Instructs Hekate to invoke its built-in L4T loader rather than Horizon/CFW loader. |
| `boot_prefixes` | `/switchroot/chimera/` | Directory on Partition 1 (FAT32) from which Hekate loads `bl31.bin`/`bl33.bin` and U-Boot loads `boot.scr`, `uImage`, `initramfs`, and `nx-plat.dtimg`. |
| `id` | `SWR-CHI` | Filesystem label passed to U-Boot (`root=LABEL=SWR-CHI` fallback). |
| `rootdev` | `mmcblk0p2` | Explicit microSD partition 2 block device passed into kernel `bootargs` (`root=/dev/mmcblk0p2`). |
| `rootfstype` | `ext4` | Root filesystem type passed to kernel (`rootfstype=ext4`). |
| `emmc` | `0` | Forces storage source to microSD (`mmcblk0`), preventing any eMMC (`mmcblk1`) boot path. |
| `mainline` | `1` | Selects the mainline Linux 6.x device-tree and clock/regulator handoff path in Switchroot L4T/U-Boot. |
| `uart_port` | `0` (normal) / `2` (debug) | `0` disables Joy-Con rail UART; `2` routes UART-B (`115200 8N1`) to the Right Joy-Con rail pins. |
| `earlycon` | `1` (debug entry) | Enables early kernel `earlycon=uart8250,mmio32,0x70006040` serial output before the full tty driver initializes. |

---

## 4. Partition 2 (`ext4`, `/dev/mmcblk0p2`, Label `SWR-CHI`) Key File Tree

```text
/ (ext4 — LABEL=SWR-CHI)
├── bin -> usr/bin                      # Chimera UsrMerge symlink (preserved during module install)
├── lib -> usr/lib                      # Chimera UsrMerge symlink (preserved via --keep-directory-symlink)
├── sbin -> usr/bin                     # Chimera UsrMerge symlink
├── boot/
│   ├── initramfs.img                   # Copy of Phase 3 initramfs.img
│   └── switchroot/                     # Mount point for /dev/mmcblk0p1 (FAT32)
├── etc/
│   ├── X11/
│   │   ├── Xwrapper.config             # Allowed console/anybody user permissions for Xorg
│   │   └── xorg.conf.d/
│   │       └── 20-switch-tegra.conf    # Tegra KMS modesetting, Rotate right, AccelMethod none, Touch calibration
│   ├── chimera-switch/
│   │   ├── kernel-release              # "6.18.0-enigma-r20-erista+"
│   │   └── version                     # "0.1.0-erista-alpha"
│   ├── dinit.d/
│   │   ├── usb-gadget                  # dinit service definition for ConfigFS USB networking
│   │   ├── x11-desktop                 # dinit service starting sxwm desktop session on tty1
│   │   └── boot.d/
│   │       ├── sshd -> /usr/lib/dinit.d/sshd
│   │       ├── usb-gadget -> /etc/dinit.d/usb-gadget
│   │       └── x11-desktop -> /etc/dinit.d/x11-desktop
│   ├── doas.conf                       # "permit persist :wheel"
│   ├── fstab                           # Mounts LABEL=SWR-CHI on / and /dev/mmcblk0p1 on /boot/switchroot
│   ├── hostname                        # "chimera-switch"
│   ├── hosts                           # Maps 10.42.0.2 to chimera-switch.local / chimera-switch
│   ├── initramfs-tools/
│   │   ├── conf.d/chimera-switch.conf  # COMPRESS=gzip, MODULES=most
│   │   ├── hooks/tegra210-switch       # Includes all Tegra210 .ko + modules.builtin + setup-usb-gadget.sh
│   │   └── modules                     # ext4, mmc_block, sdhci_tegra, tegra_xudc, dwc3, configfs, etc.
│   └── ssh/
│       └── sshd_config.d/
│           └── 10-chimera-switch.conf  # Enables PasswordAuthentication & PermitRootLogin over USB-SSH
├── home/
│   └── chimera/
│       ├── .config/
│       │   ├── sxwm/sxwmrc             # sxwm dynamic tiling window manager config
│       │   └── sxbar/sxbarc             # sxbar status bar config (battery %, RAM, CPU, IP, clock)
│       └── .xinitrc                    # X11 session launcher (LIBGL_ALWAYS_SOFTWARE=1, sxbar, sxwm)
└── usr/
    ├── bin/
    │   ├── Xorg                        # Xorg display server
    │   ├── dmenu                       # Application launcher
    │   └── urxvt                       # Lightweight terminal emulator
    ├── lib/
    │   ├── dinit.d/sshd                # Chimera OpenSSH dinit service
    │   ├── firmware/brcm/              # Broadcom BCM4356 Wi-Fi firmware files
    │   └── modules/
    │       └── 6.18.0-enigma-r20-erista+/
    │           ├── kernel/             # 33 loadable .ko modules (dwc3.ko, g_ncm.ko, g_ether.ko, ...)
    │           ├── modules.builtin     # 753 built-in modules (ext4, sdhci-tegra, tegra-xudc, ...)
    │           └── modules.dep         # Generated via depmod -a 6.18.0-enigma-r20-erista+
    └── local/
        ├── bin/
        │   ├── sxwm                    # Simple X Window Manager
        │   ├── sxbar                   # Companion status bar
        │   ├── svkbd-mobile-simple     # Suckless virtual touch keyboard
        │   └── start-desktop           # One-command desktop launcher
        └── sbin/
            └── setup-usb-gadget.sh     # ConfigFS CDC-NCM/RNDIS + ACM gadget + dnsmasq DHCP on 10.42.0.2/24
    │       └── 6.18.0-enigma-r20-erista+/
    │           ├── kernel/             # 33 loadable .ko modules (dwc3.ko, g_ncm.ko, g_ether.ko, ...)
    │           ├── modules.builtin     # 753 built-in modules (ext4, sdhci-tegra, tegra-xudc, ...)
    │           └── modules.dep         # Generated via depmod -a 6.18.0-enigma-r20-erista+
    └── local/
        └── sbin/
            └── setup-usb-gadget.sh     # ConfigFS CDC-NCM/RNDIS + ACM gadget + dnsmasq DHCP on 10.42.0.2/24
```
