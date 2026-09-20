# Hardware Models Documentation

## Overview

This document provides comprehensive documentation of the different Nabaztag hardware models and card versions supported by Pynab, including their capabilities, limitations, and implementation considerations for the Rust rewrite.

## Hardware Model Hierarchy

### Primary Hardware Models

```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum HardwareModel {
    /// Original Nabaztag (2005) - no microphone, no RFID
    #[serde(rename = "nabaztag_v1")]
    NabaztagV1,
    
    /// Nabaztag:tag (2007) - with microphone and RFID capability
    #[serde(rename = "nabaztag_v2")]
    NabaztagV2,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum CardVersion {
    /// Maker Faire 2018 card - limited functionality
    #[serde(rename = "makerfaire2018")]
    MakerFaire2018,
    
    /// Ulule 2019+ card - full functionality
    #[serde(rename = "ulule2019")]
    Ulule2019,
}

#[derive(Debug, Clone, PartialEq)]
pub struct HardwareCapabilities {
    pub model: HardwareModel,
    pub card_version: CardVersion,
    pub has_ears: bool,
    pub led_count: u8,
    pub has_microphone: bool,
    pub has_speaker: bool,
    pub rfid_capability: RfidCapability,
    pub button_available: bool,
    pub audio_input_channels: u8,
    pub audio_output_channels: u8,
}
```

## Nabaztag V1 (Original, 2005)

### Physical Characteristics
- **Ears**: Yes (2 stepper motor driven ears)
- **LEDs**: 5 RGB LEDs in circular arrangement
- **Audio**: Speaker only (no microphone)
- **RFID**: No built-in capability
- **Button**: Single button on top
- **Size**: ~23cm tall
- **Weight**: ~400g
- **Power**: 5V via AC adapter

### Hardware Capabilities Matrix

| Feature | Nabaztag V1 | Support Level |
|---------|-------------|---------------|
| Ear Movement | ✅ Yes | Full |
| LED Control | ✅ 5 RGB LEDs | Full |
| Audio Output | ✅ Speaker | Full |
| Audio Input | ❌ No microphone | None |
| RFID Reading | ❌ No RFID | None* |
| Button Input | ✅ Single button | Full |
| Speech Recognition | ❌ No microphone | None |
| Voice Synthesis | ✅ Via speaker | Full |

*Note: RFID capability can be added with 2019+ cards

### Technical Specifications

```rust
impl HardwareCapabilities {
    pub fn nabaztag_v1_makerfaire2018() -> Self {
        Self {
            model: HardwareModel::NabaztagV1,
            card_version: CardVersion::MakerFaire2018,
            has_ears: true,
            led_count: 5,
            has_microphone: false,
            has_speaker: true,
            rfid_capability: RfidCapability::None,
            button_available: true,
            audio_input_channels: 0,
            audio_output_channels: 1,
        }
    }
    
    pub fn nabaztag_v1_ulule2019() -> Self {
        Self {
            model: HardwareModel::NabaztagV1,
            card_version: CardVersion::Ulule2019,
            has_ears: true,
            led_count: 5,
            has_microphone: true,  // Added by card
            has_speaker: true,
            rfid_capability: RfidCapability::St25r391x,  // Added by card
            button_available: true,
            audio_input_channels: 2,  // Stereo microphones on card
            audio_output_channels: 1,
        }
    }
}
```

## Nabaztag:tag V2 (2007)

### Physical Characteristics
- **Ears**: Yes (2 stepper motor driven ears)
- **LEDs**: 5 RGB LEDs in circular arrangement
- **Audio**: Speaker + built-in microphone
- **RFID**: Built-in 13.56MHz RFID reader
- **Button**: Single button on top
- **Size**: ~23cm tall
- **Weight**: ~450g
- **Power**: 5V via AC adapter

### Hardware Capabilities Matrix

| Feature | Nabaztag:tag V2 | Support Level |
|---------|-----------------|---------------|
| Ear Movement | ✅ Yes | Full |
| LED Control | ✅ 5 RGB LEDs | Full |
| Audio Output | ✅ Speaker | Full |
| Audio Input | ✅ Built-in mic | Full |
| RFID Reading | ✅ Built-in 13.56MHz | Full |
| Button Input | ✅ Single button | Full |
| Speech Recognition | ✅ Via microphone | Full |
| Voice Synthesis | ✅ Via speaker | Full |

### Technical Specifications

```rust
impl HardwareCapabilities {
    pub fn nabaztag_v2_makerfaire2018() -> Self {
        Self {
            model: HardwareModel::NabaztagV2,
            card_version: CardVersion::MakerFaire2018,
            has_ears: true,
            led_count: 5,
            has_microphone: true,   // Built into rabbit
            has_speaker: true,
            rfid_capability: RfidCapability::Cr14,  // Original RFID
            button_available: true,
            audio_input_channels: 1,  // Mono microphone
            audio_output_channels: 1,
        }
    }
    
    pub fn nabaztag_v2_ulule2019() -> Self {
        Self {
            model: HardwareModel::NabaztagV2,
            card_version: CardVersion::Ulule2019,
            has_ears: true,
            led_count: 5,
            has_microphone: true,   // Enhanced by card
            has_speaker: true,
            rfid_capability: RfidCapability::St25r391x,  // Upgraded RFID
            button_available: true,
            audio_input_channels: 4,  // Multi-microphone array
            audio_output_channels: 1,
        }
    }
}
```

## Card Versions

### Maker Faire 2018 Card

#### Overview
- **Target**: Proof of concept for Maker Faire Paris 2018
- **Compatibility**: Nabaztag V1 and V2
- **Limitations**: Limited functionality compared to 2019+ cards
- **Production**: Small batch, discontinued

#### Technical Specifications
```rust
pub struct MakerFaire2018Card {
    pub audio_codec: AudioCodec::HifiBerry,
    pub led_driver: LedDriver::Gpio,
    pub ear_driver: EarDriver::Gpio,
    pub rfid_support: Option<RfidType::Cr14>,  // V2 only
    pub microphone_support: bool,  // V2 only
    pub gpio_pins: GpioPinout::MakerFaire2018,
}
```

#### GPIO Pinout (Maker Faire 2018)
| Function | GPIO Pin | Notes |
|----------|----------|-------|
| LED Data | 18 | WS2812B data line |
| Button | 17 | Active low, pull-up |
| Left Ear Step | 22, 23, 24, 25 | Stepper sequence |
| Right Ear Step | 5, 6, 13, 19 | Stepper sequence |
| I2S Audio | 2, 3 | I2S interface |
| RFID (V2) | 2, 3 | I2C interface |

#### Limitations
- No microphone enhancement for V1
- Limited RFID capability (CR14 only)
- Basic audio processing
- No advanced features

### Ulule 2019+ Card

#### Overview
- **Target**: Full production release via Ulule crowdfunding
- **Compatibility**: Nabaztag V1 and V2 with enhanced capabilities
- **Features**: Full functionality including microphone arrays
- **Production**: Mass production, current standard

#### Technical Specifications
```rust
pub struct Ulule2019Card {
    pub audio_codec: AudioCodec::Wm8960,
    pub led_driver: LedDriver::Spi,
    pub ear_driver: EarDriver::StepperController,
    pub rfid_support: RfidType::St25r391x,
    pub microphone_array: MicrophoneArray::Quad,
    pub gpio_pins: GpioPinout::Ulule2019,
    pub enhanced_features: Vec<EnhancedFeature>,
}
```

#### GPIO Pinout (Ulule 2019+)
| Function | GPIO Pin | Notes |
|----------|----------|-------|
| LED SPI | 10, 11, 21 | SPI interface |
| Button | 16 | Active low, pull-up |
| Left Ear | 22, 23, 24, 25 | Enhanced driver |
| Right Ear | 5, 6, 13, 19 | Enhanced driver |
| Audio I2S | 18, 19, 20, 21 | WM8960 codec |
| RFID SPI | 7, 8, 9, 25 | ST25R391X NFC |
| Mic Array | Multiple | 4-channel array |

#### Enhanced Features
- **Microphone Array**: 4-channel beamforming
- **Advanced RFID**: NFC support with ST25R391X
- **Better Audio**: WM8960 codec with enhanced processing
- **Improved LEDs**: SPI-driven with better color accuracy
- **Motor Control**: Enhanced stepper drivers

## RFID Capabilities

### RFID Technology Comparison

```rust
#[derive(Debug, Clone, PartialEq)]
pub enum RfidCapability {
    None,
    /// Original CR14 I2C RFID reader (Nabaztag:tag original)
    Cr14,
    /// Upgraded ST25R391X NFC reader (2019+ cards)
    St25r391x,
}

impl RfidCapability {
    pub fn supported_protocols(&self) -> Vec<RfidProtocol> {
        match self {
            RfidCapability::None => vec![],
            RfidCapability::Cr14 => vec![
                RfidProtocol::Iso14443a,
            ],
            RfidCapability::St25r391x => vec![
                RfidProtocol::Iso14443a,
                RfidProtocol::Iso14443b,
                RfidProtocol::Iso15693,
                RfidProtocol::Nfc,
            ],
        }
    }
    
    pub fn max_read_distance_cm(&self) -> u8 {
        match self {
            RfidCapability::None => 0,
            RfidCapability::Cr14 => 3,
            RfidCapability::St25r391x => 5,
        }
    }
    
    pub fn read_speed_ms(&self) -> u16 {
        match self {
            RfidCapability::None => 0,
            RfidCapability::Cr14 => 100,
            RfidCapability::St25r391x => 50,
        }
    }
}
```

### CR14 RFID Reader (Maker Faire 2018, Nabaztag:tag)
- **Interface**: I2C
- **Frequency**: 13.56 MHz
- **Protocol**: ISO14443A only
- **Range**: 2-3 cm
- **Speed**: ~100ms per read
- **Tags Supported**: Mifare Classic, Mifare Ultralight

### ST25R391X NFC Reader (Ulule 2019+)
- **Interface**: SPI
- **Frequency**: 13.56 MHz
- **Protocols**: ISO14443A/B, ISO15693, NFC Forum
- **Range**: 3-5 cm
- **Speed**: ~50ms per read
- **Tags Supported**: All major NFC/RFID tag types

## Audio Capabilities

### Audio Codec Comparison

```rust
#[derive(Debug, Clone, PartialEq)]
pub enum AudioCodec {
    /// HiFiBerry DAC (Maker Faire 2018)
    HifiBerry,
    /// WM8960 Codec (Ulule 2019+)
    Wm8960,
}

impl AudioCodec {
    pub fn sample_rates(&self) -> Vec<u32> {
        match self {
            AudioCodec::HifiBerry => vec![44100, 48000],
            AudioCodec::Wm8960 => vec![8000, 16000, 22050, 44100, 48000],
        }
    }
    
    pub fn input_channels(&self, model: HardwareModel) -> u8 {
        match (self, model) {
            (AudioCodec::HifiBerry, HardwareModel::NabaztagV1) => 0,
            (AudioCodec::HifiBerry, HardwareModel::NabaztagV2) => 1,
            (AudioCodec::Wm8960, HardwareModel::NabaztagV1) => 2,
            (AudioCodec::Wm8960, HardwareModel::NabaztagV2) => 4,
        }
    }
    
    pub fn has_hardware_volume_control(&self) -> bool {
        match self {
            AudioCodec::HifiBerry => false,
            AudioCodec::Wm8960 => true,
        }
    }
}
```

### Microphone Arrays

#### Single Microphone (Built-in, Nabaztag:tag)
- **Channels**: 1 (mono)
- **Quality**: Basic voice capture
- **Noise Cancellation**: None
- **Beamforming**: No

#### Dual Microphone (2019+ Card, Nabaztag V1)
- **Channels**: 2 (stereo)
- **Quality**: Enhanced voice capture
- **Noise Cancellation**: Basic
- **Beamforming**: Simple

#### Quad Microphone Array (2019+ Card, Nabaztag:tag)
- **Channels**: 4 (array)
- **Quality**: Professional voice capture
- **Noise Cancellation**: Advanced
- **Beamforming**: Full directional

## Hardware Detection

### Automatic Hardware Detection

```rust
pub struct HardwareDetector;

impl HardwareDetector {
    pub async fn detect() -> Result<HardwareCapabilities, DetectionError> {
        let model = Self::detect_model().await?;
        let card_version = Self::detect_card_version().await?;
        
        match (model, card_version) {
            (HardwareModel::NabaztagV1, CardVersion::MakerFaire2018) => {
                Ok(HardwareCapabilities::nabaztag_v1_makerfaire2018())
            },
            (HardwareModel::NabaztagV1, CardVersion::Ulule2019) => {
                Ok(HardwareCapabilities::nabaztag_v1_ulule2019())
            },
            (HardwareModel::NabaztagV2, CardVersion::MakerFaire2018) => {
                Ok(HardwareCapabilities::nabaztag_v2_makerfaire2018())
            },
            (HardwareModel::NabaztagV2, CardVersion::Ulule2019) => {
                Ok(HardwareCapabilities::nabaztag_v2_ulule2019())
            },
        }
    }
    
    async fn detect_model() -> Result<HardwareModel, DetectionError> {
        // Check for microphone availability in the original hardware
        if Self::has_builtin_microphone().await? {
            Ok(HardwareModel::NabaztagV2)
        } else {
            Ok(HardwareModel::NabaztagV1)
        }
    }
    
    async fn detect_card_version() -> Result<CardVersion, DetectionError> {
        // Check for WM8960 codec presence (Ulule 2019+)
        if Self::has_wm8960_codec().await? {
            Ok(CardVersion::Ulule2019)
        } else {
            Ok(CardVersion::MakerFaire2018)
        }
    }
    
    async fn has_builtin_microphone() -> Result<bool, DetectionError> {
        // Detect original microphone by checking ALSA devices
        let alsa_devices = Self::get_alsa_input_devices().await?;
        Ok(alsa_devices.iter().any(|d| d.contains("nabaztag") || d.contains("built-in")))
    }
    
    async fn has_wm8960_codec() -> Result<bool, DetectionError> {
        // Detect WM8960 by checking I2C devices
        let i2c_devices = Self::scan_i2c_devices().await?;
        Ok(i2c_devices.contains(&0x1a)) // WM8960 I2C address
    }
}
```

## Feature Compatibility Matrix

### Complete Feature Matrix

| Feature | V1+2018 | V1+2019 | V2+2018 | V2+2019 | Notes |
|---------|---------|---------|---------|---------|-------|
| **Core Features** |
| Ear Movement | ✅ | ✅ | ✅ | ✅ | All models |
| LED Control | ✅ | ✅ | ✅ | ✅ | 5 RGB LEDs |
| Button Input | ✅ | ✅ | ✅ | ✅ | Single button |
| Audio Output | ✅ | ✅ | ✅ | ✅ | Speaker |
| **Audio Input** |
| Microphone | ❌ | ✅* | ✅ | ✅+ | *Added by card, +Enhanced |
| Voice Recognition | ❌ | ✅ | ✅ | ✅+ | +Better quality |
| Noise Cancellation | ❌ | ✅ | ❌ | ✅+ | +Advanced array |
| **RFID Capabilities** |
| RFID Reading | ❌ | ✅ | ✅ | ✅+ | +NFC support |
| NFC Support | ❌ | ✅ | ❌ | ✅ | 2019+ only |
| Tag Writing | ❌ | ✅ | ⚠️ | ✅ | ⚠️Limited |
| **Advanced Features** |
| Beamforming | ❌ | ⚠️ | ❌ | ✅ | ⚠️Basic |
| Echo Cancellation | ❌ | ⚠️ | ❌ | ✅ | ⚠️Limited |
| Multi-language ASR | ❌ | ✅ | ✅ | ✅ | Depends on processing |

Legend:
- ✅ Full support
- ⚠️ Limited support
- ❌ Not supported
- * Feature added by card
- + Enhanced version

## Implementation Considerations

### Hardware-Specific Code Patterns

```rust
impl NabIO {
    pub async fn initialize_for_hardware(
        capabilities: &HardwareCapabilities,
    ) -> Result<Self, HardwareError> {
        let leds = match capabilities.card_version {
            CardVersion::MakerFaire2018 => {
                Arc::new(GpioLedController::new(18)?) as Arc<dyn LedController>
            },
            CardVersion::Ulule2019 => {
                Arc::new(SpiLedController::new()?) as Arc<dyn LedController>
            },
        };
        
        let audio = match capabilities.card_version {
            CardVersion::MakerFaire2018 => {
                Arc::new(HifiBerryAudioController::new()?) as Arc<dyn AudioController>
            },
            CardVersion::Ulule2019 => {
                Arc::new(Wm8960AudioController::new()?) as Arc<dyn AudioController>
            },
        };
        
        let rfid = match capabilities.rfid_capability {
            RfidCapability::None => None,
            RfidCapability::Cr14 => {
                Some(Arc::new(Cr14Controller::new()?) as Arc<dyn RfidController>)
            },
            RfidCapability::St25r391x => {
                Some(Arc::new(St25r391xController::new()?) as Arc<dyn RfidController>)
            },
        };
        
        Ok(NabIO {
            leds,
            ears: Arc::new(StepperEarController::new(
                capabilities.get_left_ear_pins(),
                capabilities.get_right_ear_pins(),
            )?),
            audio,
            rfid,
            button: Arc::new(GpioButtonController::new(
                capabilities.get_button_pin(),
            )?),
            capabilities: capabilities.clone(),
        })
    }
}
```

### Performance Optimizations by Hardware

```rust
impl HardwareCapabilities {
    pub fn get_optimal_audio_settings(&self) -> AudioSettings {
        match self.card_version {
            CardVersion::MakerFaire2018 => AudioSettings {
                sample_rate: 22050,
                buffer_size: 1024,
                channels: if self.has_microphone { 1 } else { 0 },
            },
            CardVersion::Ulule2019 => AudioSettings {
                sample_rate: 16000,
                buffer_size: 512,
                channels: self.audio_input_channels,
            },
        }
    }
    
    pub fn supports_feature(&self, feature: Feature) -> bool {
        match feature {
            Feature::VoiceRecognition => self.has_microphone,
            Feature::NfcReading => matches!(self.rfid_capability, RfidCapability::St25r391x),
            Feature::Beamforming => {
                self.card_version == CardVersion::Ulule2019 && 
                self.model == HardwareModel::NabaztagV2
            },
            Feature::HardwareVolumeControl => {
                self.card_version == CardVersion::Ulule2019
            },
        }
    }
}
```

### Configuration Templates

```rust
pub struct HardwareConfig {
    pub model: HardwareModel,
    pub card_version: CardVersion,
    pub pin_configuration: PinConfiguration,
    pub audio_configuration: AudioConfiguration,
    pub performance_settings: PerformanceSettings,
}

impl HardwareConfig {
    pub fn from_capabilities(caps: &HardwareCapabilities) -> Self {
        match (caps.model, caps.card_version) {
            (HardwareModel::NabaztagV1, CardVersion::MakerFaire2018) => {
                Self::nabaztag_v1_makerfaire2018_config()
            },
            (HardwareModel::NabaztagV1, CardVersion::Ulule2019) => {
                Self::nabaztag_v1_ulule2019_config()
            },
            (HardwareModel::NabaztagV2, CardVersion::MakerFaire2018) => {
                Self::nabaztag_v2_makerfaire2018_config()
            },
            (HardwareModel::NabaztagV2, CardVersion::Ulule2019) => {
                Self::nabaztag_v2_ulule2019_config()
            },
        }
    }
}
```

## Testing and Validation

### Hardware-Specific Testing

```rust
#[cfg(test)]
mod tests {
    use super::*;
    
    #[tokio::test]
    async fn test_hardware_detection() {
        let caps = HardwareDetector::detect().await.unwrap();
        
        // Validate detected capabilities
        assert!(caps.led_count == 5);
        assert!(caps.has_ears);
        assert!(caps.button_available);
        
        // Model-specific validations
        match caps.model {
            HardwareModel::NabaztagV1 => {
                if caps.card_version == CardVersion::MakerFaire2018 {
                    assert!(!caps.has_microphone);
                    assert_eq!(caps.rfid_capability, RfidCapability::None);
                }
            },
            HardwareModel::NabaztagV2 => {
                assert!(caps.has_microphone);
                assert_ne!(caps.rfid_capability, RfidCapability::None);
            },
        }
    }
    
    #[tokio::test]
    async fn test_feature_compatibility() {
        let caps_v1_2018 = HardwareCapabilities::nabaztag_v1_makerfaire2018();
        let caps_v2_2019 = HardwareCapabilities::nabaztag_v2_ulule2019();
        
        // V1 2018 should not support voice recognition
        assert!(!caps_v1_2018.supports_feature(Feature::VoiceRecognition));
        
        // V2 2019 should support all features
        assert!(caps_v2_2019.supports_feature(Feature::VoiceRecognition));
        assert!(caps_v2_2019.supports_feature(Feature::NfcReading));
        assert!(caps_v2_2019.supports_feature(Feature::Beamforming));
    }
}
```

This comprehensive hardware model documentation provides all the necessary information for implementing hardware-specific functionality in the Rust rewrite while maintaining compatibility across all supported Nabaztag variants and card versions.