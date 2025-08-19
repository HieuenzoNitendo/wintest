    #!/usr/bin/env bash
    set -eu

    SRC_DIR="/tmp/tinycore_audit/out"
    DEST_DIR="/boot/tinycore"
    SNIPPET_NAME="40_custom_tinycore_snippet"
    MARK_BEGIN="# >>> TINYCORE SAFE ENTRY BEGIN >>>"
    MARK_END="# <<< TINYCORE SAFE ENTRY END <<<"
    NONINTERACTIVE=0

    usage() {
      cat <<USAGE
Usage: sudo $0 [--source-dir DIR] [--yes]

Safely install TinyCore kernel/initrd into /boot/tinycore and add a GRUB entry.
- Backs up existing files in /boot/tinycore with datestamp
- Appends a guarded block to /etc/grub.d/40_custom if not present
- Runs update-grub (or grub-mkconfig -o /boot/grub/grub.cfg)

Options:
  --source-dir DIR  Directory containing vmlinuz64, corepure64-ssh.gz, and snippet (default: /tmp/tinycore_audit/out)
  --yes             Non-interactive mode; assume 'yes' for prompts
USAGE
    }

    while [[ $# -gt 0 ]]; do
      case "$1" in
        --source-dir) SRC_DIR="${2:-}"; shift 2 ;;
        --yes|-y) NONINTERACTIVE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
      esac
    done

    if [[ $EUID -ne 0 ]]; then
      echo "Please run as root: sudo $0" >&2
      exit 1
    fi

    for f in "vmlinuz64" "corepure64-ssh.gz" "$SNIPPET_NAME"; do
      if [[ ! -s "$SRC_DIR/$f" ]]; then
        echo "Missing expected file: $SRC_DIR/$f" >&2
        exit 1
      fi
    done

    echo "Source dir: $SRC_DIR"
    echo "Dest dir:   $DEST_DIR"
    echo

    confirm() {
      local prompt="$1"
      if [[ "$NONINTERACTIVE" -eq 1 ]]; then
        return 0
      fi
      read -r -p "$prompt [y/N]: " ans
      [[ "$ans" == "y" || "$ans" == "Y" ]]
    }

    # Ensure dest dir
    if [[ ! -d "$DEST_DIR" ]]; then
      echo "Creating $DEST_DIR ..."
      mkdir -p "$DEST_DIR"
    fi

    ts="$(date +%Y%m%d-%H%M%S)"
    backup_if_exists() {
      local path="$1"
      if [[ -e "$path" ]]; then
        local bak="${path}.bak-${ts}"
        echo "Backing up $(basename "$path") -> $bak"
        cp -a "$path" "$bak"
      fi
    }

    echo "About to copy kernel and initrd to $DEST_DIR"
    confirm "Proceed to copy?" || { echo "Aborted."; exit 1; }

    backup_if_exists "$DEST_DIR/vmlinuz64"
    backup_if_exists "$DEST_DIR/corepure64-ssh.gz"

    install -m 0644 "$SRC_DIR/vmlinuz64" "$DEST_DIR/vmlinuz64"
    install -m 0644 "$SRC_DIR/corepure64-ssh.gz" "$DEST_DIR/corepure64-ssh.gz"

    echo
    echo "Kernel/initrd installed."
    echo

    # Append snippet to /etc/grub.d/40_custom if not already present
    CUSTOM="/etc/grub.d/40_custom"
    if ! grep -qF "$MARK_BEGIN" "$CUSTOM" 2>/dev/null; then
      echo "About to append GRUB entry to $CUSTOM"
      confirm "Append entry?" || { echo "Skipped GRUB append."; exit 0; }

      backup_if_exists "$CUSTOM"
      {
        echo "$MARK_BEGIN"
        # Normalize snippet so linux/initrd paths match DEST_DIR location
        # The snippet uses /boot/tinycore/, so no change required.
        cat "$SRC_DIR/$SNIPPET_NAME"
        echo "$MARK_END"
      } >> "$CUSTOM"
      chmod 0755 "$CUSTOM" || true

      echo "GRUB entry appended."
    else
      echo "Guarded GRUB block already present in $CUSTOM; skipping append."
    fi

    echo
    echo "Updating GRUB configuration..."
    if command -v update-grub >/dev/null 2>&1; then
      update-grub
    else
      # Fallback for systems without update-grub
      if [[ -d /boot/grub ]]; then
        grub-mkconfig -o /boot/grub/grub.cfg
      elif [[ -d /boot/grub2 ]]; then
        grub2-mkconfig -o /boot/grub2/grub.cfg
      else
        echo "Could not find GRUB directory. Please update your bootloader manually." >&2
        exit 1
      fi
    fi

    echo
    echo "✅ Done. Reboot to test the new 'TinyCore SSH Auto (SAFE PREVIEW)' entry."
    echo "If needed, you can roll back using backups with suffix .bak-${ts}."
