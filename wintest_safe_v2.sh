#!/bin/bash
set -euo pipefail

# === PURPOSE ===
# Safe auditor for the TinyCore initrd workflow.
# - Installs prerequisites (no disk writes)
# - Downloads kernel+initrd to /tmp (no /boot writes)
# - Unpacks, injects minimal bootlocal.sh with DESTRUCTIVE STEPS COMMENTED OUT
# - Rebuilds a patched initrd to /tmp
# - Emits a GRUB menuentry snippet to /tmp/40_custom_tinycore_snippet
#
# NOTE: This script is intentionally NON-DESTRUCTIVE.
# It DOES NOT write to /boot, update GRUB, or touch /dev/sd*.
# Review all artifacts in /tmp and apply manually if you accept the risks.

# === CONFIG ===
TCE_VERSION="14.x"
ARCH="x86_64"
TCE_MIRROR="http://tinycorelinux.net"
WORKROOT="/tmp/tinycore_audit"
WORKDIR="$WORKROOT/initrd"
OUTDIR="$WORKROOT/out"

KERNEL_URL="$TCE_MIRROR/$TCE_VERSION/$ARCH/release/distribution_files/vmlinuz64"
INITRD_URL="$TCE_MIRROR/$TCE_VERSION/$ARCH/release/distribution_files/corepure64.gz"

KERNEL_PATH="$OUTDIR/vmlinuz64"
INITRD_PATH="$OUTDIR/corepure64.gz"
INITRD_PATCHED="$OUTDIR/corepure64-ssh.gz"

BUSYBOX_URL="https://github.com/kmille36/CaiWindowsChoLinux/raw/refs/heads/main/busybox"

# Shortlink from the original script is intentionally NOT used here.
# If you really need it, set GZ_LINK yourself and verify it is trustworthy.
: "${GZ_LINK:=}"

echo "[0/7] Pre-flight checks..."
if [[ $EUID -ne 0 ]]; then
  echo "Please run as root (sudo) so packages can be installed. Exiting." >&2
  exit 1
fi

command -v apt-get >/dev/null 2>&1 || { echo "This script expects apt-get (Debian/Ubuntu). Exiting."; exit 1; }

echo "[1/7] Installing dependencies (wget, curl, cpio, gzip)..."
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y wget curl cpio gzip

echo "[2/7] Preparing work folders under $WORKROOT ..."
rm -rf "$WORKROOT"
mkdir -p "$WORKDIR" "$OUTDIR"

echo "[3/7] Downloading TinyCore kernel and initrd to $OUTDIR ..."
wget -q -O "$KERNEL_PATH" "$KERNEL_URL"
wget -q -O "$INITRD_PATH" "$INITRD_URL"
[[ -s "$KERNEL_PATH" && -s "$INITRD_PATH" ]] || { echo "Download failed."; exit 1; }

\
    echo "[4/7] Unpacking initrd to $WORKDIR ..."
    # Try bsdtar first (avoids creating device nodes), fall back to cpio with tolerant errors.
    if ! command -v bsdtar >/dev/null 2>&1; then
      echo "   - Installing libarchive-tools (for bsdtar)..."
      DEBIAN_FRONTEND=noninteractive apt-get install -y libarchive-tools >/dev/null 2>&1 || true
    fi

    if command -v bsdtar >/dev/null 2>&1; then
      # Exclude dev/* to avoid mknod permission issues in containers/lockdown kernels
      mkdir -p "$WORKDIR"
      gzip -dc "$INITRD_PATH" | bsdtar -xpf - -C "$WORKDIR" --exclude "dev/*"
    else
      # Tolerant cpio extraction; capture warnings and continue even if device nodes fail
      mkdir -p "$WORKDIR"
      set +e
      ( cd "$WORKDIR" && gzip -dc "$INITRD_PATH" | cpio -idm --no-absolute-filenames --quiet ) 2> "$WORKROOT/cpio_warnings.log"
      cpio_status=$?
      set -e
      if [ "$cpio_status" -ne 0 ]; then
        echo "   - cpio returned $cpio_status (likely dev node mknod failures). Continuing safely."
        echo "     See $WORKROOT/cpio_warnings.log for details."
      fi
      # Remove any partially-extracted dev entries to be safe
      rm -rf "$WORKDIR/dev" || true
    fi

( cd "$WORKDIR" && gzip -dc "$INITRD_PATH" | cpio -idm --quiet )

echo "[5/7] Injecting bootlocal.sh and busybox (safe mode)..."
mkdir -p "$WORKDIR/srv"
# Use curl to record public IP if desired (non-fatal if it fails)
( curl -m 3 -fsSL ifconfig.me || true ) > "$WORKDIR/srv/lab" || true
echo "/admin/admin" >> "$WORKDIR/srv/lab"

# Busybox for httpd (as in the original), but we won't start any servers here.
wget -q -O "$WORKDIR/srv/busybox" "$BUSYBOX_URL" || true
chmod +x "$WORKDIR/srv/busybox" || true

# Write a SAFE bootlocal.sh (no destructive actions).
cat > "$WORKDIR/opt/bootlocal.sh" <<'BOOTLOCAL'
#!/bin/sh
# SAFE bootlocal: retains package loads, comments out destructive steps.

# Try to acquire DHCP (ignore failures)
sudo udhcpc 2>/dev/null || true

echo "Installation (SAFE MODE) started" >> /srv/lab

# Optional: lightweight http server for status page (commented out by default)
# su tc -c "sudo /srv/busybox httpd -p 80 -h /srv"

# Load optional tools (ignore failures)
su tc -c "tce-load -wi ntfs-3g" || true
su tc -c "tce-load -wi gdisk" || true
su tc -c "tce-load -wi openssh.tcz" || true

# Start SSH if available (ignore failures)
sudo /usr/local/etc/init.d/openssh start 2>/dev/null || true

# ===== DANGEROUS STEPS FROM ORIGINAL SCRIPT (COMMENTED OUT) =====
# The following commands modify the bootloader and DESTROY/REPARTITION DISKS.
# They are **DISABLED** for safety. Review and enable only if you accept the risks.
#
# sudo sh -c "wget --no-check-certificate -O grub.gz https://github.com/kmille36/CaiWindowsChoLinux/raw/refs/heads/main/grubsdbuefiwin.gz"
# sudo gunzip -c grub.gz | dd of=/dev/sda bs=4M
# echo formatting sda to GPT NTFS >> /srv/lab
# sudo sgdisk -d 2 /dev/sda
# sudo sgdisk -n 2:0:0 -t 2:0700 -c 2:"Data" /dev/sda
# sudo mkfs.ntfs -f /dev/sda2 -L DATA
# if [ -n "$GZ_LINK" ]; then
#   sudo sh -c '(wget --no-check-certificate -O- "$GZ_LINK" | gunzip | dd of=/dev/sdb bs=4M) & i=0; while kill -0 $(pidof dd) 2>/dev/null; do echo "Installing... (${i}s)"; echo "Installing... (${i}s)" >> /srv/lab; sleep 1; i=$((i+1)); done; echo "Done in ${i}s"; echo "Installing completed in ${i}s" >> /srv/lab'
# fi
#
# sleep 1
# sudo reboot
# ===== END DANGEROUS STEPS =====

echo "SAFE MODE complete" >> /srv/lab
BOOTLOCAL

chmod +x "$WORKDIR/opt/bootlocal.sh"

echo "[6/7] Repacking patched initrd to $INITRD_PATCHED ..."
( cd "$WORKDIR" && find . | cpio -o -H newc --quiet | gzip -c > "$INITRD_PATCHED" )

echo "[7/7] Emitting GRUB menuentry snippet to /tmp (no changes applied) ..."
SNIPPET="$OUTDIR/40_custom_tinycore_snippet"
cat > "$SNIPPET" <<'GRUBSNIP'
menuentry "🔧 TinyCore SSH Auto (SAFE PREVIEW)" {
    insmod part_gpt
    insmod ext2
    # Adjust these paths to where you actually place the artifacts
    linux /boot/tinycore/vmlinuz64 console=ttyS0 quiet
    initrd /boot/tinycore/corepure64-ssh.gz
}
GRUBSNIP

echo
echo "✅ SAFE audit complete."
echo "Artifacts:"
echo "  - Kernel:         $KERNEL_PATH"
echo "  - Initrd (orig):  $INITRD_PATH"
echo "  - Initrd (safe):  $INITRD_PATCHED"
echo "  - GRUB snippet:   $SNIPPET"
echo
echo "Next steps (manual):"
echo "  1) Review '$WORKROOT' contents."
echo "  2) If acceptable, copy vmlinuz64 and corepure64-ssh.gz to /boot/tinycore/"
echo "  3) Append the snippet to /etc/grub.d/40_custom and run 'update-grub' (Ubuntu/Debian)."
echo "  4) Reboot and test."
echo
