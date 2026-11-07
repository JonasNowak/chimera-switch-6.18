# Reproducible macOS (Apple Silicon) Build Guide

Every build artifact in this repository is generated from a clean clone on **macOS (Apple Silicon / `arm64`)** using five deterministic scripts that read all pins from the top-level [`VERSIONS`](../VERSIONS) file.

---

## 1. Host Architecture & Case-Sensitivity Strategy

macOS uses **case-insensitive APFS** by default, which breaks the Linux kernel source tree (e.g., `include/uapi/linux/netfilter/xt_CONNMARK.h` vs `xt_connmark.h`) and Linux rootfs extraction.

`scripts/setup-macos.sh` provisions **both** supported case-sensitive build environments and documents when each is used:

1. **Option 1 — Case-Sensitive APFS Sparse Image (Used for Native LLVM Kernel Cross-Build):**
   ```bash
   hdiutil create -type SPARSE -fs "Case-sensitive APFS" -size 25g -volname "ChimeraBuild" .build-vol/ChimeraBuild.sparseimage
   hdiutil attach .build-vol/ChimeraBuild.sparseimage -mountpoint /Volumes/ChimeraBuild
   ```
   - Mounted at `/Volumes/ChimeraBuild`.
   - Allows compiling the Linux 6.18 kernel natively on macOS with Homebrew LLVM (`make ARCH=arm64 LLVM=1`) at full Apple Silicon M-series disk and CPU speed without VM filesystem overhead.
2. **Option 2 — Docker Named Volume (`chimera-switch-build`, Used for Linux Userland Steps & Fallback Kernel Build):**
   ```bash
   docker volume create chimera-switch-build
   ```
   - Formatted as native Linux `ext4` inside the `colima` (`linux/aarch64`, Apple Virtualization.framework `vz`) VM.
   - Used for all Linux-userland steps (`build-rootfs.sh`, `build-initramfs.sh`, `make-sd.sh`) and supported as a 100% containerized fallback for `build-kernel.sh --container`.

### Native macOS Kernel Host Compatibility (`scripts/macos-host-include/`)

When cross-compiling the Linux 6.18 kernel natively on macOS (`make ARCH=arm64 LLVM=1`), Kbuild compiles a few host utilities (`scripts/sorttable`, `scripts/mod/modpost`, `scripts/kallsyms`, `usr/gen_init_cpio`) using macOS `clang`. Because the macOS SDK does not ship glibc headers (`<elf.h>`, `<endian.h>`, `<byteswap.h>`, `<features.h>`) and defines `uuid_t` in `<unistd.h>`, this repository includes [`scripts/macos-host-include/`](../scripts/macos-host-include/) passed via `HOSTCFLAGS`:
- Provides standard ELF64/ELF32 struct definitions (`elf.h`), byte-order macros (`endian.h`, `byteswap.h`), `_UUID_T` guard, `O_LARGEFILE=0`, and a POSIX fallback stub for `copy_file_range()` in `usr/gen_init_cpio.c`.
- If a future upstream kernel introduces additional Linux-only host tools, `./scripts/build-kernel.sh --container` automatically runs the exact same build inside an `aarch64` `debian:trixie-slim` container.

---

## 2. Step-by-Step Build Pipeline

### Phase 0: Environment Setup & Verification

```bash
./scripts/setup-macos.sh
./scripts/verify-env.sh
```

- Installs missing Homebrew packages: `llvm`, `lld`, `dtc`, `cpio`, `gnu-sed`, `gnu-tar`, `findutils`, `coreutils`, `pigz`, `xz`, `zstd`, `u-boot-tools`, `gh`, `docker`, `colima`.
- Starts the `colima` `linux/aarch64` VM (`vz` driver).
- Creates and mounts `/Volumes/ChimeraBuild` and the `chimera-switch-build` Docker volume.
- `scripts/verify-env.sh` prints a 23-point PASS/FAIL dependency matrix and exits nonzero if any check fails.

### Phase 1: Enigma R20 Kernel for Erista (`scripts/build-kernel.sh`)

```bash
# Default: native macOS LLVM cross-build on /Volumes/ChimeraBuild
./scripts/build-kernel.sh

# Optional: build inside aarch64 Debian container on Docker volume
./scripts/build-kernel.sh --container
```

1. Invokes [`scripts/fetch-enigma.sh`](../scripts/fetch-enigma.sh) to clone `l4t-community/kernel/linux-nx` at the pinned `LINUX_NX_COMMIT` (`80f1e68e163ac77d688f0244b03cf05f791b4781`) onto `/Volumes/ChimeraBuild/linux-enigma`.
2. Verifies SHA256 checksums and applies [`patches/enigma-r20-base.patch`](../patches/enigma-r20-base.patch) followed by [`patches/enigma-r20-ltssm.patch`](../patches/enigma-r20-ltssm.patch).
3. Applies [`configs/chimera-erista-r20.config`](../configs/chimera-erista-r20.config) (`CONFIG_LOCALVERSION="-enigma-r20-erista"`).
4. Compiles `Image`, modules (`33` `.ko` + `753` built-in), and the Erista Device Tree (`nvidia/tegra210-odin.dtb`, aliased as `tegra210-icosa.dtb`).
5. Outputs verified artifacts to `out/kernel/`:
   - `out/kernel/Image` (`Linux kernel ARM64 boot executable Image, little-endian, 4K pages`)
   - `out/kernel/tegra210-odin.dtb` & `out/kernel/tegra210-icosa.dtb`
   - `out/kernel/modules.tar.gz`
   - `out/kernel/kernel.config`, `out/kernel/kernel.release`, `out/kernel/BUILD-INFO.txt`, `out/kernel/SHA256SUMS`

### Phase 2: Chimera Linux `aarch64` Rootfs (`scripts/build-rootfs.sh`)

```bash
./scripts/build-rootfs.sh
```

1. Downloads `chimera-linux-aarch64-ROOTFS-20261103-full.tar.gz` and verifies its SHA256 against [`VERSIONS`](../VERSIONS).
2. Inside the `linux/aarch64` container on `/build/chimera-rootfs`:
   - Extracts the base rootfs and installs `out/kernel/modules.tar.gz` with `--keep-directory-symlink` (preserving Chimera's UsrMerge `/lib -> usr/lib` layout).
   - Configures `/etc/hostname` (`chimera-switch`), `/etc/hosts`, and `/etc/fstab` (`LABEL=SWR-CHI` on `/`, `/dev/mmcblk0p1` on `/boot/switchroot`).
   - Runs `apk update && apk upgrade` and installs headless/networking tooling (`openssh`, `openssh-dinit`, `iproute2`, `dnsmasq`, `opendoas`, `initramfs-tools`, `kmod`, `e2fsprogs`, `dosfstools`, `util-linux`, `usbutils`, `pciutils`, `tmux`, `htop`, `nano`).
   - Installs `/usr/local/sbin/setup-usb-gadget.sh` and enables both `sshd` and `usb-gadget` in `/etc/dinit.d/boot.d/`.
   - Creates user `chimera` (`wheel` group, password `chimera`, `doas` enabled) and sets root password `chimera`.
3. Outputs `out/rootfs.tar.zst` and `out/rootfs.tar.zst.sha256`.

### Phase 3: Initramfs (`scripts/build-initramfs.sh`)

```bash
./scripts/build-initramfs.sh
```

1. Runs `mkinitramfs` (`initramfs-tools`) inside the `aarch64` Chimera chroot against `6.18.0-enigma-r20-erista+`.
2. Includes Tegra210 storage (`ext4`, `mmc_block`, `sdhci-tegra`) and USB gadget drivers (`tegra-xudc`, `phy-tegra-xusb`, `dwc3`, `configfs`, `libcomposite`, `u_ether`, `usb_f_ncm`, `usb_f_rndis`, `g_ncm`, `g_ether`).
3. Verifies contents with `lsinitramfs` (`out/initramfs.lsinitramfs.txt`) and outputs `out/initramfs.img` (`gzip`-compressed cpio archive).

### Phase 4: Hekate & Switchroot Boot Packaging (`scripts/make-boot-files.sh`)

```bash
./scripts/make-boot-files.sh --force
```

1. Downloads and SHA256-verifies the official Switchroot L4T bootstack files (`bl31.bin`, `bl33.bin`, `boot.txt`, icons) from `l4t-community/gnu-linux/l4s-pipeline` pinned in [`VERSIONS`](../VERSIONS).
2. Wraps `out/kernel/Image` into `out/sd-boot/switchroot/chimera/uImage` via `mkimage` (`load=0x80200000`, `entry=0x80200000`).
3. Builds `nx-plat.dtimg` (`ODIN` SKU `0x4F44494E` rev `0x0` → `tegra210-odin.dtb`) via `scripts/mkdtimg.py`, and copies standalone `tegra210-odin.dtb` and `tegra210-icosa.dtb`.
4. Compiles `boot.txt` → `boot.scr` and generates `out/sd-boot/bootloader/ini/CHIMERA.ini` + `out/sd-boot/MANIFEST.sha256`.

### Phase 5: Flashable Two-Partition SD Image (`scripts/make-sd.sh`)

```bash
./scripts/make-sd.sh
```

1. Builds a 256 MiB FAT32 partition (`SWITCHBOOT`) populated from `out/sd-boot/` and a 1536 MiB ext4 partition (`SWR-CHI`) populated from `out/rootfs.tar.zst`.
2. Assembles `out/chimera-switch-erista.img` (`1.8 GiB` MBR disk image) and `out/chimera-switch-erista.img.sha256`.
