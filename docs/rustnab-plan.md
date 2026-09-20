# rustnab: plan

rustnab is a replacement firmware for the Nabaztag rabbit on Raspberry Pi Zero boards with the tagtagtag board. It is written in Rust, runs on current Raspberry Pi OS, and adds on-device speech recognition and synthesis. It is for the Nabaztag community, not for one rabbit. It lives in its own GitHub organization, `rustnab`, under GPL-3.

This document records the decisions and the reasons behind them. The reference documents next to it (protocol, packets, state machine, service architecture, hardware) describe pynab as it is today. Where they conflict with this plan, this plan wins.

## Why replace pynab

- Upstream pynab is inactive. The last release is 1.0.2 from November 2022, the last commit is from January 2025, and the community calls the project dead in issue 493. The living fork (f-laurens) still targets Debian 11 only.
- Nothing in the stack runs past Debian 11. The install script recognizes only Debian 10 and 11 on armv7l, Python 3.7 and 3.9, and a Kaldi build pinned to a 2020 release. DietPi users are capped at version 9.20.
- The kernel drivers are half broken on kernel 6.x. The wm8960 sound fork fails to build on 6.12 and has an open capture crackle bug. The ears and NFC modules have kernel 6.6 fixes sitting in unmerged pull requests.
- The Zero 2 W, the board we want, is the one pynab handles worst. Issue 316 (recognition fails, daemon pinned at 100% CPU) has been open since 2022 and was never traced.
- Postgres takes over half the rabbit's RAM for a few dozen settings rows (issue 110, ignored).
- pynab has no text to speech. Everything spoken is one of 5841 pre-recorded MP3 files.

Rust does not make speech recognition faster by itself. The gains come from the engine swap, from removing Postgres and thirteen Python processes, and from owning the drivers.

## Hardware and OS

Supported boards: the tagtagtag 2019/2021 Ulule board, the original CR14 RFID reader, and the 2022 ST25R3917 NFC card. The 2018 Maker Faire board is not supported. pynab already broke it at 0.7.

Supported computers: Raspberry Pi Zero 2 W as the first-class target, Raspberry Pi Zero (1) W as a degraded target. Degraded means no on-device speech. Everything else works, and cloud speech providers work.

Two builds, because the Zero 2 W runs a 64-bit kernel and the Zero 1 cannot:

- `aarch64-unknown-linux-gnu` for Zero 2 W on Raspberry Pi OS Lite 64-bit. This build carries the local speech engine.
- `arm-unknown-linux-gnueabihf` for Zero 1 on Raspberry Pi OS Lite 32-bit, compiled with `target-cpu=arm1176jzf-s`. ARMv7 code crashes with illegal instruction on this CPU.

On-device speech is aarch64 only for a hard reason. ONNX Runtime ships no 32-bit ARM binaries and Vosk has no ARMv6 build. Whisper tiny measured about 18 seconds per utterance even on a Zero 2 W. The only engine that runs on ARMv6 is Kaldi through a C++ shim, and that path ends with the old models and the old build pain. We do not take it.

Target OS is Raspberry Pi OS Lite Trixie (Debian 13, kernel 6.12). The armhf smoke build runs on a bare Zero 1 from milestone 1 on, because finding an ARMv6-incompatible crate late is expensive.

The tagtagtag board also carries a Si7021 temperature and humidity sensor and a LIS3DH accelerometer that pynab never reads. rustnab reads both and exposes them as events from the first release.

## Drivers: userspace, no kernel modules

rustnab maintains no kernel modules. Each pguyot module was checked against what userspace can do:

- Ears. Two DC motors through an SN754410 H-bridge, one optical slot sensor per ear through an LM393 comparator. 17 slots per turn, edges about 200 ms apart, a 750 ms gap as the index mark. The kernel module exists for interrupt timestamps, and the GPIO character device gives those too. rustnab drives the ears from userspace with the `gpiocdev` crate.
- CR14 RFID. I2C at address 0x50, no interrupt line, polled every 500 ms. A userspace I2C poller.
- ST25R3917 NFC. I2C at address 0x50, no interrupt line, polled every 10 ms. Same address as the CR14, so the two readers are exclusive by hardware, and the boot probe picks one. The driver is a real one (ISO 14443 A and B, ISO 15693, NDEF). rustnab ports pguyot's GPL kernel code to a standalone Rust crate, `st25r39xx`, published on crates.io because it has value outside rabbits.
- Sound. See the next section.
- LEDs. Five NeoPixels on GPIO 13 need PWM DMA through `/dev/mem`, which is why pynab runs the whole daemon as root. rustnab puts the LEDs in a small privileged helper, `rustnab-leds`, behind a unix socket. The main daemon runs as an unprivileged user in the gpio, i2c and audio groups. A root process that holds cloud API keys and serves HTTP is the one pynab design we refuse to copy. SPI-driven LEDs are not an option: SPI MOSI is GPIO 10, which is the right ear forward pin.
- Button on GPIO 17 through the GPIO character device.

Performance is not a concern for any of these. The fastest loop is the 10 ms NFC poll, whose I2C read takes about one millisecond.

## Sound: mainline codec, our overlay

pguyot's wm8960 fork is a May 2019 copy of the mainline codec with three real patches: slave-mode clock configuration, simple-audio-card compatibility, and optional gain pins in the MAX9759 amplifier driver. Everything else in the fork is compatibility shims for newer kernels. Mainline has since absorbed the clocking fix. It is also better than the fork in four ways. Capture is no longer muted together with playback. The anti-pop discharge no longer blocks for 600 ms on every bias change. Headphone jack detection is real. Clock configuration no longer depends on bias state.

The one trap: the board has a 12.000 MHz crystal, and no standard sample rate divides from it directly. The codec must use its PLL. Mainline only enters the PLL path when the codec's I2C node carries a clock phandle:

```dts
wm8960: wm8960@1a {
    compatible = "wlf,wm8960";
    reg = <0x1a>;
    #sound-dai-cells = <0>;
    clocks = <&wm8960_mclk>;   /* fixed-clock, clock-frequency = <12000000> */
    clock-names = "mclk";
};
```

Do not use `system-clock-frequency` on the DAI link for this. It sets the system clock without setting the PLL input, and the codec then runs at 46875 Hz without an error. The symptom is `dmesg` printing `slave mode, but proceeding with no clock configuration`. This is the bug behind pynab issue 438 ("rabbit is mute with latest kernels"): a stock kernel loaded mainline wm8960 with an overlay that gave it no clock.

Both Raspberry Pi kernel builds (ARMv6 `bcmrpi` and arm64 `bcm2711`) ship `wm8960`, `simple-audio-card` and the bcm2835 I2S driver as modules. Neither ships the MAX9759 driver, and mainline's version refuses to probe without gain pins the board does not wire. So rustnab drives the amplifier from userspace: shutdown on GPIO 7, mute on GPIO 8. Jack detect on GPIO 25 and the two volume switches on GPIO 22 and 27 are read the same way. The volume policy that pynab's `tagtagtag-mixerd` daemon applied (different Speaker and Headphone ranges per rabbit model) moves into rustnab. rustnab applies that policy and unmutes the amplifier only after the ALSA card has appeared, by watching for the device rather than sleeping. The codec probes late at boot, and pynab users hit a race here.

The overlay ships in the rustnab package. If the milestone 0 spike shows the mainline codec misbehaving in a way the overlay cannot fix, the fallback is to fork the codec, and only then.

Microphones: two analog MEMS microphones on the board into the codec's left and right line inputs. They work as soon as the overlay works.

## Architecture

One daemon. pynab's thirteen processes exist because of Python, not by design. In rustnab the services (clock, weather, surprise, taichi, book, radio, webhook) are tokio tasks in one process, with typed channels, one config and one log.

Cargo workspace:

- `rustnab-hal`: traits for ears, LEDs, button, RFID, audio in and out, sensors.
- `rustnab-hal-linux`: the real implementations on gpiocdev, i2cdev, alsa and the LED helper client.
- `rustnab-hal-sim`: a simulator so the daemon runs on macOS and in tests without a board.
- `rustnab-protocol`: pynab packet types, the JSGF parser and the intent matcher.
- `rustnab-speech`: recognition and synthesis traits, the sherpa-onnx backend (aarch64 only), the OpenAI-compatible backend.
- `rustnab-core`: state machine, scheduler, service host, SQLite store.
- `rustnab-services`: the built-in services.
- `rustnab-api`: Axum HTTP with OpenAPI, server-sent events, and the legacy TCP socket.
- `rustnab`: the daemon binary.
- `rustnab-leds`: the privileged LED helper.
- `st25r39xx`: the NFC driver crate.

Integration surface. The HTTP JSON API with OpenAPI documentation and a server-sent events stream is the primary interface for the future web UI and for third parties. Authentication is an optional bearer token, off by default, because a LAN rabbit with no auth is what users have today and retrofitting auth is painful. pynab's TCP protocol on port 10543 stays wire-compatible as a legacy ingress so unmodified Python services and community scripts keep working. New event types (tap, temperature) go on both surfaces. Legacy services ignore packet types they do not know.

Storage. SQLite through `rusqlite` with the bundled feature, called from blocking tasks behind a small repository trait. State is a few hundred rows: settings, RFID tag bindings, schedules. Secrets (cloud keys, webhook tokens) live in a separate file with mode 0600 owned by the rustnab user, so a settings export or a bug report never carries a key.

WiFi onboarding stays with comitup from Debian. No maintained Rust captive portal exists. balena wifi-connect is stalled, with open bugs on both Trixie and Zero 2 W. A hand-rolled one on the `nmrs` crate would hit the same dnsmasq conflicts comitup already solved. rustnab reads comitup's state over D-Bus so the API can report onboarding progress.

## Speech

Recognition and synthesis sit behind a provider trait so users pick their privacy level. Two providers ship:

- Local, aarch64 only: the official `sherpa-onnx` crate for both recognition and synthesis. One native dependency to cross-compile. The archived `sherpa-rs` crate is not used. First picks are Moonshine tiny (its cost scales with utterance length, and a French fine-tune exists) for recognition, and Piper `fr_FR` and `en_GB` at low or x_low quality for synthesis. Piper medium is already slow on a Pi 4. These picks are reconsidered if the milestone 0 benchmark is unsatisfying.
- Cloud: any OpenAI-compatible HTTP endpoint. One implementation covers hosted vendors and self-hosted Whisper servers, which gives self-hosters a middle privacy tier.

Listening starts when the user holds the head button, as in pynab. No wake word. Always-on capture on a 512 MB board is a separate project.

Intents come from the JSGF grammars pynab ships in its `asr/` directory for French and English. They are GPL-3 and move into this repository in milestone 2. rustnab parses JSGF and compiles it to a matcher over the recognized text, which keeps the existing multilingual command coverage and, later, lets the same grammar bias the recognizer toward expected phrases. Intent extraction through a language model is a later, optional provider.

Pre-recorded sounds stay. They are the rabbit's personality and cover eight locales. Synthesis is for text no one can pre-record: weather sentences, messages, service output.

Languages: French and English first. Norwegian when a model exists.

## Distribution

- `.deb` packages built with `cargo-deb`, one per architecture, installed by a script on a stock Raspberry Pi OS Lite.
- Two SD card images built with pi-gen in GitHub Actions, arm64 for Zero 2 W and armhf for Zero 1, each with the package, the sound overlay, comitup and first-boot setup preinstalled.
- Self-update through an API endpoint that checks GitHub releases, downloads the package, installs it and restarts. No package repository to host.
- Cross-compiled from macOS with `cargo-zigbuild`, no Docker. A `just deploy` recipe copies the binary to the rabbit over SSH and restarts the service. `cross` is the fallback if the C++ link of sherpa-onnx fights zig.
- No migration from pynab installs. Users reinstall and re-enter a handful of settings.

## Non-goals

- The 2018 Maker Faire board.
- On-device speech on Zero 1.
- Mastodon and IFTTT services.
- A web UI in the first release. The API comes first, the UI is a separate project.
- Wake word detection.
- Reading pynab's Postgres database.

## Milestones

Milestone 0, spikes with a go or no-go each. Run the first two on the Zero 1 while it is still in the rabbit, from a Trixie 32-bit SD card, because it is the harder target. Then swap in the Zero 2 W for the third.

1. Sound: mainline wm8960 with our overlay plays a file at 44.1 kHz and records the two microphones at 16 kHz on Trixie. `dmesg` shows no clock warning. No-go means fork the codec.
2. Ears: a userspace driver homes both ears, moves to a position, and detects a user turning an ear. No-go is not expected.
3. Speech benchmark on the Zero 2 W: real-time factor and resident memory for Moonshine tiny, a streaming Zipformer and Whisper tiny int8 through sherpa-onnx, and for two Piper qualities. Pick by measurement.

Milestone 1, a rabbit without a voice. Ears, LEDs through the helper, button, sound playback, CR14, the clock service, the HTTP API, the simulator, and the legacy socket. Exit: the rabbit replaces pynab for daily use on the Zero 2 W, and the armhf build runs against the simulator on the bare Zero 1.

Milestone 2, speech. Local recognition and synthesis on aarch64, the OpenAI-compatible provider, JSGF intents. Exit: hold the button, ask for the weather in French and in English, hear the answer.

Milestone 3, services and sensors. Weather, surprise, taichi, radio, webhook, book. Tap and temperature events. Volume policy.

Milestone 4, distribution. The `st25r39xx` crate and NFC card support, the Zero 1 hardware pass, both images, self-update.

## Open risks

- The Moonshine French export on Hugging Face may not match the model layout sherpa-onnx expects. The benchmark in milestone 0 settles this.
- Every speech number we have comes from other boards or from unverified exports. Treat them as hypotheses until measured on the Zero 2 W.
- The `rs_ws281x` LED crate was last published in December 2023. Nobody has confirmed or denied that it works on a Zero 2 W with kernel 6.x. The privileged helper isolates the blast radius if it does not.
- Zig linking sherpa-onnx's static C++ archives is untested for this project.

## Board reference

Pins are BCM numbers. Taken from pguyot's device tree overlays and the tagtagtag V2.0 schematic.

- Ears: left encoder 24, right encoder 23. Left motor forward 12, backward 11. Right motor forward 10, backward 9. Direction only, no speed control. Ear position offset from the index mark is 3 slots.
- Button: 17.
- LEDs: 13 (PWM1), five pixels, 800 kHz, DMA channel 12, through a Schmitt buffer.
- Sound: WM8960 on I2C 0x1a, I2S on 18 to 21, 12.000 MHz crystal. Amplifier MAX9759 shutdown 7, mute 8. Jack detect 25. Volume switches 22 and 27.
- RFID and NFC: I2C 0x50 for both the CR14 and the ST25R3917. The 2022 NFC card uses a 27.12 MHz crystal.
- Sensors: Si7021 temperature and humidity, LIS3DH accelerometer, both on I2C.
- Ear timing: slot high 120 to 150 ms, slot low 60 to 90 ms, index gap 750 ms, one full turn about 4 s.
