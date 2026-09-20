#!/usr/bin/env bash
# Compile and install the tagtagtag sound overlay, then edit config.txt.
# Idempotent. Reboot afterwards, then run 11-sound-test.sh.
source "$(dirname "$0")/lib.sh"
require dtc

DTS="$SPIKE_ROOT/hardware/overlays/tagtagtag-sound-overlay.dts"
CONFIG=/boot/firmware/config.txt
[ -f "$DTS" ] || fail "overlay source not found at $DTS"
[ -f "$CONFIG" ] || fail "$CONFIG not found. This script expects Raspberry Pi OS Bookworm or later."

results_begin "Sound overlay install"

log "compiling overlay"
dtc -@ -I dts -O dtb -o /tmp/tagtagtag-sound.dtbo "$DTS"
sudo install -m 644 /tmp/tagtagtag-sound.dtbo /boot/firmware/overlays/tagtagtag-sound.dtbo
result "overlay compiled and installed" PASS "$(stat -c %s /boot/firmware/overlays/tagtagtag-sound.dtbo) bytes"

if [ ! -f "$CONFIG.rustnab-backup" ]; then
  sudo cp "$CONFIG" "$CONFIG.rustnab-backup"
  log "backup of config.txt at $CONFIG.rustnab-backup"
fi

# Onboard audio off: the Zero has no analog jack, and the bcm2835 audio device
# would otherwise take card index 0 and confuse tools that assume one card.
sudo sed -i -E 's/^(dtparam=audio=on)/# \1 (disabled by rustnab spike)/' "$CONFIG"
for line in "dtparam=audio=off" "dtoverlay=tagtagtag-sound"; do
  grep -qxF "$line" "$CONFIG" || echo "$line" | sudo tee -a "$CONFIG" >/dev/null
done
result "config.txt" PASS "$(grep -E 'audio|tagtagtag' "$CONFIG" | tr '\n' ';')"
results_end

log "reboot now, then run 11-sound-test.sh"
