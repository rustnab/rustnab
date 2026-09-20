# Hardware Interface Specification

## Overview

This document specifies the hardware interfaces for the Pynab Rust implementation, ensuring compatibility with both Nabaztag (v1) and Nabaztag:tag (v2) hardware across the 2018 and 2019+ card designs.

## Hardware Models

### Model Detection
Hardware model is detected by checking GPIO pin configurations and available devices:

```rust
#[derive(Debug, Clone, PartialEq)]
pub enum HardwareModel {
    NabaztagV1,    // Original Nabaztag (no microphone, no RFID)
    NabaztagV2,    // Nabaztag:tag with microphone and RFID
}

#[derive(Debug, Clone, PartialEq)]
pub enum CardVersion {
    MakerFaire2018,  // Limited functionality
    Ulule2019,       // Full functionality
}
```

## LED Controller Interface

### Hardware Specifications
- **Type**: WS2812B addressable RGB LEDs
- **Count**: 5 LEDs in a circle (indexed 0-4)
- **Protocol**: Single-wire serial (800kHz)
- **Power**: 5V, ~50mA per LED at full brightness
- **GPIO Pin**: Configurable (typically GPIO 18 on Pi)

### Rust Interface
```rust
use rgb::RGB8;
use std::time::Duration;

#[async_trait::async_trait]
pub trait LedController: Send + Sync {
    async fn set_led(&self, index: u8, color: RGB8) -> Result<()>;
    async fn set_all(&self, colors: [RGB8; 5]) -> Result<()>;
    async fn set_brightness(&self, brightness: u8) -> Result<()>;
    async fn pulse(&self, index: u8, color: RGB8, duration: Duration) -> Result<()>;
    async fn clear_all(&self) -> Result<()>;
}

pub struct WS2812BController {
    channel: ws2812_rpi::Channel,
    brightness: u8,
    current_colors: [RGB8; 5],
}

impl WS2812BController {
    pub fn new(pin: u8, brightness: u8) -> Result<Self>;
    
    async fn update_strip(&self, colors: &[RGB8; 5]) -> Result<()> {
        // Convert RGB8 to WS2812B format with brightness adjustment
        let mut led_data = Vec::with_capacity(5);
        
        for color in colors {
            let adjusted_color = RGB8 {
                r: (color.r as u16 * self.brightness as u16 / 255) as u8,
                g: (color.g as u16 * self.brightness as u16 / 255) as u8,
                b: (color.b as u16 * self.brightness as u16 / 255) as u8,
            };
            led_data.push(adjusted_color);
        }
        
        self.channel.write(&led_data)?;
        Ok(())
    }
}
```

### Color Format
Colors are specified as 24-bit RGB values:
- **Format**: RGB8 (red: 0-255, green: 0-255, blue: 0-255)
- **JSON Format**: 6-character hex string ("RRGGBB")
- **Special Colors**: 
  - Black (off): #000000
  - Red: #FF0000
  - Green: #00FF00
  - Blue: #0000FF

### Performance Requirements
- **Update Rate**: Minimum 50Hz for smooth animations
- **Latency**: < 10ms from command to visible change
- **Color Accuracy**: 8-bit per channel precision

## Ear Controller Interface

### Hardware Specifications
- **Type**: Stepper motors (28BYJ-48 or equivalent)
- **Driver**: ULN2003 or similar H-bridge
- **Steps per Revolution**: 2048 steps (64 steps × 32 gear ratio)
- **Position Range**: -17 to +17 (centered at 0)
- **GPIO Pins**: 4 pins per ear (8 total)

### Rust Interface
```rust
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Ear {
    Left,
    Right,
}

#[async_trait::async_trait]
pub trait EarController: Send + Sync {
    async fn move_to(&self, ear: Ear, position: i16) -> Result<()>;
    async fn get_position(&self, ear: Ear) -> Result<i16>;
    async fn calibrate(&self, ear: Ear) -> Result<()>;
    async fn move_both(&self, left_pos: i16, right_pos: i16) -> Result<()>;
    async fn is_moving(&self, ear: Ear) -> Result<bool>;
    async fn stop(&self, ear: Ear) -> Result<()>;
    async fn stop_all(&self) -> Result<()>;
}

pub struct StepperEarController {
    left_motor: StepperMotor,
    right_motor: StepperMotor,
    left_position: Arc<Mutex<i16>>,
    right_position: Arc<Mutex<i16>>,
}

impl StepperEarController {
    pub fn new(
        left_pins: [u8; 4],  // GPIO pins for left ear
        right_pins: [u8; 4], // GPIO pins for right ear
    ) -> Result<Self>;
    
    async fn move_steps(&self, ear: Ear, steps: i32) -> Result<()> {
        let motor = match ear {
            Ear::Left => &self.left_motor,
            Ear::Right => &self.right_motor,
        };
        
        // Execute stepper sequence
        let direction = if steps > 0 { Direction::Clockwise } else { Direction::CounterClockwise };
        motor.step(steps.abs() as u32, direction).await?;
        
        // Update position
        let position_mutex = match ear {
            Ear::Left => &self.left_position,
            Ear::Right => &self.right_position,
        };
        let mut position = position_mutex.lock().await;
        *position = (*position + (steps / STEPS_PER_POSITION)).clamp(-17, 17);
        
        Ok(())
    }
}
```

### Position System
- **Range**: -17 (fully backward) to +17 (fully forward)
- **Center**: 0 (neutral position)
- **Resolution**: ~120 steps per position unit
- **Calibration**: Home position detected by end-stops or current sensing

### Movement Characteristics
- **Speed**: 2-3 seconds for full range movement
- **Acceleration**: Smooth ramp-up/down to prevent skipping
- **Accuracy**: ±1 position unit
- **Holding Torque**: Sufficient to maintain position against gravity

## Audio Controller Interface

### Hardware Specifications
#### Audio Output
- **Interface**: ALSA (Advanced Linux Sound Architecture)
- **Device**: Hardware-dependent (HiFiBerry, WM8960, etc.)
- **Formats**: WAV, MP3 (via software decode)
- **Sample Rates**: 8kHz - 48kHz
- **Channels**: Mono/Stereo

#### Audio Input (Nabaztag:tag only)
- **Interface**: ALSA capture device
- **Microphones**: 2-4 microphones depending on card version
- **Sample Rate**: 16kHz (typical for ASR)
- **Channels**: Mono (processed from multi-mic array)

### Rust Interface
```rust
use rodio::{OutputStream, OutputStreamHandle, Sink, Decoder};
use cpal::{Device, Stream, StreamConfig};

#[derive(Debug, Clone)]
pub struct AudioData {
    pub data: Vec<u8>,
    pub format: AudioFormat,
    pub sample_rate: u32,
    pub channels: u16,
}

#[derive(Debug, Clone)]
pub enum AudioFormat {
    Wav,
    Mp3,
    Raw16Le,
}

#[async_trait::async_trait]
pub trait AudioController: Send + Sync {
    async fn play(&self, audio: AudioData) -> Result<PlaybackHandle>;
    async fn play_file(&self, path: &str) -> Result<PlaybackHandle>;
    async fn record(&self, duration: Duration) -> Result<AudioData>;
    async fn start_recording(&self) -> Result<RecordingHandle>;
    async fn set_volume(&self, volume: u8) -> Result<()>;
    async fn get_volume(&self) -> Result<u8>;
    async fn stop_all_playback(&self) -> Result<()>;
}

pub struct AlsaAudioController {
    output_stream: OutputStream,
    output_handle: OutputStreamHandle,
    input_device: Option<Device>,
    volume: Arc<Mutex<u8>>,
    active_sinks: Arc<Mutex<Vec<Sink>>>,
}

impl AlsaAudioController {
    pub fn new(
        output_device: Option<String>,
        input_device: Option<String>,
    ) -> Result<Self>;
    
    async fn play_internal(&self, audio: AudioData) -> Result<PlaybackHandle> {
        let sink = Sink::try_new(&self.output_handle)?;
        
        // Apply volume control
        let volume = *self.volume.lock().await;
        sink.set_volume(volume as f32 / 100.0);
        
        // Decode and play audio
        let cursor = std::io::Cursor::new(audio.data);
        let source = Decoder::new(cursor)?;
        sink.append(source);
        
        // Track active sink
        let mut active_sinks = self.active_sinks.lock().await;
        active_sinks.push(sink.clone());
        
        Ok(PlaybackHandle::new(sink))
    }
}

pub struct PlaybackHandle {
    sink: Sink,
}

impl PlaybackHandle {
    pub fn stop(&self) {
        self.sink.stop();
    }
    
    pub fn is_finished(&self) -> bool {
        self.sink.is_paused() && self.sink.len() == 0
    }
}
```

### Audio Processing Requirements
- **Latency**: < 100ms for playback commands
- **Quality**: 16-bit, 22kHz minimum for speech
- **Volume Control**: 0-100 linear scale
- **Simultaneous Playback**: Support for multiple audio streams
- **Format Support**: WAV (uncompressed), MP3 (via libmpg123)

## RFID Controller Interface

### Hardware Specifications
Two RFID systems are supported:

#### CR14 (Nabaztag:tag original)
- **Interface**: I2C
- **Frequency**: 13.56 MHz
- **Protocol**: ISO14443A
- **Range**: 2-3 cm
- **Read Speed**: ~100ms per tag

#### ST25R391X (2019+ upgrade)
- **Interface**: SPI
- **Frequency**: 13.56 MHz
- **Protocol**: ISO14443A/B, ISO15693, NFC
- **Range**: 3-5 cm
- **Read Speed**: ~50ms per tag

### Rust Interface
```rust
#[derive(Debug, Clone, PartialEq)]
pub struct RfidTag {
    pub uid: String,      // Hexadecimal UID (e.g., "04:52:de:ad:be:ef:42")
    pub tag_type: RfidTagType,
    pub data: Option<Vec<u8>>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum RfidTagType {
    Mifare1K,
    Mifare4K,
    MifareUltralight,
    ISO15693,
    Unknown(u16),
}

#[async_trait::async_trait]
pub trait RfidController: Send + Sync {
    async fn start_detection(&self) -> Result<()>;
    async fn stop_detection(&self) -> Result<()>;
    async fn read_tag(&self) -> Result<Option<RfidTag>>;
    async fn write_tag(&self, tag: &RfidTag, data: &[u8]) -> Result<()>;
    async fn is_tag_present(&self) -> Result<bool>;
}

pub struct CR14Controller {
    i2c_device: I2cDevice,
    detection_active: Arc<AtomicBool>,
    tag_present: Arc<AtomicBool>,
}

pub struct ST25R391XController {
    spi_device: SpiDevice,
    detection_active: Arc<AtomicBool>,
    tag_present: Arc<AtomicBool>,
}

// Common implementation pattern
impl RfidController for CR14Controller {
    async fn start_detection(&self) -> Result<()> {
        self.detection_active.store(true, Ordering::Relaxed);
        
        // Start polling loop
        let device = self.i2c_device.clone();
        let active = self.detection_active.clone();
        let present = self.tag_present.clone();
        
        tokio::spawn(async move {
            while active.load(Ordering::Relaxed) {
                let tag_detected = device.poll_for_tag().await.unwrap_or(false);
                present.store(tag_detected, Ordering::Relaxed);
                tokio::time::sleep(Duration::from_millis(100)).await;
            }
        });
        
        Ok(())
    }
}
```

### RFID Data Format
Tags store application-specific data in NDEF format:
```rust
#[derive(Debug, Serialize, Deserialize)]
pub struct NabTagData {
    pub app: String,           // Service name (e.g., "nabclockd")
    pub picture: u8,           // Visual picture ID (0-255)
    pub data: serde_json::Value, // Service-specific data
}
```

## Button Controller Interface

### Hardware Specifications
- **Type**: GPIO button with pull-up resistor
- **Active State**: Low (0V when pressed)
- **Debounce**: Software debouncing required
- **GPIO Pin**: Configurable (typically GPIO 17)

### Rust Interface
```rust
#[derive(Debug, Clone, PartialEq)]
pub enum ButtonEvent {
    Down,        // Button pressed
    Up,          // Button released
    Click,       // Short press/release
    DoubleClick, // Two quick clicks
    LongPress,   // Held for >2 seconds
}

#[async_trait::async_trait]
pub trait ButtonController: Send + Sync {
    async fn start_monitoring(&self) -> Result<()>;
    async fn stop_monitoring(&self) -> Result<()>;
    async fn get_state(&self) -> Result<bool>; // true = pressed
}

pub struct GpioButtonController {
    pin: InputPin,
    event_sender: mpsc::UnboundedSender<ButtonEvent>,
    monitoring: Arc<AtomicBool>,
}

impl GpioButtonController {
    pub fn new(pin_number: u8) -> Result<Self>;
    
    async fn monitor_button(&self) -> Result<()> {
        let mut last_state = false;
        let mut press_start: Option<Instant> = None;
        let mut last_click: Option<Instant> = None;
        
        while self.monitoring.load(Ordering::Relaxed) {
            let current_state = self.pin.is_low();
            
            if current_state != last_state {
                if current_state {
                    // Button pressed
                    press_start = Some(Instant::now());
                    let _ = self.event_sender.send(ButtonEvent::Down);
                } else {
                    // Button released
                    let _ = self.event_sender.send(ButtonEvent::Up);
                    
                    if let Some(start) = press_start {
                        let duration = start.elapsed();
                        
                        if duration < Duration::from_millis(50) {
                            // Too short, likely bounce
                            continue;
                        } else if duration < Duration::from_millis(500) {
                            // Click
                            if let Some(last) = last_click {
                                if last.elapsed() < Duration::from_millis(500) {
                                    let _ = self.event_sender.send(ButtonEvent::DoubleClick);
                                    last_click = None;
                                } else {
                                    let _ = self.event_sender.send(ButtonEvent::Click);
                                    last_click = Some(Instant::now());
                                }
                            } else {
                                let _ = self.event_sender.send(ButtonEvent::Click);
                                last_click = Some(Instant::now());
                            }
                        } else {
                            // Long press
                            let _ = self.event_sender.send(ButtonEvent::LongPress);
                            last_click = None;
                        }
                    }
                    press_start = None;
                }
                last_state = current_state;
            }
            
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        
        Ok(())
    }
}
```

### Button Timing
- **Debounce**: 50ms minimum press duration
- **Click**: 50ms - 500ms press duration
- **Long Press**: > 2000ms press duration
- **Double Click**: Two clicks within 500ms

## Hardware Abstraction Layer

### Unified Interface
```rust
pub struct NabIO {
    pub leds: Arc<dyn LedController>,
    pub ears: Arc<dyn EarController>,
    pub audio: Arc<dyn AudioController>,
    pub rfid: Option<Arc<dyn RfidController>>,
    pub button: Arc<dyn ButtonController>,
    pub model: HardwareModel,
    pub card_version: CardVersion,
}

impl NabIO {
    pub async fn new(config: &HardwareConfig) -> Result<Self> {
        let model = detect_hardware_model().await?;
        let card_version = detect_card_version().await?;
        
        let leds = Arc::new(WS2812BController::new(
            config.led_pin, 
            config.led_brightness
        )?);
        
        let ears = Arc::new(StepperEarController::new(
            config.left_ear_pins,
            config.right_ear_pins,
        )?);
        
        let audio = Arc::new(AlsaAudioController::new(
            config.audio_output_device.clone(),
            config.audio_input_device.clone(),
        )?);
        
        let rfid = match model {
            HardwareModel::NabaztagV1 => None,
            HardwareModel::NabaztagV2 => {
                Some(match card_version {
                    CardVersion::MakerFaire2018 => {
                        Arc::new(CR14Controller::new()?) as Arc<dyn RfidController>
                    },
                    CardVersion::Ulule2019 => {
                        Arc::new(ST25R391XController::new()?) as Arc<dyn RfidController>
                    }
                })
            }
        };
        
        let button = Arc::new(GpioButtonController::new(config.button_pin)?);
        
        Ok(NabIO {
            leds, ears, audio, rfid, button, model, card_version
        })
    }
    
    pub async fn initialize(&self) -> Result<()> {
        // Initialize all hardware subsystems
        self.leds.clear_all().await?;
        self.ears.calibrate(Ear::Left).await?;
        self.ears.calibrate(Ear::Right).await?;
        self.button.start_monitoring().await?;
        
        if let Some(rfid) = &self.rfid {
            rfid.start_detection().await?;
        }
        
        Ok(())
    }
    
    pub async fn shutdown(&self) -> Result<()> {
        // Graceful shutdown of all hardware
        self.leds.clear_all().await?;
        self.ears.stop_all().await?;
        self.audio.stop_all_playback().await?;
        self.button.stop_monitoring().await?;
        
        if let Some(rfid) = &self.rfid {
            rfid.stop_detection().await?;
        }
        
        Ok(())
    }
}
```

## Resource Lookup and Media Resolution

- Treat every entry in a command or message sequence as a **relative resource identifier** (for example `"nabd/sounds/boot.wav"`). Reject absolute paths for safety.
- Support **fallback lists** separated by semicolons. Probe each candidate until a file is found.
- Respect **locale-aware lookups** by checking `app/type/<locale>/<filename>` first, then `app/type/<filename>` across all installed applications.
- When a component starts with `*`, perform a **wildcard search** and choose a matching file at random (used for `asr/failed/*.mp3`).
- **Cache and preload** resolved assets before playback to keep latency within the 50 ms goal.

Packaging guidance: reuse the existing application layout so the Rust daemon, services, and tooling share media bundles without conversion.

## Virtual Hardware Backend

Provide a feature-parity development backend that mirrors the Python `NabIOVirtual` implementation:

- Listen on `127.0.0.1:(NABD_PORT_NUMBER + 1)` and broadcast an ANSI-rendered rabbit state to connected clients.
- Simulate button, ear, RFID, and audio events while still emitting the real protocol packets (`button_event`, `ear_event`, `rfid_event`).
- Implement stubbed audio playback/recording that honours sequencing, cancellation, and response semantics.
- Allow deterministic seeds so automated tests can assert LED/ear behaviour.

Maintaining the virtual backend ensures developers can exercise the Rust stack without Raspberry Pi hardware.

## Error Handling

### Hardware-Specific Errors
```rust
#[derive(thiserror::Error, Debug)]
pub enum HardwareError {
    #[error("GPIO error: {0}")]
    Gpio(String),
    
    #[error("I2C communication error: {0}")]
    I2c(String),
    
    #[error("SPI communication error: {0}")]
    Spi(String),
    
    #[error("Audio device error: {0}")]
    Audio(String),
    
    #[error("Hardware not detected: {device}")]
    DeviceNotFound { device: String },
    
    #[error("Hardware initialization failed: {0}")]
    InitializationFailed(String),
    
    #[error("Hardware operation timeout")]
    Timeout,
    
    #[error("Invalid parameter: {parameter} = {value}")]
    InvalidParameter { parameter: String, value: String },
}
```

## Configuration

### Hardware Configuration
```rust
#[derive(Deserialize, Debug)]
pub struct HardwareConfig {
    // LED Configuration
    pub led_pin: u8,
    pub led_brightness: u8,
    pub led_count: u8,
    
    // Ear Configuration  
    pub left_ear_pins: [u8; 4],
    pub right_ear_pins: [u8; 4],
    pub ear_steps_per_position: u32,
    
    // Audio Configuration
    pub audio_output_device: Option<String>,
    pub audio_input_device: Option<String>,
    pub audio_sample_rate: u32,
    pub audio_channels: u16,
    
    // RFID Configuration
    pub rfid_enabled: bool,
    pub rfid_type: Option<String>, // "cr14" or "st25r391x"
    
    // Button Configuration
    pub button_pin: u8,
    pub button_pull_up: bool,
}
```

## Testing and Validation

### Hardware Testing Framework
```rust
#[cfg(test)]
mod tests {
    use super::*;
    
    #[tokio::test]
    async fn test_led_controller() {
        let controller = MockLedController::new();
        
        // Test individual LED control
        controller.set_led(0, RGB8::new(255, 0, 0)).await.unwrap();
        assert_eq!(controller.get_led_state(0), RGB8::new(255, 0, 0));
        
        // Test all LEDs
        let colors = [RGB8::new(255, 0, 0); 5];
        controller.set_all(colors).await.unwrap();
    }
    
    #[tokio::test]
    async fn test_ear_movement() {
        let controller = MockEarController::new();
        
        // Test position movement
        controller.move_to(Ear::Left, 10).await.unwrap();
        assert_eq!(controller.get_position(Ear::Left).await.unwrap(), 10);
        
        // Test range limits
        controller.move_to(Ear::Left, 20).await.unwrap();
        assert_eq!(controller.get_position(Ear::Left).await.unwrap(), 17); // Clamped
    }
}
```

### Performance Benchmarks
- LED update latency: < 10ms
- Ear movement precision: ±1 position
- Audio playback latency: < 100ms
- RFID detection rate: > 90% within range
- Button response time: < 50ms

### Hardware Validation
- GPIO pin functionality tests
- I2C/SPI communication tests
- Audio device detection and playback tests
- Motor calibration and movement tests
- RFID tag read/write validation
