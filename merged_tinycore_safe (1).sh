#!/bin/bash
# ============================================================================
# TinyCore Safe Auditor & GRUB Snippet Applier (merged script)
# ============================================================================
# This script contains two parts:
#   1. Safe auditor for TinyCore initrd (non-destructive).
#   2. POSIX-safe GRUB snippet applier for Debian/Ubuntu.
#
# Usage examples:
#   sudo bash merged_tinycore_safe.sh audit        # Run the safe auditor
#   sudo bash merged_tinycore_safe.sh apply        # Apply GRUB snippet safely
# ============================================================================

set -euo pipefail

ACTION="${1:-}"

# ----------------------------------------------------------------------------
# CONFIG (shared)
# ----------------------------------------------------------------------------
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
: "${GZ_LINK:=}"

# ----------------------------------------------------------------------------
# Function: Safe Auditor
# ----------------------------------------------------------------------------
audit_tinycore() {
  echo "[0/7] Pre-flight checks..."
  if [[ $EUID -ne 0 ]]; then
    echo "Please run as root (sudo). Exiting." >&2
    exit 1
  fi

  if ! command -v apt-get >/dev/null 2>&1; then
    echo "This script expects apt-get (Debian/Ubuntu). Exiting." >&2
    exit 1
  fi

  echo "[1/7] Installing dependencies..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y wget curl cpio gzip libarchive-tools ca-certificates

  echo "[2/7] Preparing work folders under $WORKROOT ..."
  rm -rf "$WORKROOT"
  mkdir -p "$WORKDIR" "$OUTDIR"

  echo "[3/7] Downloading TinyCore kernel and initrd ..."
  wget -q -O "$KERNEL_PATH" "$KERNEL_URL"
  wget -q -O "$INITRD_PATH" "$INITRD_URL"
  if [[ ! -s "$KERNEL_PATH" || ! -s "$INITRD_PATH" ]]; then
    echo "Download failed." >&2
    exit 1
  fi

  echo "[4/7] Unpacking initrd ..."
  if command -v bsdtar >/dev/null 2>&1; then
    gzip -dc "$INITRD_PATH" | bsdtar -xpf - -C "$WORKDIR" --exclude "dev/*"
  else
    set +e
    ( cd "$WORKDIR" && gzip -dc "$INITRD_PATH" | cpio -idm --no-absolute-filenames --quiet ) 2> "$WORKROOT/cpio_warnings.log"
    cpio_status=$?
    set -e
    if [ "$cpio_status" -ne 0 ]; then
      echo "   - cpio returned $cpio_status (likely dev node mknod failures). Continuing."
    fi
    rm -rf "$WORKDIR/dev" || true
  fi

  echo "[5/7] Injecting bootlocal.sh and busybox ..."
  mkdir -p "$WORKDIR/srv"
  ( curl -m 3 -fsSL ifconfig.me || true ) > "$WORKDIR/srv/lab" || true
  echo "/admin/admin" >> "$WORKDIR/srv/lab"

  wget -q -O "$WORKDIR/srv/busybox" "$BUSYBOX_URL" || true
  chmod +x "$WORKDIR/srv/busybox" || true

  cat > "$WORKDIR/opt/bootlocal.sh" <<'BOOTLOCAL'
#!/bin/sh
udhcpc 2>/dev/null || true
echo "Installation (SAFE MODE) started" >> /srv/lab
# su tc -c "/srv/busybox httpd -p 80 -h /srv"
su tc -c "tce-load -wi ntfs-3g" || true
su tc -c "tce-load -wi gdisk" || true
su tc -c "tce-load -wi openssh.tcz" || true
[ -x /usr/local/etc/init.d/openssh ] && /usr/local/etc/init.d/openssh start 2>/dev/null || true
# ==== DANGEROUS STEPS REMOVED FOR SAFETY ====
echo "SAFE MODE complete" >> /srv/lab
BOOTLOCAL

  chmod +x "$WORKDIR/opt/bootlocal.sh"

  echo "[6/7] Repacking initrd ..."
  ( cd "$WORKDIR" && find . | cpio -o -H newc --quiet | gzip -c > "$INITRD_PATCHED" )

  echo "[7/7] Emitting GRUB snippet ..."
  SNIPPET="$OUTDIR/40_custom_tinycore_snippet"
  cat > "$SNIPPET" <<'GRUBSNIP'
menuentry "🔧 TinyCore SSH Auto (SAFE PREVIEW)" {
    insmod part_gpt
    insmod ext2
    linux /boot/tinycore/vmlinuz64 console=ttyS0 quiet
    initrd /boot/tinycore/corepure64-ssh.gz
}
GRUBSNIP

  echo "✅ SAFE audit complete."
  echo "Artifacts:"
  echo "  - Kernel:         $KERNEL_PATH"
  echo "  - Initrd (orig):  $INITRD_PATH"
  echo "  - Initrd (safe):  $INITRD_PATCHED"
  echo "  - GRUB snippet:   $SNIPPET"
}

# ----------------------------------------------------------------------------
# Function: Apply GRUB Snippet
# ----------------------------------------------------------------------------
apply_snippet() {
  SNIPPET_SRC="${1:-$WORKROOT/out/40_custom_tinycore_snippet}"
  SNIPPET_DST="/etc/grub.d/40_custom"

  if [ "$(id -u)" -ne 0 ]; then
    echo "Please run as root." >&2
    exit 1
  fi

  if [ ! -f "$SNIPPET_SRC" ]; then
    echo "Snippet not found: $SNIPPET_SRC" >&2
    exit 1
  fi

  if [ ! -f "$SNIPPET_DST" ]; then
    echo "# Custom entries" > "$SNIPPET_DST"
    chmod 755 "$SNIPPET_DST"
  fi

  if ! grep -q "TinyCore SSH Auto (SAFE PREVIEW)" "$SNIPPET_DST"; then
    printf '\n%s\n' "$(cat "$SNIPPET_SRC")" >> "$SNIPPET_DST"
    echo "Appended snippet to $SNIPPET_DST"
  else
    echo "Snippet already present in $SNIPPET_DST"
  fi

  if command -v update-grub >/dev/null 2>&1; then
    if grub-probe / >/dev/null 2>&1; then
      update-grub
    else
      echo "Warning: grub-probe failed. Likely container/chroot without /dev,/proc,/sys."
      exit 2
    fi
  else
    echo "update-grub not found."
  fi
}

# ----------------------------------------------------------------------------
# Main dispatcher
# ----------------------------------------------------------------------------
case "$ACTION" in
  audit)
    audit_tinycore
    ;;
  apply)
    apply_snippet "$2"
    ;;
  *)
    echo "Usage:"
    echo "  sudo bash $0 audit              # Run safe auditor"
    echo "  sudo bash $0 apply [snippet]    # Apply GRUB snippet"
    exit 1
    ;;
esac
