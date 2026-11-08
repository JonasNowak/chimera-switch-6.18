#!/usr/bin/env bash
# ==============================================================================
# scripts/build-rootfs.sh — Phase 2: Build Chimera Linux aarch64 Rootfs
# ==============================================================================
# Downloads and verifies the pinned Chimera Linux aarch64 rootfs tarball from
# VERSIONS, extracts it inside an aarch64 container on the case-sensitive Docker
# volume, installs Phase 1 kernel modules, configures hostname, /etc/fstab,
# user accounts (root + chimera), doas, sshd (enabled in dinit), and a ConfigFS
# USB gadget networking service (CDC-NCM / RNDIS + DHCP via dnsmasq on usb0).
#
# Output:
#   out/rootfs.tar.zst
#   out/rootfs.tar.zst.sha256
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../VERSIONS
source "${REPO_ROOT}/VERSIONS"

export PATH="/opt/homebrew/opt/llvm/bin:/opt/homebrew/opt/lld/bin:/opt/homebrew/opt/coreutils/libexec/gnubin:/opt/homebrew/opt/gnu-tar/libexec/gnubin:/opt/homebrew/opt/gnu-sed/libexec/gnubin:/opt/homebrew/bin:${PATH}"

DOWNLOAD_DIR="${REPO_ROOT}/work/downloads"
KERNEL_OUT_DIR="${REPO_ROOT}/out/kernel"
OUT_DIR="${REPO_ROOT}/out"
ROOTFS_TARBALL="${DOWNLOAD_DIR}/${CHIMERA_ROOTFS_FILENAME}"
OUT_ROOTFS_ZST="${OUT_DIR}/rootfs.tar.zst"

mkdir -p "${DOWNLOAD_DIR}" "${OUT_DIR}"

echo "=============================================================================="
echo " Chimera Linux Switch (Erista) — Phase 2: Rootfs Builder"
echo "=============================================================================="
echo " Chimera image date : ${CHIMERA_IMAGE_DATE} (${CHIMERA_ROOTFS_FLAVOR})"
echo " Source tarball     : ${CHIMERA_ROOTFS_URL}"
echo " Expected SHA256    : ${CHIMERA_ROOTFS_SHA256}"
echo " Output archive     : ${OUT_ROOTFS_ZST}"
echo "=============================================================================="

# 1. Verify Phase 1 kernel modules exist
if [[ ! -f "${KERNEL_OUT_DIR}/modules.tar.gz" ]] || [[ ! -f "${KERNEL_OUT_DIR}/kernel.release" ]]; then
  echo "[ERROR] Phase 1 kernel artifacts not found in ${KERNEL_OUT_DIR}." >&2
  echo "        Run ./scripts/build-kernel.sh first." >&2
  exit 1
fi

KERNEL_RELEASE="$(tr -d '\r\n' < "${KERNEL_OUT_DIR}/kernel.release")"
echo "[INFO] Integrating kernel modules for release: ${KERNEL_RELEASE}"

# 2. Download and verify Chimera Linux rootfs tarball
if [[ ! -f "${ROOTFS_TARBALL}" ]]; then
  echo "[INFO] Downloading ${CHIMERA_ROOTFS_FILENAME}..."
  curl -fL --retry 3 -o "${ROOTFS_TARBALL}.part" "${CHIMERA_ROOTFS_URL}"
  mv "${ROOTFS_TARBALL}.part" "${ROOTFS_TARBALL}"
else
  echo "[INFO] Using cached rootfs tarball: ${ROOTFS_TARBALL}"
fi

ACTUAL_SHA256="$(sha256sum "${ROOTFS_TARBALL}" | awk '{print $1}')"
if [[ "${ACTUAL_SHA256}" != "${CHIMERA_ROOTFS_SHA256}" ]]; then
  echo "[ERROR] SHA256 mismatch for ${ROOTFS_TARBALL}!" >&2
  echo "        Expected: ${CHIMERA_ROOTFS_SHA256}" >&2
  echo "        Actual:   ${ACTUAL_SHA256}" >&2
  exit 1
fi
echo "[OK] Verified SHA256 of ${CHIMERA_ROOTFS_FILENAME}"

# 3. Ensure Docker volume exists
if ! docker volume inspect "${DOCKER_BUILD_VOLUME}" >/dev/null 2>&1; then
  docker volume create "${DOCKER_BUILD_VOLUME}" >/dev/null
fi

# 4. Run rootfs assembly and chroot customization inside aarch64 container
echo "[INFO] Building and configuring Chimera rootfs inside aarch64 container..."

docker run --rm --privileged \
  --platform linux/aarch64 \
  -e CHIMERA_ROOTFS_FILENAME="${CHIMERA_ROOTFS_FILENAME}" \
  -e KERNEL_RELEASE="${KERNEL_RELEASE}" \
  -e HEKATE_FS_LABEL="${HEKATE_FS_LABEL}" \
  -e PROJECT_VERSION="${PROJECT_VERSION}" \
  -e SXWM_GIT_URL="${SXWM_GIT_URL}" \
  -e SXWM_COMMIT="${SXWM_COMMIT}" \
  -e SXBAR_GIT_URL="${SXBAR_GIT_URL}" \
  -e SXBAR_COMMIT="${SXBAR_COMMIT}" \
  -e SVKBD_GIT_URL="${SVKBD_GIT_URL}" \
  -e SVKBD_COMMIT="${SVKBD_COMMIT}" \
  -v "${DOCKER_BUILD_VOLUME}:/build" \
  -v "${REPO_ROOT}:/workspace" \
  "${BUILD_CONTAINER_IMAGE}" \
  /bin/bash -c '
    set -euo pipefail

    export DEBIAN_FRONTEND=noninteractive
    if ! command -v zstd >/dev/null 2>&1 || ! command -v tar >/dev/null 2>&1; then
      apt-get update -qq
      apt-get install -y -qq zstd tar coreutils >/dev/null
    fi

    ROOTFS="/build/chimera-rootfs"
    echo "[CONTAINER] Preparing clean rootfs staging directory at ${ROOTFS}..."
    rm -rf "${ROOTFS}"
    mkdir -p "${ROOTFS}"

    echo "[CONTAINER] Extracting Chimera base rootfs (${CHIMERA_ROOTFS_FILENAME})..."
    tar -xzpf "/workspace/work/downloads/${CHIMERA_ROOTFS_FILENAME}" -C "${ROOTFS}"

    echo "[CONTAINER] Installing kernel modules (${KERNEL_RELEASE}) preserving UsrMerge symlinks..."
    tar --keep-directory-symlink -xzpf "/workspace/out/kernel/modules.tar.gz" -C "${ROOTFS}"

    # Verify /lib is still a symlink to usr/lib
    if [[ ! -L "${ROOTFS}/lib" ]]; then
      echo "[ERROR] ${ROOTFS}/lib is no longer a symlink! UsrMerge layout broken." >&2
      exit 1
    fi

    # Record kernel release inside rootfs for Phase 3 (initramfs)
    mkdir -p "${ROOTFS}/etc/chimera-switch"
    echo "${KERNEL_RELEASE}" > "${ROOTFS}/etc/chimera-switch/kernel-release"
    echo "${PROJECT_VERSION}" > "${ROOTFS}/etc/chimera-switch/version"

    # Configure hostname & hosts
    echo "chimera-switch" > "${ROOTFS}/etc/hostname"
    cat > "${ROOTFS}/etc/hosts" <<EOF
127.0.0.1   localhost chimera-switch
::1         localhost chimera-switch ip6-localhost ip6-loopback
10.42.0.2   chimera-switch.local chimera-switch
EOF

    # Configure /etc/fstab (SD card only — never touch eMMC!)
    mkdir -p "${ROOTFS}/boot/switchroot"
    cat > "${ROOTFS}/etc/fstab" <<EOF
# /etc/fstab — Chimera Linux on Nintendo Switch (Erista SD Card Layout)
# Ground rule: Never mount or modify internal eMMC (mmcblk1 / boot0 / boot1).
LABEL=${HEKATE_FS_LABEL}   /                 ext4      defaults,noatime,errors=remount-ro  0 1
/dev/mmcblk0p1             /boot/switchroot  vfat      defaults,noatime,nofail             0 2
tmpfs                      /tmp              tmpfs     defaults,nosuid,nodev,mode=1777     0 0
EOF

    # Install USB Gadget Networking script (/usr/local/sbin/setup-usb-gadget.sh)
    mkdir -p "${ROOTFS}/usr/local/sbin"
    cat > "${ROOTFS}/usr/local/sbin/setup-usb-gadget.sh" <<'\''GADGET_EOF'\''
#!/bin/sh
# ==============================================================================
# /usr/local/sbin/setup-usb-gadget.sh
# Brings up USB-C Ethernet (CDC-NCM + RNDIS fallback) and USB ACM Serial on
# Nintendo Switch (Tegra210 xUDC) via ConfigFS, assigns 10.42.0.2/24 to usb0,
# and starts dnsmasq DHCP so macOS/Linux hosts auto-configure on plug-in.
# ==============================================================================

set -u

GADGET_DIR="/sys/kernel/config/usb_gadget/chimera_switch"
USB_IP="10.42.0.2"
USB_PREFIX="24"
USB_SUBNET_CIDR="10.42.0.2/24"
DHCP_RANGE="10.42.0.10,10.42.0.50,255.255.255.0,12h"
DNSMASQ_PID="/run/usb-gadget-dnsmasq.pid"

log() {
  echo "[usb-gadget] $*"
  if [ -w /dev/kmsg ]; then
    echo "<6>[usb-gadget] $*" > /dev/kmsg 2>/dev/null || true
  fi
}

load_modules() {
  for mod in phy_tegra_xusb tegra_xudc dwc3 configfs libcomposite u_ether usb_f_ncm usb_f_ecm usb_f_rndis usb_f_acm; do
    modprobe "$mod" 2>/dev/null || true
  done
}

mount_configfs() {
  if ! mountpoint -q /sys/kernel/config 2>/dev/null; then
    mount -t configfs none /sys/kernel/config 2>/dev/null || true
  fi
}

wait_for_udc() {
  i=0
  while [ "$i" -lt 30 ]; do
    udc_dev="$(ls -1 /sys/class/udc 2>/dev/null | head -n 1)"
    if [ -n "$udc_dev" ]; then
      echo "$udc_dev"
      return 0
    fi
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}

configure_configfs_gadget() {
  udc_dev="$1"
  if [ -d "$GADGET_DIR" ]; then
    log "Gadget directory already exists at $GADGET_DIR"
    return 0
  fi

  mkdir -p "$GADGET_DIR" || return 1
  cd "$GADGET_DIR" || return 1

  # Linux Foundation Multifunction Composite Gadget (natively recognized by macOS/Linux/Windows)
  echo 0x1d6b > idVendor
  echo 0x0104 > idProduct
  echo 0x0100 > bcdDevice
  echo 0x0200 > bcdUSB
  echo 0xEF   > bDeviceClass
  echo 0x02   > bDeviceSubClass
  echo 0x01   > bDeviceProtocol

  mkdir -p strings/0x409
  # Deterministic locally-administered MAC addresses derived from SoC serial if available
  SERIAL="erista000001"
  if [ -r /sys/firmware/devicetree/base/serial-number ]; then
    SERIAL="$(tr -d '\''\000\r\n '\'' < /sys/firmware/devicetree/base/serial-number | cut -c1-16)"
  fi
  echo "$SERIAL" > strings/0x409/serialnumber
  echo "Chimera Linux Switch" > strings/0x409/manufacturer
  echo "Switch Erista USB Network" > strings/0x409/product

  mkdir -p configs/c.1/strings/0x409
  echo "CDC-NCM + ACM Composite" > configs/c.1/strings/0x409/configuration
  echo 250 > configs/c.1/MaxPower

  # Primary function: CDC-NCM (native zero-driver support on macOS, Linux, Windows 11)
  if mkdir -p functions/ncm.usb0 2>/dev/null; then
    echo "02:4e:58:00:00:02" > functions/ncm.usb0/dev_addr 2>/dev/null || true
    echo "02:4e:58:00:00:01" > functions/ncm.usb0/host_addr 2>/dev/null || true
    ln -s functions/ncm.usb0 configs/c.1/
  elif mkdir -p functions/rndis.usb0 2>/dev/null; then
    echo "02:4e:58:00:00:02" > functions/rndis.usb0/dev_addr 2>/dev/null || true
    echo "02:4e:58:00:00:01" > functions/rndis.usb0/host_addr 2>/dev/null || true
    ln -s functions/rndis.usb0 configs/c.1/
  elif mkdir -p functions/ecm.usb0 2>/dev/null; then
    echo "02:4e:58:00:00:02" > functions/ecm.usb0/dev_addr 2>/dev/null || true
    echo "02:4e:58:00:00:01" > functions/ecm.usb0/host_addr 2>/dev/null || true
    ln -s functions/ecm.usb0 configs/c.1/
  fi

  # Optional bonus: USB ACM serial console (/dev/ttyGS0)
  if mkdir -p functions/acm.GS0 2>/dev/null; then
    ln -s functions/acm.GS0 configs/c.1/
  fi

  log "Binding USB gadget to UDC: $udc_dev"
  echo "$udc_dev" > UDC
  return 0
}

find_usb_net_iface() {
  for candidate in usb0 ncm0 rndis0 ecm0; do
    if [ -d "/sys/class/net/$candidate" ]; then
      echo "$candidate"
      return 0
    fi
  done
  # Check gadget function ifname if present
  for f in "$GADGET_DIR"/functions/*/ifname; do
    if [ -r "$f" ]; then
      ifname="$(tr -d '\''\r\n'\'' < "$f")"
      if [ -n "$ifname" ] && [ -d "/sys/class/net/$ifname" ]; then
        echo "$ifname"
        return 0
      fi
    fi
  done
  return 1
}

start_gadget() {
  log "Starting Switch USB gadget networking..."
  load_modules
  mount_configfs

  udc_dev="$(wait_for_udc || true)"
  if [ -n "$udc_dev" ]; then
    if ! configure_configfs_gadget "$udc_dev"; then
      log "ConfigFS setup failed; attempting legacy g_ncm / g_ether fallback..."
      modprobe g_ncm 2>/dev/null || modprobe g_ether 2>/dev/null || true
    fi
  else
    log "WARNING: No UDC found in /sys/class/udc after 15s; trying g_ncm fallback..."
    modprobe g_ncm 2>/dev/null || modprobe g_ether 2>/dev/null || true
  fi

  # Wait up to 10s for network interface
  i=0
  iface=""
  while [ "$i" -lt 20 ]; do
    iface="$(find_usb_net_iface || true)"
    if [ -n "$iface" ]; then
      break
    fi
    sleep 0.5
    i=$((i + 1))
  done

  if [ -z "$iface" ]; then
    log "WARNING: No USB network interface (usb0) detected yet."
    return 0
  fi

  log "Configuring interface $iface with IP $USB_SUBNET_CIDR..."
  ip link set dev "$iface" up
  ip addr flush dev "$iface" 2>/dev/null || true
  ip addr add "$USB_SUBNET_CIDR" dev "$iface"

  # Start dnsmasq on usb0 so macOS host automatically receives 10.42.0.x
  if command -v dnsmasq >/dev/null 2>&1; then
    if [ -f "$DNSMASQ_PID" ] && kill -0 "$(cat "$DNSMASQ_PID")" 2>/dev/null; then
      kill "$(cat "$DNSMASQ_PID")" 2>/dev/null || true
    fi
    log "Starting dnsmasq DHCP server on $iface ($DHCP_RANGE)..."
    dnsmasq \
      --interface="$iface" \
      --bind-interfaces \
      --listen-address="$USB_IP" \
      --dhcp-range="$DHCP_RANGE" \
      --dhcp-option=3 \
      --dhcp-option=6 \
      --port=0 \
      --pid-file="$DNSMASQ_PID" || log "WARNING: dnsmasq failed to start (static IP $USB_IP still active)"
  fi

  log "USB gadget networking ready on $iface ($USB_IP)"
}

stop_gadget() {
  log "Stopping Switch USB gadget networking..."
  if [ -f "$DNSMASQ_PID" ]; then
    kill "$(cat "$DNSMASQ_PID")" 2>/dev/null || true
    rm -f "$DNSMASQ_PID"
  fi
  if [ -d "$GADGET_DIR" ]; then
    echo "" > "$GADGET_DIR/UDC" 2>/dev/null || true
  fi
}

case "${1:-start}" in
  start)
    start_gadget
    ;;
  stop)
    stop_gadget
    ;;
  restart)
    stop_gadget
    start_gadget
    ;;
  *)
    echo "Usage: $0 {start|stop|restart}" >&2
    exit 1
    ;;
esac
GADGET_EOF
    chmod 0755 "${ROOTFS}/usr/local/sbin/setup-usb-gadget.sh"

    # Prepare chroot mounts
    mkdir -p "${ROOTFS}/workspace"
    mount -t proc proc "${ROOTFS}/proc"
    mount -t sysfs sys "${ROOTFS}/sys"
    mount --bind /dev "${ROOTFS}/dev"
    mount --bind /dev/pts "${ROOTFS}/dev/pts"
    mount --bind /workspace "${ROOTFS}/workspace"

    cleanup_mounts() {
      umount -lf "${ROOTFS}/workspace" 2>/dev/null || true
      rm -rf "${ROOTFS}/workspace" 2>/dev/null || true
      umount -lf "${ROOTFS}/dev/pts" 2>/dev/null || true
      umount -lf "${ROOTFS}/dev" 2>/dev/null || true
      umount -lf "${ROOTFS}/sys" 2>/dev/null || true
      umount -lf "${ROOTFS}/proc" 2>/dev/null || true
    }
    trap cleanup_mounts EXIT

    cp -L /etc/resolv.conf "${ROOTFS}/etc/resolv.conf"

    echo "[CONTAINER] Running chroot configuration inside Chimera Linux (aarch64)..."
    chroot "${ROOTFS}" /bin/sh -e -c "
      export PATH=/usr/bin:/usr/sbin:/bin:/sbin

      echo \"[CHROOT] Updating apk indices and upgrading installed packages...\"
      apk add --no-interactive chimera-repo-user chimera-repo-contrib >/dev/null 2>&1 || true
      apk update
      apk upgrade --no-interactive

      echo \"[CHROOT] Installing base headless & Switch support packages (no kernel package)...\"
      apk add --no-interactive \
        openssh \
        openssh-dinit \
        iproute2 \
        dnsmasq \
        opendoas \
        initramfs-tools \
        kmod \
        e2fsprogs \
        dosfstools \
        util-linux \
        usbutils \
        pciutils \
        curl \
        ca-certificates \
        zstd \
        xz \
        nano \
        tmux \
        htop \
        firmware-linux-brcm \
        xserver-xorg-core \
        xserver-xorg-input-libinput \
        xinit \
        xrandr \
        xsetroot \
        dmenu \
        rxvt-unicode \
        font-terminus \
        fonts-dejavu \
        fonts-freefont-otf \
        gmake \
        clang \
        pkgconf \
        git \
        libx11-devel \
        libxinerama-devel \
        libxcursor-devel \
        libxft-devel \
        fontconfig-devel \
        freetype-devel \
        libxtst-devel

      echo \"[CHROOT] Building and installing sxwm (Simple X Window Manager)...\"
      rm -rf /tmp/src && mkdir -p /tmp/src
      git clone --filter=blob:none \"${SXWM_GIT_URL}\" /tmp/src/sxwm
      git -C /tmp/src/sxwm checkout \"${SXWM_COMMIT}\"
      (cd /tmp/src/sxwm && gmake CC=clang && gmake install)

      echo \"[CHROOT] Building and installing sxbar (sxwm companion status bar)...\"
      git clone --filter=blob:none \"${SXBAR_GIT_URL}\" /tmp/src/sxbar
      git -C /tmp/src/sxbar checkout \"${SXBAR_COMMIT}\"
      (cd /tmp/src/sxbar && gmake CC=clang && gmake install)

      echo \"[CHROOT] Building and installing svkbd (suckless virtual touch keyboard)...\"
      git clone --filter=blob:none \"${SVKBD_GIT_URL}\" /tmp/src/svkbd
      git -C /tmp/src/svkbd checkout \"${SVKBD_COMMIT}\"
      (cd /tmp/src/svkbd && gmake CC=clang LAYOUT=mobile-simple && cp -f svkbd-mobile-simple /usr/local/bin/)

      echo \"[CHROOT] Cleaning temporary build packages...\"
      apk del gmake clang llvm musl-devel libx11-devel libxinerama-devel libxcursor-devel libxft-devel fontconfig-devel freetype-devel libxtst-devel pkgconf git
      rm -rf /tmp/src

      echo \"[CHROOT] Configuring locale and timezone (UTC)...\"
      ln -sf /usr/share/zoneinfo/UTC /etc/localtime

      echo \"[CHROOT] Creating user '\''chimera'\'' and setting passwords...\"
      if ! id -u chimera >/dev/null 2>&1; then
        useradd -m -G wheel,audio,video,input,tty,dialout -s /bin/sh chimera
      fi
      echo \"root:chimera\" | chpasswd
      echo \"chimera:chimera\" | chpasswd

      echo \"[CHROOT] Configuring opendoas (/etc/doas.conf)...\"
      cat > /etc/doas.conf <<DOAS_EOF
# Allow members of group wheel to run commands as root
permit persist :wheel
DOAS_EOF
      chmod 0600 /etc/doas.conf

      echo \"[CHROOT] Configuring X11, Tegra KMS & touchscreen calibration...\"
      mkdir -p /etc/X11/xorg.conf.d
      cp -f /workspace/configs/xorg-switch.conf /etc/X11/xorg.conf.d/20-switch-tegra.conf

      cat > /etc/X11/Xwrapper.config <<'XWRAP_EOF'
needs_root_rights = yes
allowed_users = anybody
XWRAP_EOF

      echo \"[CHROOT] Configuring user environment and sxwm/sxbar session...\"
      mkdir -p /home/chimera/.config/sxwm /home/chimera/.config/sxbar
      cp -f /workspace/configs/sxwmrc /home/chimera/.config/sxwm/sxwmrc
      cp -f /workspace/configs/sxwmrc /home/chimera/.config/sxwmrc
      cp -f /workspace/configs/sxbarc /home/chimera/.config/sxbar/sxbarc
      cp -f /workspace/configs/sxbarc /home/chimera/.config/sxbarc

      cat > /home/chimera/.xinitrc <<'XINIT_EOF'
#!/bin/sh
# Chimera Linux Switch (Erista) X11 Startup
export LIBGL_ALWAYS_SOFTWARE=1
export GALLIUM_DRIVER=llvmpipe

# Set standard cursor and background
xsetroot -cursor_name left_ptr
xsetroot -solid "#1a1b26"

# Launch sxbar companion status bar
sxbar &

# Start sxwm tiling window manager
exec sxwm
XINIT_EOF
      chmod 0755 /home/chimera/.xinitrc

      cat > /usr/local/bin/start-desktop <<'LAUNCH_EOF'
#!/bin/sh
exec su - chimera -c "startx"
LAUNCH_EOF
      chmod 0755 /usr/local/bin/start-desktop

      chown -R chimera:chimera /home/chimera

      echo \"[CHROOT] Configuring OpenSSH server for headless USB-Ethernet access...\"
      mkdir -p /etc/ssh/sshd_config.d
      cat > /etc/ssh/sshd_config.d/10-chimera-switch.conf <<SSH_EOF
# Chimera Linux Switch (Erista) Headless USB-SSH Configuration
PermitRootLogin yes
PasswordAuthentication yes
PubkeyAuthentication yes
UseDNS no
SSH_EOF
      ssh-keygen -A

      echo \"[CHROOT] Configuring dinit services (sshd + usb-gadget + x11-desktop)...\"
      mkdir -p /etc/dinit.d /etc/dinit.d/boot.d

      # Determine dependency target used by Chimera dinit
      DEP_TARGET=\"local.target\"
      if [ ! -e /usr/lib/dinit.d/local.target ] && [ -e /usr/lib/dinit.d/System ]; then
        DEP_TARGET=\"login.target\"
      fi

      cat > /etc/dinit.d/usb-gadget <<DINIT_EOF
type = scripted
command = /usr/local/sbin/setup-usb-gadget.sh start
stop-command = /usr/local/sbin/setup-usb-gadget.sh stop
depends-on = \${DEP_TARGET}
restart = false
DINIT_EOF

      cat > /etc/dinit.d/x11-desktop <<DINIT_EOF
type = process
command = /usr/bin/su - chimera -c "startx -- vt1"
depends-on = \${DEP_TARGET}
restart = true
smooth-recovery = true
DINIT_EOF

      # Enable sshd, usb-gadget, and x11-desktop in dinit boot.d
      ln -sf /usr/lib/dinit.d/sshd /etc/dinit.d/boot.d/sshd
      ln -sf /etc/dinit.d/usb-gadget /etc/dinit.d/boot.d/usb-gadget
      ln -sf /etc/dinit.d/x11-desktop /etc/dinit.d/boot.d/x11-desktop

      # Disable default dnsmasq system service if apk added one so it only runs on usb0 via setup-usb-gadget.sh
      rm -f /etc/dinit.d/boot.d/dnsmasq

      echo \"[CHROOT] Cleaning apk package cache...\"
      rm -rf /var/cache/apk/*
    "

    # Clean temporary chroot resolv.conf and unmount virtual filesystems
    rm -f "${ROOTFS}/etc/resolv.conf"
    cat > "${ROOTFS}/etc/resolv.conf" <<EOF
# Configured by DHCP or manual network setup
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF

    cleanup_mounts
    trap - EXIT

    echo "[CONTAINER] Compressing rootfs into /workspace/out/rootfs.tar.zst..."
    rm -f /workspace/out/rootfs.tar.zst
    tar --numeric-owner -C "${ROOTFS}" -cpf - . | zstd -T0 -10 -o /workspace/out/rootfs.tar.zst
  '

# 5. Compute SHA256 and print summary
(
  cd "${OUT_DIR}"
  sha256sum "$(basename "${OUT_ROOTFS_ZST}")" > "$(basename "${OUT_ROOTFS_ZST}").sha256"
)

ROOTFS_SIZE_HUMAN="$(du -h "${OUT_ROOTFS_ZST}" | awk '{print $1}')"
ROOTFS_SHA="$(awk '{print $1}' "${OUT_ROOTFS_ZST}.sha256")"

echo "=============================================================================="
echo " Phase 2 Rootfs Build Complete"
echo "=============================================================================="
echo " Output archive : ${OUT_ROOTFS_ZST} (${ROOTFS_SIZE_HUMAN})"
echo " SHA256         : ${ROOTFS_SHA}"
echo " Default login  : chimera / chimera (root: root / chimera)"
echo " USB-SSH IP     : 10.42.0.2/24 on usb0 (DHCP server active for host)"
echo "=============================================================================="
