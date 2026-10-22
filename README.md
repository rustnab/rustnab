# rustnab

Replacement firmware for the Nabaztag rabbit on a Raspberry Pi Zero with the tagtagtag board. Written in Rust. Runs on current Raspberry Pi OS. Adds on-device speech recognition and synthesis on the Zero 2 W, with cloud providers as an alternative for the Zero (1) W and for anyone who prefers them.

rustnab replaces [pynab](https://github.com/nabaztag2018/pynab), which is no longer maintained. It keeps pynab's TCP protocol so existing pynab services keep working, and it reuses pynab's recorded sounds.

Status: planning and early scaffolding. Nothing runs on a rabbit yet. Follow the milestones in [docs/rustnab-plan.md](docs/rustnab-plan.md).

## Supported hardware

- Raspberry Pi Zero 2 W, first class.
- Raspberry Pi Zero W, without on-device speech.
- tagtagtag 2019/2021 board, with the CR14 RFID reader or the 2022 NFC card.

The 2018 Maker Faire board is not supported.

## Documentation

[docs/README.md](docs/README.md) lists the plan and the reference documents.

## Building

You need a stable Rust toolchain. `rustup` picks up the rest from `rust-toolchain.toml`.

```sh
cargo check --workspace
cargo test --workspace
```

Cross builds for the rabbit use [cargo-zigbuild](https://github.com/rust-cross/cargo-zigbuild), which needs `zig` and `just`:

```sh
brew install zig just
cargo install cargo-zigbuild
just build-zero2      # aarch64, Zero 2 W
just build-zero1      # ARMv6, Zero W
just deploy rabbit.local
```

## Preparing a rabbit

On a Mac, build an SD card image with your WiFi and SSH access:

```sh
tools/make-image.sh zero1     # or zero2
```

The script prints the flash command when it finishes. The image holds your WiFi password, so it stays in the git-ignored `images/` folder.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
