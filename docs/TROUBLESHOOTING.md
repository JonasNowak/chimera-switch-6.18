# Troubleshooting & Hardware Bring-Up Diagnostics

Because physical Erista (`icosa` / T210) bring-up with the Enigma R20 Linux 6.18 patch set is currently **UNTESTED**, this guide provides a structured diagnostic checklist covering Hekate, U-Boot, early kernel boot, UART-B serial logging on the Right Joy-Con rail, and macOS USB-Ethernet (`usb0`) connectivity.

---

## 1. No-Boot Checklist (By Boot Stage)

### Stage A: Switch Screen Stays Black Before Hekate Loads
- **Symptom:** Pressing Power + Volume Up yields a black screen, and Hekate never appears.
- **Checks:**
  1. Connect USB-C to your Mac and run `system_profiler SPUSBDataType | grep -i APX`.
  2. If `APX` is **not** listed, either the Switch booted into Horizon OS (RCM jig pin 10 did not make contact) or the battery is depleted. Reseat the RCM jig in the Right Joy-Con rail and hold Power for 12s, then press Volume Up + Power.
  3. If `APX` **is** listed, inject `hekate_ctcaer_X.Y.Z.bin` from macOS.

### Stage B: Hekate Error When Tapping `Chimera Linux 6.18 (Erista)`
- **Symptom:** Hekate prints `bl31.bin or bl33.bin not found!` or `Failed to launch L4T!`.
- **Checks:**
  1. Verify `/switchroot/chimera/bl31.bin` and `/switchroot/chimera/bl33.bin` exist on Partition 1 (FAT32).
  2. Verify `boot_prefixes=/switchroot/chimera/` in `/bootloader/ini/CHIMERA.ini` has both a **leading** and **trailing** forward slash (`/`). Missing the trailing slash causes Hekate/U-Boot to look for `/switchroot/chimerauboot.scr`.
  3. Ensure your Hekate version is **v6.0.0 or newer** (older Hekate releases do not support `l4t=1` + `mainline=1`).

### Stage C: Switchroot U-Boot Loads, Then Resets or Halts Before Kernel
- **Symptom:** U-Boot splash logo appears briefly, or U-Boot console reports `Failed to load dtimg from SD` / `Wrong Image Format for bootm command`.
- **Checks:**
  1. Ensure `uImage` (wrapped with `mkimage -A arm64 -O linux -T kernel -C none -a 0x80200000 -e 0x80200000`) is in `/switchroot/chimera/uImage`, **not** a raw `Image`.
  2. Verify both `/switchroot/chimera/nx-plat.dtimg` and `/switchroot/chimera/tegra210-odin.dtb` exist on Partition 1. Our `boot.scr` automatically falls back to `tegra210-odin.dtb` if `dtimg load` fails.
  3. Verify `initramfs` is compressed with **gzip** (`COMPRESS=gzip` in `/etc/initramfs-tools/conf.d/chimera-switch.conf`), as Switchroot U-Boot's ramdisk loader may reject `zstd`-compressed initramfs images unless compiled with `CONFIG_ZSTD`.

### Stage D: Kernel Boots, But Drops to `(initramfs)` Emergency Shell
- **Symptom:** Kernel boots (visible on screen or UART), but halts waiting for root device `/dev/mmcblk0p2` or `LABEL=SWR-CHI`.
- **Checks:**
  1. Verify Partition 2 on the microSD card is formatted as `ext4` with volume label `SWR-CHI` (`e2label /dev/mmcblk0p2 SWR-CHI`).
  2. Check which partition number your Linux rootfs uses in `diskutil list`:
     - If you have an emuMMC partition or Android partitions on the same SD card, your Linux rootfs may be `mmcblk0p3` or `mmcblk0p4` instead of `mmcblk0p2`.
     - Edit `rootdev=mmcblk0p2` in `/bootloader/ini/CHIMERA.ini` on the FAT32 partition to match your actual partition number (or remove `rootdev=` so `boot.scr` uses `root=LABEL=SWR-CHI`).

---

## 2. Capturing Early Boot Logs via Right Joy-Con Rail UART-B (`115200 8N1`)

If the screen remains blank after U-Boot hands off to Linux 6.18 (expected when `simple-framebuffer` or panel driver is inactive), the **Right Joy-Con rail (UART-B)** provides full U-Boot + Linux `earlycon` + `ttyS0` console output and a root login prompt.

### Hardware Pinout (Right Joy-Con Rail — Console Side)

| Console Rail Pin | Signal | Direction (from Switch perspective) | Voltage Level |
| :--- | :--- | :--- | :--- |
| **Pin 1** | `GND` | Ground | `0V` |
| **Pin 5** | `UART-B TX` | Switch transmits → Host UART RX | **`1.8V` logic** (Use a 1.8V TTL USB-UART adapter such as FT232RL/CP2102n with `VIO=1.8V`!) |
| **Pin 8** | `UART-B RX` | Switch receives ← Host UART TX | **`1.8V` logic** |

> **Warning:** Switch Joy-Con rail UART pins use **1.8V CMOS logic**, not 3.3V or 5V. Always use a 1.8V USB-to-UART adapter (or level shifter) to avoid damaging the Tegra210 pad controller.

### Capturing UART Logs on macOS

1. Plug your 1.8V USB-UART adapter into your Mac and find its device node:
   ```bash
   ls /dev/cu.usbserial* /dev/cu.usbmodem*
   ```
2. Start `screen` or `minicom` with logging enabled at **115200 baud, 8N1, no hardware flow control**:
   ```bash
   screen -L -Logfile switch-erista-uart.log /dev/cu.usbserial-XXXX 115200
   ```
3. In Hekate → **More Configs**, select **`Chimera Linux 6.18 (UART-B Joy-Con Debug)`** (which sets `uart_port=2` and `earlycon=1`).
4. All ATF (`bl31`), U-Boot (`bl33`), Linux 6.18 `earlycon`, `initramfs`, and `dinit` boot messages will stream directly to `switch-erista-uart.log`.

---

## 3. Common Hekate INI Mistakes

| Mistake in `bootloader/ini/CHIMERA.ini` | Symptom | Fix |
| :--- | :--- | :--- |
| `boot_prefixes=/switchroot/chimera` (missing trailing `/`) | Hekate fails to locate `/switchroot/chimera/bl31.bin` | Always include leading and trailing slashes: `boot_prefixes=/switchroot/chimera/` |
| `emmc=1` | Attempts to read boot/root from internal eMMC (`mmcblk1`) | Always set `emmc=0` (ground rule: never touch eMMC) |
| Missing `mainline=1` | Switchroot L4T loader sets legacy L4T 4.9 BPMP/clock state, causing Linux 6.18 to hang early in clock init | Always include `mainline=1` |
| Using Mariko DTB (`tegra210b01-vali.dtb`) on Erista | Kernel panics or hangs immediately in EMC/clock/regulator init because Erista is `T210` (`tegra210-odin.dtb`), not `T210B01` | Use `nx-plat.dtimg` / `tegra210-odin.dtb` built by `./scripts/build-kernel.sh` |

---

## 4. Troubleshooting USB-Ethernet (`usb0`) on macOS

1. **USB device does not appear in `system_profiler SPUSBDataType`:**
   - Ensure you are using a data-capable USB-C cable connected directly to the Mac (not a charge-only cable).
   - If you have a USB-ACM serial device (`/dev/cu.usbmodem*`) enumerated by our composite gadget, you can open a serial shell over the same USB-C cable (`screen /dev/cu.usbmodem* 115200`) to inspect `dmesg | grep -E 'xudc|udc|usb|gadget'`.
2. **USB interface appears on macOS, but `ping 10.42.0.2` times out:**
   - Check which macOS interface corresponds to `Switch Erista USB Network`:
     ```bash
     networksetup -listallhardwareports
     ```
   - Manually assign `10.42.0.1/24` on macOS:
     ```bash
     sudo ifconfig en7 inet 10.42.0.1 netmask 255.255.255.0 up
     ```
   - Verify route table on macOS:
     ```bash
     route -n get 10.42.0.2
     ```
