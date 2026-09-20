set shell := ["bash", "-euo", "pipefail", "-c"]

zero2 := "aarch64-unknown-linux-gnu"
zero1 := "arm-unknown-linux-gnueabihf"

default: check

check:
    cargo fmt --all --check
    cargo clippy --workspace --all-targets -- -D warnings
    cargo test --workspace

# Release build for the Zero 2 W (64-bit OS).
build-zero2:
    cargo zigbuild --release --workspace --target {{zero2}}

# Release build for the Zero W (32-bit OS). No local speech on this target.
build-zero1:
    cargo zigbuild --release --workspace --target {{zero1}}

# Copy the daemon and LED helper to a rabbit over SSH and restart the service.
# The rabbit must already have the rustnab package installed once, so the
# systemd units and the rustnab user exist.
deploy host target=zero2:
    cargo zigbuild --release --target {{target}} -p rustnab -p rustnab-leds
    scp target/{{target}}/release/rustnab target/{{target}}/release/rustnab-leds {{host}}:/tmp/
    ssh {{host}} 'sudo install -m 755 /tmp/rustnab /tmp/rustnab-leds /usr/local/bin/ && sudo systemctl restart rustnab-leds rustnab'

# Run a milestone 0 spike on a rabbit: just spike user@rabbit.local 11 [--no-interactive]
spike host what *args:
    spikes/run.sh {{host}} {{what}} {{args}}
