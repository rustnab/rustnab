# Milestone 0: spikes

Three experiments decide whether the plan holds before any daemon code is written. Each one ends in a go or no-go. Run the sound and ears spikes on the Zero W while it is still in the rabbit, then swap in the Zero 2 W for the speech benchmark. Nothing here needs rustnab installed, only stock Raspberry Pi OS and shell tools.

Every spike exists twice: as the manual steps below, and as a script in `spikes/` that runs the same steps and writes a results table to `spikes/results/`. Use the scripts. The manual steps are the explanation of what the scripts do and the fallback when one of them misbehaves.

From a laptop, `spikes/run.sh user@rabbit.local 11` pushes the scripts and the overlay to the rabbit over SSH, runs the script whose name starts with `11`, and pulls the results back into `spikes/results/<host>/`. Steps that need a person at the rabbit (plugging a cable, turning an ear, speaking) show a prompt with a countdown. Pass `--no-interactive` to skip them. The script order is:

1. `00-prepare.sh`, packages and I2C, once per card.
2. `01-bus.sh`, I2C scan.
3. `10-sound-install.sh`, overlay and `config.txt`, then reboot.
4. `11-sound-test.sh`.
5. `20-ears.sh`.
6. `30-speech-bench.sh`, Zero 2 W only.

Record results in the tables at the end of each spike and commit them. A number measured on the board is worth more than any estimate in the plan.

## Prepare the card

1. Flash Raspberry Pi OS Lite (Trixie) with Raspberry Pi Imager. For the Zero W take the 32-bit image. For the Zero 2 W take the 64-bit image.
2. In the Imager settings, set a hostname, enable SSH, and enter your WiFi. comitup is not needed for the spikes.
3. Boot, log in over SSH, then install the tools:

```sh
sudo apt update
sudo apt install -y device-tree-compiler gpiod alsa-utils mpg123 i2c-tools sox
```

4. Clone this repository on your laptop if you have not, and copy `hardware/overlays/tagtagtag-sound-overlay.dts` to the rabbit with `scp`.

5. Confirm the GPIO chip name. On both boards the main GPIO block is `gpiochip0`:

```sh
gpiodetect
```

Every `gpioset` and `gpiomon` command below assumes `gpiochip0`. If `gpiodetect` shows another name for the `pinctrl-bcm2835` or `pinctrl-bcm2711` chip, use that name.

## Bus check

Before touching sound, confirm the board answers on I2C. Expected addresses: `1a` codec, `50` RFID or NFC reader, `40` Si7021 temperature sensor, `18` or `19` LIS3DH accelerometer.

```sh
sudo raspi-config nonint do_i2c 0
sudo i2cdetect -y 1
```

Write down which addresses answer. A missing `1a` means the sound spike cannot pass and the problem is wiring or power, not software.

## Spike 1: sound on the mainline codec

Goal: the mainline `wm8960` codec with our overlay plays at 44.1 kHz and records the two onboard microphones at 16 kHz, with no clock warning in the kernel log.

### Install the overlay

```sh
dtc -@ -I dts -O dtb -o tagtagtag-sound.dtbo tagtagtag-sound-overlay.dts
sudo cp tagtagtag-sound.dtbo /boot/firmware/overlays/
```

Edit `/boot/firmware/config.txt`. Remove or comment out `dtparam=audio=on`, then add at the end:

```ini
dtparam=audio=off
dtoverlay=tagtagtag-sound
```

Reboot.

### Check the kernel log

```sh
sudo dmesg | grep -iE 'wm8960|simple-audio|i2s|asoc'
aplay -l
```

Pass when:

- `aplay -l` lists a card named `tagtagtagsound`.
- The log does not contain `slave mode, but proceeding with no clock configuration`. That line means the PLL input is zero and the codec runs at the wrong rate. If you see it, the overlay is wrong, stop and fix it before testing audio.
- The log does not contain `failed to configure clock` or `soc_pcm_hw_params() failed`.

### Enable the amplifier

The overlay leaves the MAX9759 in shutdown. Enable it and unmute from userspace for the duration of the test. The command holds the lines until you stop it, so run it in a second SSH session or with `-z` to background it:

```sh
gpioset -z -c gpiochip0 7=1 8=1
```

### Set the mixer

The codec starts with every path off. List the controls once, then set a starting point. On a Nabaztag:tag the speaker sits behind the headphone outputs. On an original Nabaztag it sits on the right speaker output. Set both.

```sh
amixer -c tagtagtagsound scontrols
amixer -c tagtagtagsound sset 'Left Output Mixer PCM' on
amixer -c tagtagtagsound sset 'Right Output Mixer PCM' on
amixer -c tagtagtagsound sset 'Playback' 230
amixer -c tagtagtagsound sset 'Headphone' 100
amixer -c tagtagtagsound sset 'Speaker' 100
```

Start quiet. pynab's mixer daemon capped Headphone at 120 and Speaker at 127 out of 127 for a reason.

### Play

```sh
speaker-test -D plughw:CARD=tagtagtagsound -c 2 -t sine -f 440 -l 2
```

Listen for pitch. A 440 Hz sine at the wrong PLL setting comes out flat by about six percent, close to a semitone. If you have a tuner app, use it. Then play a real file, at 44.1 kHz and at 48 kHz:

```sh
sox -n -r 44100 -c 2 sine441.wav synth 3 sine 440
sox -n -r 48000 -c 2 sine48.wav synth 3 sine 440
aplay -D plughw:CARD=tagtagtagsound sine441.wav
aplay -D plughw:CARD=tagtagtagsound sine48.wav
```

While a file plays, read the rate ALSA negotiated:

```sh
cat /proc/asound/tagtagtagsound/pcm0p/sub0/hw_params
```

Then play one of pynab's MP3 files through `mpg123 -a plughw:CARD=tagtagtagsound file.mp3` and listen for the two known failure modes from pynab's history: a sizzle on top of the sound, and periodic crackle.

### Record

Enable the microphone path, record five seconds from both onboard microphones at 16 kHz, then play it back:

```sh
amixer -c tagtagtagsound sset 'Capture' 40
amixer -c tagtagtagsound sset 'Left Input Boost Mixer LINPUT1' 3
amixer -c tagtagtagsound sset 'Right Input Boost Mixer RINPUT1' 3
amixer -c tagtagtagsound sset 'Left Boost Mixer LINPUT1' on
amixer -c tagtagtagsound sset 'Right Boost Mixer RINPUT1' on
arecord -D plughw:CARD=tagtagtagsound -f S16_LE -r 16000 -c 2 -d 5 mic.wav
aplay -D plughw:CARD=tagtagtagsound mic.wav
sudo dmesg | grep -i 'sync error'
```

Speak while it records. Copy `mic.wav` to your laptop and look at it in any waveform viewer for a periodic tick about six times a second, the crackle from pguyot's wm8960 issue 28. An `I2S SYNC error` line in the log is the same problem seen from the kernel.

If a control name in the commands above does not exist on your kernel, take the closest one from `amixer scontrols`. Control names are the mainline codec's, and they differ slightly between kernel versions.

### Jack detect and volume switches

Plug a 3.5 mm cable into the line out and watch the jack state change:

```sh
amixer -c tagtagtagsound contents | grep -A2 -i jack
```

Turn the volume wheel and watch the two switch lines:

```sh
gpiomon -c gpiochip0 -E realtime --format '%S %E %o' 22 27
```

Note which line changes in which direction. rustnab needs this to port the volume policy.

### Release the amplifier

Stop the `gpioset` process. The amplifier goes back to shutdown.

### Results

| Check | Result |
|---|---|
| Card `tagtagtagsound` present | |
| No clock warning in the log | |
| 440 Hz sine sounds in tune | |
| 44.1 kHz file plays | |
| 48 kHz file plays | |
| MP3 plays without sizzle or crackle | |
| Microphones record speech at 16 kHz | |
| No tick in the recording, no sync error | |
| Jack detect changes on plug | |
| Volume switch lines change on turn | |
| Kernel version (`uname -r`) | |

Go: every row passes. No-go: the clock warning appears, or playback is off pitch, or the recording has the tick. Then the fallback is a fork of the codec with the Linux 6.18 patches from olb17's alfredpi_rpi3a repository, and the plan's sound section gets rewritten.

## Spike 2: ears from userspace

Goal: a userspace process drives the ear motors and sees every encoder edge with usable timestamps, so no kernel module is needed.

Pins, BCM numbering:

- Left ear: encoder 24, motor forward 12, motor backward 11.
- Right ear: encoder 23, motor forward 10, motor backward 9.

Expected signal, from pguyot's driver: 17 slots per turn, high for 120 to 150 ms and low for 60 to 90 ms per slot, one gap where the line stays high for about 750 ms, and a full turn in about 4 seconds.

If pynab is still installed on this card, stop it first, its ear module holds the pins. On a fresh Trixie card nothing holds them.

### Watch an ear turn under motor power

Open two SSH sessions. In the first, monitor the left encoder with timestamps:

```sh
gpiomon -c gpiochip0 -e falling -E realtime --format '%S %E %o' 24
```

In the second, run the left motor forward for four seconds. `gpioset` holds the lines for the hold period and releases them when it exits:

```sh
gpioset -c gpiochip0 -p 4s 12=1 11=0
```

Never set 12 and 11 high at the same time. The H-bridge treats that as brake, which is safe, but it tells you nothing.

Copy the event list from the first session. Count the edges and compute the gaps between consecutive timestamps. Repeat for the right ear with encoder 23 and motor 10 and 9, and repeat both ears backward (11 or 9 high instead).

Pass when:

- About 17 falling edges appear per full turn.
- Consecutive edges are 180 to 240 ms apart, with one interval near 900 ms where the index gap is.
- No interval is shorter than 100 ms. Shorter intervals mean bounce that the driver must filter.

### Detect a hand turn

With no motor running, monitor an encoder and turn the ear by hand. Edges must appear. This is how the rabbit notices the user moving an ear.

### About the timestamps

The kernel stamps each event when the interrupt fires, before any userspace scheduling. The `%S` field above is that timestamp. The interval between edges is the number the ear driver acts on, so scheduling jitter in the reader does not distort it. This is why the spike does not need to measure delivery latency separately.

### Results

| Check | Left forward | Left backward | Right forward | Right backward |
|---|---|---|---|---|
| Edges per turn | | | | |
| Typical interval (ms) | | | | |
| Index gap interval (ms) | | | | |
| Shortest interval (ms) | | | | |
| Hand turn detected | | | | |

Go: edges and gap match the expected signal on both ears in both directions. A no-go here is not expected. If it happens, look at the encoder power first, then at pull-up configuration on the encoder lines.

## Spike 3: speech benchmark on the Zero 2 W

Swap the Zero 2 W into the rabbit and flash the 64-bit card. Repeat the sound spike once on this board, it takes ten minutes and proves the arm64 kernel behaves the same. Then benchmark.

Goal: numbers for real-time factor and peak memory of the candidate models on the board they will run on, so the plan picks by measurement.

Everything runs from prebuilt sherpa-onnx command line tools, no Rust and no Python. Work in a scratch directory on the rabbit. The downloads total about 500 MB, so use a card of at least 16 GB.

### Get the tools and models

```sh
mkdir -p ~/bench && cd ~/bench
V=v1.13.8
B=https://github.com/k2-fsa/sherpa-onnx/releases/download
curl -LO $B/$V/sherpa-onnx-$V-linux-aarch64-shared-cpu.tar.bz2
curl -LO $B/asr-models/sherpa-onnx-moonshine-tiny-en-int8.tar.bz2
curl -LO $B/asr-models/sherpa-onnx-whisper-tiny.tar.bz2
curl -LO $B/asr-models/sherpa-onnx-streaming-zipformer-fr-kroko-2025-08-06.tar.bz2
curl -LO $B/asr-models/sherpa-onnx-nemo-fast-conformer-ctc-en-de-es-fr-14288-int8.tar.bz2
curl -LO $B/tts-models/vits-piper-fr_FR-siwis-low.tar.bz2
curl -LO $B/tts-models/vits-piper-fr_FR-upmc-medium.tar.bz2
curl -LO $B/tts-models/vits-piper-en_GB-alan-low.tar.bz2
for f in *.tar.bz2; do tar xjf "$f"; done
export PATH=$PWD/sherpa-onnx-$V-linux-aarch64-shared-cpu/bin:$PATH
export LD_LIBRARY_PATH=$PWD/sherpa-onnx-$V-linux-aarch64-shared-cpu/lib
```

Model choice, and why these four:

- Moonshine tiny, English only. Its cost grows with the length of the utterance instead of padding to 30 seconds. sherpa-onnx has no French Moonshine, so it cannot be the only recognizer.
- Whisper tiny, multilingual, int8. The reference point everyone quotes. Expected to be too slow.
- Kroko streaming Zipformer, French. A streaming transducer, 57 MB, the best French pick in the sherpa-onnx catalog.
- NeMo fast-conformer CTC, int8, English, German, Spanish and French in one 103 MB model. If it is fast enough, one model covers both of our languages.

### Test recordings

Use the rabbit's own microphones, because that is the audio the recognizer will see. With the sound spike's mixer settings in place, record one short command in each language, 16 kHz mono, then a longer sentence:

```sh
arecord -D plughw:CARD=tagtagtagsound -f S16_LE -r 16000 -c 1 -d 3 fr-short.wav
arecord -D plughw:CARD=tagtagtagsound -f S16_LE -r 16000 -c 1 -d 3 en-short.wav
arecord -D plughw:CARD=tagtagtagsound -f S16_LE -r 16000 -c 1 -d 8 fr-long.wav
```

Say something a rabbit would hear, such as a weather request. Write down what you said so you can score the transcripts.

### Run the recognizers

Wrap every run in `/usr/bin/time -v` and keep two numbers from its output: `Elapsed (wall clock) time` and `Maximum resident set size`. The sherpa-onnx tools also print their own numbers on stderr at the end of each run, on lines starting with `Elapsed seconds:` and `Real time factor (RTF):`. The synthesis tool spells it `Real-time factor (RTF):` and adds an `Audio duration:` line, so you do not need `soxi` for it. Run each command twice and keep the second run, the first pays for loading the model from the card.

```sh
M=sherpa-onnx-moonshine-tiny-en-int8
/usr/bin/time -v sherpa-onnx-offline \
  --moonshine-preprocessor=$M/preprocess.onnx \
  --moonshine-encoder=$M/encode.int8.onnx \
  --moonshine-uncached-decoder=$M/uncached_decode.int8.onnx \
  --moonshine-cached-decoder=$M/cached_decode.int8.onnx \
  --tokens=$M/tokens.txt --num-threads=4 en-short.wav

W=sherpa-onnx-whisper-tiny
/usr/bin/time -v sherpa-onnx-offline \
  --whisper-encoder=$W/tiny-encoder.int8.onnx \
  --whisper-decoder=$W/tiny-decoder.int8.onnx \
  --tokens=$W/tiny-tokens.txt --whisper-language=fr --whisper-task=transcribe \
  --whisper-tail-paddings=300 --num-threads=4 fr-short.wav

K=sherpa-onnx-streaming-zipformer-fr-kroko-2025-08-06
/usr/bin/time -v sherpa-onnx \
  --tokens=$K/tokens.txt --encoder=$K/encoder.onnx \
  --decoder=$K/decoder.onnx --joiner=$K/joiner.onnx \
  --num-threads=4 --decoding-method=greedy_search fr-short.wav

N=sherpa-onnx-nemo-fast-conformer-ctc-en-de-es-fr-14288-int8
/usr/bin/time -v sherpa-onnx-offline \
  --nemo-ctc-model=$N/model.int8.onnx --tokens=$N/tokens.txt \
  --num-threads=4 fr-short.wav
/usr/bin/time -v sherpa-onnx-offline \
  --nemo-ctc-model=$N/model.int8.onnx --tokens=$N/tokens.txt \
  --num-threads=4 en-short.wav
```

Run the French models on `fr-long.wav` too. Then repeat the best two with `--num-threads=2`. The daemon, the LEDs and audio playback share the four cores, and the recognizer will not get all of them.

### Run the synthesizers

One French sentence and one English sentence, the kind a weather service would say. Time the run and listen to the result through the speaker:

```sh
S=vits-piper-fr_FR-siwis-low
/usr/bin/time -v sherpa-onnx-offline-tts --vits-model=$S/fr_FR-siwis-low.onnx \
  --vits-tokens=$S/tokens.txt --vits-data-dir=$S/espeak-ng-data \
  --num-threads=4 --output-filename=fr-low.wav \
  "Il fera douze degrés cet après-midi, avec des averses en fin de journée."

U=vits-piper-fr_FR-upmc-medium
/usr/bin/time -v sherpa-onnx-offline-tts --vits-model=$U/fr_FR-upmc-medium.onnx \
  --vits-tokens=$U/tokens.txt --vits-data-dir=$U/espeak-ng-data \
  --num-threads=4 --output-filename=fr-medium.wav \
  "Il fera douze degrés cet après-midi, avec des averses en fin de journée."

A=vits-piper-en_GB-alan-low
/usr/bin/time -v sherpa-onnx-offline-tts --vits-model=$A/en_GB-alan-low.onnx \
  --vits-tokens=$A/tokens.txt --vits-data-dir=$A/espeak-ng-data \
  --num-threads=4 --output-filename=en-low.wav \
  "It will be twelve degrees this afternoon, with showers later in the day."

aplay -D plughw:CARD=tagtagtagsound fr-low.wav
aplay -D plughw:CARD=tagtagtagsound fr-medium.wav
aplay -D plughw:CARD=tagtagtagsound en-low.wav
```

Real-time factor for synthesis is wall time divided by the length of the produced audio (`soxi -D file.wav`).

### Results

Recognition, one row per model and file. Real-time factor is wall time divided by audio length; below 1.0 means faster than the speech itself.

| Model | File | Threads | Wall (s) | RTF | Peak RSS (MB) | Transcript correct |
|---|---|---|---|---|---|---|
| moonshine tiny en | en-short | 4 | | | | |
| whisper tiny | fr-short | 4 | | | | |
| kroko zipformer fr | fr-short | 4 | | | | |
| kroko zipformer fr | fr-long | 4 | | | | |
| nemo conformer | fr-short | 4 | | | | |
| nemo conformer | en-short | 4 | | | | |
| nemo conformer | fr-long | 4 | | | | |
| best two | fr-short | 2 | | | | |

Synthesis:

| Voice | Wall (s) | Audio (s) | RTF | Peak RSS (MB) | Sounds acceptable |
|---|---|---|---|---|---|
| fr_FR siwis low | | | | | |
| fr_FR upmc medium | | | | | |
| en_GB alan low | | | | | |

Go: at least one recognizer per language has a real-time factor under 1.0 on the short files at two threads, with peak memory under 200 MB, and one French voice synthesizes a sentence in under two seconds and is understandable through the speaker. No-go: nothing meets that. Then local speech on the Zero 2 W drops to a later milestone, the cloud provider carries milestone 2, and the plan's speech section is rewritten.

Update the plan's speech section with the winners before writing any recognizer code.
