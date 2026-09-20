#!/usr/bin/env bash
# Install the tools the spikes need and turn on the I2C bus. Run once per card.
source "$(dirname "$0")/lib.sh"

log "installing packages"
sudo apt-get update -qq
sudo apt-get install -y -qq device-tree-compiler gpiod alsa-utils mpg123 i2c-tools sox time curl bzip2 >/dev/null

log "enabling i2c"
sudo raspi-config nonint do_i2c 0

results_begin "Prepare"
result "packages" PASS "$(dpkg-query -W -f='${Package} ${Version}\n' gpiod device-tree-compiler alsa-utils | tr '\n' ';')"
result "i2c enabled" "$([ -e /dev/i2c-1 ] && echo PASS || echo FAIL)" "/dev/i2c-1"
result "gpiochip" INFO "$(gpiochip)"
results_end
