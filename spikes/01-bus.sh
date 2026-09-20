#!/usr/bin/env bash
# Scan I2C bus 1 and check that the tagtagtag board's chips answer.
source "$(dirname "$0")/lib.sh"
require i2cdetect

results_begin "I2C bus"
scan="$(sudo i2cdetect -y 1)"
echo "$scan"
echo >> "$RESULT_FILE"

has() { echo "$scan" | grep -qiE "(^| )$1( |$)"; }

check() { # <addr> <name> <required>
  if has "$1"; then result "$2 at 0x$1" PASS
  elif [ "$3" = required ]; then result "$2 at 0x$1" FAIL "not answering"
  else result "$2 at 0x$1" INFO "not present"
  fi
}
check 1a "WM8960 codec" required
check 50 "CR14 or ST25R3917 reader" optional
check 40 "Si7021 temperature and humidity" optional
if has 18 || has 19; then result "LIS3DH accelerometer" PASS "0x$(has 18 && echo 18 || echo 19)"
else result "LIS3DH accelerometer" INFO "not present at 0x18 or 0x19"; fi
results_end
