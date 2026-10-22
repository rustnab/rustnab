#!/usr/bin/env bash
# Build a ready-to-flash Raspberry Pi OS Lite image for a rabbit, from macOS.
#
#   tools/make-image.sh zero1      # 32-bit, Raspberry Pi Zero W
#   tools/make-image.sh zero2      # 64-bit, Raspberry Pi Zero 2 W
#
# The image boots, joins your WiFi, trusts one SSH key, enables I2C and
# installs the tools the milestone 0 spikes need. Raspberry Pi OS Trixie reads
# these settings with cloud-init from three files on the FAT boot partition
# (user-data, network-config, meta-data), the same files Raspberry Pi Imager
# writes. macOS can mount that partition, so no Linux machine is needed.
#
# The finished image contains the WiFi password in plain text. It is written to
# images/, which git ignores. Do not publish it.
#
# WiFi credentials come from RUSTNAB_WIFI_SSID and RUSTNAB_WIFI_PASSWORD, or
# from a prompt. Options:
#   --user NAME        login user on the rabbit (default: your macOS user)
#   --country CC       WiFi regulatory domain (default: NO)
#   --timezone TZ      (default: Europe/Oslo)
set -euo pipefail

[ "$(uname -s)" = Darwin ] || { echo "error: this script uses diskutil and runs on macOS only" >&2; exit 1; }

BOARD="${1:-}"
shift || true
USER_NAME="$USER"
COUNTRY=NO
TIMEZONE=Europe/Oslo
while [ $# -gt 0 ]; do
  case "$1" in
    --user) USER_NAME="$2"; shift 2 ;;
    --country) COUNTRY="$2"; shift 2 ;;
    --timezone) TIMEZONE="$2"; shift 2 ;;
    *) echo "error: unknown option $1" >&2; exit 1 ;;
  esac
done

case "$BOARD" in
  zero1) ARCH=armhf ;;
  zero2) ARCH=arm64 ;;
  *) echo "usage: $0 zero1|zero2 [--user NAME] [--country CC] [--timezone TZ]" >&2; exit 1 ;;
esac
HOST="rabbit-$BOARD"

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IMAGES="$REPO/images"
KEY="$HOME/.ssh/id_ed25519_rabbit"
mkdir -p "$IMAGES"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }

# --- WiFi credentials ---------------------------------------------------------
SSID="${RUSTNAB_WIFI_SSID:-}"
PASS="${RUSTNAB_WIFI_PASSWORD:-}"
[ -n "$SSID" ] || read -r -p "WiFi network name: " SSID
[ -n "$PASS" ] || { read -r -s -p "WiFi password for $SSID: " PASS; echo >&2; }
[ -n "$SSID" ] && [ -n "$PASS" ] || { echo "error: WiFi name and password are required" >&2; exit 1; }
[ ${#PASS} -ge 8 ] || { echo "error: a WPA password has at least 8 characters" >&2; exit 1; }

# --- SSH key and ~/.ssh/config --------------------------------------------------
# A dedicated key, so the rabbit never holds a key that also signs commits.
if [ ! -f "$KEY" ]; then
  log "creating SSH key $KEY"
  ssh-keygen -q -t ed25519 -N "" -C "rabbit@$(hostname -s)" -f "$KEY"
fi
PUBKEY="$(cat "$KEY.pub")"

SSH_CONFIG="$HOME/.ssh/config"
BEGIN="# >>> rustnab rabbits >>>"
END="# <<< rustnab rabbits <<<"
touch "$SSH_CONFIG"
if ! grep -qF "$BEGIN" "$SSH_CONFIG"; then
  cp "$SSH_CONFIG" "$SSH_CONFIG.before-rustnab"
  log "adding rabbit hosts to $SSH_CONFIG (backup at $SSH_CONFIG.before-rustnab)"
  {
    echo
    echo "$BEGIN"
    for h in rabbit-zero1 rabbit-zero2; do
      echo "Host $h"
      echo "  HostName $h.local"
      echo "  User $USER_NAME"
      echo "  IdentityFile $KEY"
      echo "  IdentitiesOnly yes"
    done
    echo "$END"
  } >> "$SSH_CONFIG"
fi

# --- base image -------------------------------------------------------------------
# The OS list Raspberry Pi Imager reads names the current Trixie Lite image and
# its checksum, so the script never pins a date that goes stale.
log "looking up the current Raspberry Pi OS Lite ($ARCH)"
read -r URL SHA < <(curl -fsSL https://downloads.raspberrypi.com/os_list_imagingutility_v4.json | python3 -c '
import json, sys
arch = sys.argv[1]
def walk(items):
    for i in items:
        if "subitems" in i:
            yield from walk(i["subitems"])
        else:
            yield i
for i in walk(json.load(sys.stdin)["os_list"]):
    u = i.get("url", "")
    if f"/raspios_lite_{arch}/" in u and i.get("init_format") == "cloudinit-rpi":
        print(u, i["extract_sha256"]); break
' "$ARCH")
[ -n "${URL:-}" ] || { echo "error: no cloud-init Lite image for $ARCH in the OS list" >&2; exit 1; }
BASE="$IMAGES/$(basename "$URL" .xz)"

if [ ! -f "$BASE" ] || [ "$(shasum -a 256 "$BASE" | cut -d' ' -f1)" != "$SHA" ]; then
  log "downloading $(basename "$URL")"
  curl -fL --progress-bar -o "$BASE.xz" "$URL"
  log "decompressing"
  xz -df "$BASE.xz"
  [ "$(shasum -a 256 "$BASE" | cut -d' ' -f1)" = "$SHA" ] || { echo "error: checksum mismatch for $BASE" >&2; rm -f "$BASE"; exit 1; }
fi

OUT="$IMAGES/$HOST.img"
log "copying base image to $OUT"
cp "$BASE" "$OUT"
chmod 600 "$OUT"

# --- cloud-init files ---------------------------------------------------------------
# JSON strings are valid YAML double-quoted scalars, so json.dumps quotes the
# SSID and password safely whatever characters they contain. Quoting also keeps
# YAML from reading the country code NO as the boolean false.
q() { python3 -c 'import json, sys; print(json.dumps(sys.argv[1]))' "$1"; }

MNT="$(mktemp -d)"
DISK=""
cleanup() {
  [ -n "$DISK" ] && diskutil quiet eject "$DISK" 2>/dev/null || true
  rmdir "$MNT" 2>/dev/null || true
}
trap cleanup EXIT

DISK="$(diskutil image attach --noMount "$OUT" | awk 'NR==1 {print $1}')"
diskutil quiet mount -mountPoint "$MNT" "${DISK}s1"
[ -f "$MNT/cmdline.txt" ] || { echo "error: ${DISK}s1 does not look like a Raspberry Pi boot partition" >&2; exit 1; }

cat > "$MNT/meta-data" <<META
instance-id: rustnab-$HOST-$(date +%Y%m%d%H%M%S)
META

cat > "$MNT/network-config" <<NET
network:
  version: 2
  wifis:
    wlan0:
      dhcp4: true
      optional: true
      regulatory-domain: $(q "$COUNTRY")
      access-points:
        $(q "$SSID"):
          password: $(q "$PASS")
NET

# Packages are the ones spikes/00-prepare.sh installs. avahi-daemon makes the
# rabbit reachable as <hostname>.local. The apt Check-Date setting matters on
# a Pi Zero: it has no real time clock, and apt rejects repository metadata
# while the clock still says 1970 before NTP has run.
cat > "$MNT/user-data" <<USER
#cloud-config
hostname: $(q "$HOST")
manage_etc_hosts: true
timezone: $(q "$TIMEZONE")

user:
  name: $(q "$USER_NAME")
  shell: /bin/bash
  lock_passwd: true
  ssh_authorized_keys:
    - $(q "$PUBKEY")
  sudo: ALL=(ALL) NOPASSWD:ALL
ssh_pwauth: false

rpi:
  interfaces:
    i2c: true

apt:
  preserve_sources_list: true
  conf: |
    Acquire {
      Check-Date "false";
    };

packages:
  - avahi-daemon
  - device-tree-compiler
  - gpiod
  - alsa-utils
  - mpg123
  - i2c-tools
  - sox
  - time
  - curl
  - bzip2

runcmd:
  - [ systemctl, enable, --now, ssh ]
USER

chmod 600 "$OUT"
sync
diskutil quiet unmount "$MNT"
diskutil quiet eject "$DISK"
DISK=""

log "done: $OUT"
cat >&2 <<DONE

Flash it. Find the SD card first, then check twice that N is the card and not
your Mac's disk. dd erases the whole target without asking.

  diskutil list external
  diskutil unmountDisk /dev/diskN
  sudo dd if=$OUT of=/dev/rdiskN bs=4m status=progress
  diskutil eject /dev/diskN

First boot takes several minutes: cloud-init installs packages over WiFi.
Then: ssh $HOST
DONE
