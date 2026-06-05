#!/usr/bin/env bash
set -euo pipefail

ISO_URL="https://enterprise.proxmox.com/iso/proxmox-ve_9.2-1.iso"
ISO="/tmp/$(basename "$ISO_URL")"
MNT="/mnt/pveiso-pin"

PREF="/etc/apt/preferences.d/pve-iso-all-versions.pref"
VERSION_FILE="/root/pve-iso-pve-manager.version"
CHECK_SCRIPT="/root/check-pve-iso-version-onboot.sh"
LOG="/var/log/check-pve-iso-version-onboot.log"

echo "Downloading ISO: $ISO_URL"
curl -L -o "$ISO" "$ISO_URL"

mkdir -p "$MNT"

if mountpoint -q "$MNT"; then
  umount "$MNT" || true
fi

echo "Mounting ISO..."
mount -o loop,ro "$ISO" "$MNT"

PKG="$(find "$MNT" -type f -path '*/packages/Packages' | head -n1)"

if [ -z "$PKG" ]; then
  echo "Packages file not found in ISO"
  umount "$MNT" || true
  exit 1
fi

echo "Found Packages: $PKG"

echo "Generating version pinning from ISO to $PREF"
awk '
  /^Package: / {pkg=$2}
  /^Version: / {
    ver=$2
    if (pkg != "" && ver != "") {
      print "Package: " pkg
      print "Pin: version " ver
      print "Pin-Priority: 1001"
      print ""
      pkg=""
      ver=""
    }
  }
' "$PKG" > "$PREF"

chmod 644 "$PREF"

ISO_PVE_MANAGER_VERSION="$(
  awk '
    /^Package: / {pkg=$2}
    /^Version: / {
      if (pkg == "pve-manager") {
        print $2
        exit
      }
    }
  ' "$PKG"
)"

if [ -z "$ISO_PVE_MANAGER_VERSION" ]; then
  echo "Could not find pve-manager version in Packages"
  umount "$MNT" || true
  exit 1
fi

echo "$ISO_PVE_MANAGER_VERSION" > "$VERSION_FILE"
chmod 644 "$VERSION_FILE"

echo "pve-manager version from ISO: $ISO_PVE_MANAGER_VERSION"
echo "Saved to: $VERSION_FILE"

umount "$MNT" || true

cat >"$CHECK_SCRIPT" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail

PREF="/etc/apt/preferences.d/pve-iso-all-versions.pref"
VERSION_FILE="/root/pve-iso-pve-manager.version"
SCRIPT="/root/check-pve-iso-version-onboot.sh"
SETUP_SCRIPT="/root/proxmox-upgrade-version-pinning.sh"
LOG="/var/log/check-pve-iso-version-onboot.log"

exec >>"$LOG" 2>&1

echo "===== $(date) ====="

if [ ! -f "$VERSION_FILE" ]; then
  echo "ISO version file not found: $VERSION_FILE"
  exit 1
fi

ISO_PVE_MANAGER_VERSION="$(cat "$VERSION_FILE" | tr -d '[:space:]')"
INSTALLED="$(dpkg-query -W -f='${Version}' pve-manager 2>/dev/null || true)"

echo "pve-manager version from ISO: $ISO_PVE_MANAGER_VERSION"
echo "Installed pve-manager: $INSTALLED"

if [ -z "$INSTALLED" ]; then
  echo "pve-manager not found on this system"
  exit 0
fi

if [ "$INSTALLED" = "$ISO_PVE_MANAGER_VERSION" ]; then
  echo "OK: pve-manager is already at the ISO version."
  echo "Removing pinning, cron job and helper files."

  rm -f "$PREF"

  crontab -l 2>/dev/null | grep -vF "$SCRIPT" | crontab - || true

  rm -f "$VERSION_FILE"
  rm -f "$SCRIPT"
  rm -f "$SETUP_SCRIPT"

  echo "Done."
else
  echo "Not yet: installed=$INSTALLED iso=$ISO_PVE_MANAGER_VERSION"
  echo "Pinning remains active."
fi
EOS

chmod +x "$CHECK_SCRIPT"

TMPCRON="$(mktemp)"
crontab -l 2>/dev/null | grep -vF "$CHECK_SCRIPT" > "$TMPCRON" || true
echo "@reboot $CHECK_SCRIPT" >> "$TMPCRON"
crontab "$TMPCRON"
rm -f "$TMPCRON"

echo
echo "===== apt update ====="
apt update

echo
echo "===== apt full-upgrade -s (dry run, no Summary) ====="
script -qefc "apt full-upgrade -s" /dev/null | awk 'BEGIN{stop=0} /^[[:space:]]*Summary:/{stop=1} !stop{print}'

echo
echo "============================================================"
echo "Dry run complete."
echo "To perform the actual upgrade, run manually in the terminal:"
echo
echo "    apt full-upgrade"
echo
echo "The upgrade is NOT started automatically."
echo "============================================================"
