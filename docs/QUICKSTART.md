# Physical Console Quickstart Guide (Nintendo Switch v1 "Erista" + macOS)

> **Hardware Status Notice:** This guide walks through booting **Chimera Linux (`aarch64`)** with the **Linux 6.18 Enigma R20 kernel (`6.18.0-enigma-r20-erista+`)** on an unpatched **Nintendo Switch v1 "Erista" (NVIDIA Tegra X1 T210 / `icosa`)**. Because Erista hardware bring-up for the Enigma R20 patch set is **UNTESTED**, please record your boot results in [`docs/TEST-REPORT.md`](TEST-REPORT.md).

---

## Prerequisites

1. **Unpatched Nintendo Switch v1 ("Erista" / `icosa`, 2017–mid 2018)** vulnerable to the Fusée-Gélée BootROM RCM exploit.
2. **RCM Jig** (inserted into the Right Joy-Con rail) + **USB-A to USB-C** (or USB-C to USB-C) data cable connected to your Mac.
3. **microSD Card** (16 GB+ UHS-I recommended).
   - *Tip:* Using a dedicated spare microSD card or adding a second Linux partition while keeping your working **Switchroot L4T 4.9 (Ubuntu/Android)** card intact ensures you always have an instant hardware rescue path.
4. **Hekate (v6.0.x or newer)** release zip downloaded from [`CTCaer/hekate/releases`](https://github.com/CTCaer/hekate/releases).
5. **Built Artifacts in `out/`** (produced by running Phases 0–5 on your Mac; see [`docs/BUILD.md`](BUILD.md)):
   - `out/sd-boot/` (`bootloader/ini/CHIMERA.ini` + `switchroot/chimera/*`)
   - `out/rootfs.tar.zst`
   - `out/chimera-switch-erista.img`

---

## Step 1: Prepare the microSD Card (Two Safe Options)

> **Ground Rule — Never Touch eMMC:** All files and partitions live strictly on the microSD card (`mmcblk0`). Internal Switch eMMC (`mmcblk1`) is never modified.

### Option A: Co-exist with an Existing Switchroot L4T 4.9 Install (Preserves Rescue Path)

Use this option if your microSD card already has Hekate on Partition 1 (FAT32) and an ext4 partition (`mmcblk0p2`) formatted via Hekate's Partition Manager:

1. Insert your Switch microSD card into your Mac (or mount it via **Hekate → Tools → USB Tools → SD Card**).
2. Copy the Chimera boot configuration and bootloader chain onto the FAT32 partition (`/Volumes/SWITCHBOOT` or `/Volumes/SWITCHSD`):
   ```bash
   # Replace /Volumes/SWITCHSD with your mounted FAT32 SD volume name
   SD_FAT32="/Volumes/SWITCHSD"

   mkdir -p "${SD_FAT32}/bootloader/ini" "${SD_FAT32}/switchroot"
   cp -v out/sd-boot/bootloader/ini/CHIMERA.ini "${SD_FAT32}/bootloader/ini/CHIMERA.ini"
   cp -rv out/sd-boot/switchroot/chimera "${SD_FAT32}/switchroot/"
   ```
   *Note:* Your existing `bootloader/ini/L4T.ini` and `switchroot/ubuntu/` directories remain completely untouched!
3. Populate the Linux ext4 partition (`/dev/mmcblk0p2`, volume label `SWR-CHI`) with `out/rootfs.tar.zst`:
   - Since macOS does not mount `ext4` natively, identify the SD card's Linux partition via `diskutil list` (e.g., `/dev/disk4s2`) and write the pre-built ext4 partition image or extract inside Linux/Hekate.
   - Alternatively, you can write just the ext4 partition image onto `/dev/diskXs2` after verifying its partition number with `diskutil list`.

### Option B: Flash a Dedicated microSD Card Using `out/chimera-switch-erista.img`

Use this option with a dedicated spare microSD card so your primary L4T 4.9 SD card stays safely set aside:

1. **Flash via balenaEtcher (Recommended GUI):**
   - Open [balenaEtcher](https://etcher.balena.io/) on macOS.
   - Click **Flash from file** and select `out/chimera-switch-erista.img`.
   - Click **Select target** and choose your external microSD card reader.
   - Click **Flash!**.
   - *(Or via CLI with interactive `diskutil` safety verification: `./scripts/make-sd.sh --device /dev/diskX`)*
2. **Re-mount Partition 1 (`SWITCHBOOT`) and copy Hekate's `bootloader/` core files:**
   - Extract the official `hekate_ctcaer_X.Y.Z_Nyx_X.Y.Z.zip` onto `/Volumes/SWITCHBOOT` so `/Volumes/SWITCHBOOT/bootloader/sys/` and `payload.bin` exist alongside `/Volumes/SWITCHBOOT/bootloader/ini/CHIMERA.ini` and `/Volumes/SWITCHBOOT/switchroot/chimera/`.
3. Safely eject the microSD card on macOS:
   ```bash
   diskutil eject /Volumes/SWITCHBOOT
   ```

---

## Step 2: Enter RCM and Inject Hekate from macOS

1. Power off the Nintendo Switch completely (hold **Power** for 12 seconds if needed).
2. Insert the prepared microSD card into the Switch.
3. Slide the **RCM Jig** into the bottom of the **Right Joy-Con rail**.
4. Hold **Volume Up (`+`)** and press the **Power** button once. The screen will remain **completely black** (this indicates RCM mode).
5. Connect the Switch to your Mac via USB-C and verify the APX/RCM device is visible:
   ```bash
   system_profiler SPUSBDataType | grep -A 6 -i "APX"
   # Expected: Product ID: 0x7321, Vendor ID: 0x0955 (NVIDIA Corp.)
   ```
6. Inject `hekate_ctcaer_X.Y.Z.bin` from macOS using any RCM injector:
   - **WebUSB (Chrome/Brave/Edge on macOS):** Open <https://webcfw.sh/> or <https://atlasnx.github.io/web-cfw-loader/>, select `hekate_ctcaer_X.Y.Z.bin`, and click **Deliver Payload**.
   - **CLI (`fusee-interfacee-tk` / `tegra-rcm`):**
     ```bash
     python3 fusee-launcher.py hekate_ctcaer_X.Y.Z.bin
     ```

---

## Step 3: Select the Chimera Linux Boot Entry in Hekate

1. Once Hekate's Nyx GUI loads on the Switch screen, remove the RCM jig from the Right Joy-Con rail.
2. Tap **More Configs** on the Hekate home screen.
3. You will see two entries from `bootloader/ini/CHIMERA.ini`:
   - **`Chimera Linux 6.18 (Erista)`** — Normal headless USB-SSH boot.
   - **`Chimera Linux 6.18 (UART-B Joy-Con Debug)`** — Enables 115200 8N1 serial console output on the Right Joy-Con rail (`uart_port=2`, `earlycon=1`).
4. Tap **`Chimera Linux 6.18 (Erista)`**.
5. **What happens during boot:**
   - Hekate's L4T loader loads `bl31.bin` (ARM Trusted Firmware) and `bl33.bin` (Switchroot U-Boot).
   - Switchroot U-Boot executes `/switchroot/chimera/boot.scr`, loads `uImage`, `initramfs`, and the Erista Device Tree (`nx-plat.dtimg` SKU `0x4F44494E` / `tegra210-odin.dtb`), and jumps to Linux 6.18.
   - Linux mounts `/dev/mmcblk0p2` (`LABEL=SWR-CHI`) and starts `dinit`.
   - `dinit` runs `/etc/dinit.d/usb-gadget` (`/usr/local/sbin/setup-usb-gadget.sh`) and `/usr/lib/dinit.d/sshd`.

---

## Step 4: Connect over USB-Ethernet (`usb0`) and SSH from macOS

Keep the USB-C cable plugged between the Switch and your Mac. Within 10–20 seconds of kernel boot, the Switch configures its Tegra210 xUDC controller (`tegra-xudc`) as a **CDC-NCM USB Ethernet + ACM Serial Composite Gadget** (`Vendor 0x1d6b`, `Product 0x0104`).

### 4.1 Verify USB Gadget Enumeration on macOS

Run on your Mac:

```bash
system_profiler SPUSBDataType | grep -B 2 -A 10 "Switch Erista USB Network"
```

macOS's built-in `AppleUSBNCM` driver binds automatically (zero third-party kexts or drivers needed).

### 4.2 Automatic DHCP vs. Manual IP Configuration on macOS

The Switch assigns itself **`10.42.0.2/24`** on `usb0` and starts a `dnsmasq` DHCP server handing out **`10.42.0.10`–`10.42.0.50`** to your Mac.

1. Check if your Mac automatically received a `10.42.0.x` IP address:
   ```bash
   ifconfig | grep -B 4 "10.42.0."
   ```
2. **If DHCP did not auto-assign** (or if you prefer a static IP on macOS), find the USB Ethernet interface name (`enX`) and set `10.42.0.1/24`:
   ```bash
   # List network hardware ports to identify the USB gadget interface (e.g. en7 or en8)
   networksetup -listallhardwareports

   # Configure static IP 10.42.0.1/24 on that interface (replace en7 with yours)
   sudo ifconfig en7 inet 10.42.0.1 netmask 255.255.255.0 up
   ```
3. Ping the Switch:
   ```bash
   ping -c 3 10.42.0.2
   ```

### 4.3 SSH into Chimera Linux on the Switch

```bash
ssh chimera@10.42.0.2
```

| Account | Username | Default Password | Privilege Escalation |
| :--- | :--- | :--- | :--- |
| Standard User | `chimera` | `chimera` | `doas <command>` (or `doas -s`) |
| Root User | `root` | `chimera` | Direct root shell (`ssh root@10.42.0.2`) |

### 4.4 First Commands Inside Chimera Linux on the Switch

Once logged in over SSH, run these commands and paste their output into [`docs/TEST-REPORT.md`](TEST-REPORT.md):

```bash
uname -a
cat /proc/cpuinfo
cat /sys/firmware/devicetree/base/model && echo
dinitctl list
ip addr show
lsmod
df -h
dmesg | head -n 80
```

To power off cleanly from SSH:

```bash
doas poweroff
```
