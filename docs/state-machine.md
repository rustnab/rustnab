# State Machine Specification

## Overview

This document defines the state machine that governs the Nabaztag's behavior, including states, transitions, event handling, and the interaction between hardware and services.

## Core State Machine

### Primary States

```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum NabState {
    /// Normal operation state - responsive to all interactions
    Idle,
    /// Sleep state - limited responsiveness, low power mode
    Asleep,
    /// Active interaction state - engaged with user
    Interactive,
}

impl NabState {
    pub fn is_responsive(&self) -> bool {
        match self {
            NabState::Idle | NabState::Interactive => true,
            NabState::Asleep => false,
        }
    }
    
    pub fn allows_hardware_control(&self) -> bool {
        match self {
            NabState::Idle | NabState::Interactive => true,
            NabState::Asleep => false, // Limited hardware access
        }
    }
    
    pub fn allows_choreography(&self) -> bool {
        match self {
            NabState::Idle | NabState::Interactive => true,
            NabState::Asleep => false,
        }
    }
}
```

### State Transitions

```rust
#[derive(Debug, Clone, PartialEq)]
pub struct StateTransition {
    pub from: NabState,
    pub to: NabState,
    pub trigger: TransitionTrigger,
    pub conditions: Vec<TransitionCondition>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum TransitionTrigger {
    /// User interaction detected (button, RFID, ASR)
    UserInteraction,
    /// Sleep command from service
    SleepCommand,
    /// Wakeup command from service
    WakeupCommand,
    /// Inactivity timeout
    InactivityTimeout,
    /// Interaction session complete
    InteractionComplete,
    /// System startup
    SystemStartup,
    /// Emergency/error condition
    Emergency,
}

#[derive(Debug, Clone, PartialEq)]
pub enum TransitionCondition {
    /// Hardware is not busy with operations
    HardwareIdle,
    /// No active choreographies
    NoActiveChoreography,
    /// Audio playback finished
    AudioIdle,
    /// Time-based condition (e.g., sleep schedule)
    TimeCondition(TimeCondition),
    /// Service permission required
    ServicePermission(String),
}

#[derive(Debug, Clone, PartialEq)]
pub struct TimeCondition {
    pub start_time: Option<chrono::NaiveTime>,
    pub end_time: Option<chrono::NaiveTime>,
    pub weekdays: Option<Vec<chrono::Weekday>>,
}
```

### Valid State Transitions

```rust
impl NabStateMachine {
    fn get_valid_transitions() -> Vec<StateTransition> {
        vec![
            // Startup transitions
            StateTransition {
                from: NabState::Asleep, // Initial state
                to: NabState::Idle,
                trigger: TransitionTrigger::SystemStartup,
                conditions: vec![TransitionCondition::HardwareIdle],
            },
            
            // Sleep transitions
            StateTransition {
                from: NabState::Idle,
                to: NabState::Asleep,
                trigger: TransitionTrigger::SleepCommand,
                conditions: vec![
                    TransitionCondition::NoActiveChoreography,
                    TransitionCondition::AudioIdle,
                ],
            },
            
            StateTransition {
                from: NabState::Interactive,
                to: NabState::Asleep,
                trigger: TransitionTrigger::SleepCommand,
                conditions: vec![
                    TransitionCondition::NoActiveChoreography,
                    TransitionCondition::AudioIdle,
                ],
            },
            
            // Wakeup transitions
            StateTransition {
                from: NabState::Asleep,
                to: NabState::Idle,
                trigger: TransitionTrigger::WakeupCommand,
                conditions: vec![],
            },
            
            StateTransition {
                from: NabState::Asleep,
                to: NabState::Interactive,
                trigger: TransitionTrigger::UserInteraction,
                conditions: vec![],
            },
            
            // Interactive transitions
            StateTransition {
                from: NabState::Idle,
                to: NabState::Interactive,
                trigger: TransitionTrigger::UserInteraction,
                conditions: vec![],
            },
            
            StateTransition {
                from: NabState::Interactive,
                to: NabState::Idle,
                trigger: TransitionTrigger::InteractionComplete,
                conditions: vec![],
            },
            
            StateTransition {
                from: NabState::Interactive,
                to: NabState::Idle,
                trigger: TransitionTrigger::InactivityTimeout,
                conditions: vec![],
            },
        ]
    }
}
```

## State Machine Implementation

### Core State Machine Structure

```rust
use tokio::sync::{RwLock, mpsc};
use std::sync::Arc;
use std::time::{Duration, Instant};

pub struct NabStateMachine {
    current_state: Arc<RwLock<NabState>>,
    previous_state: Arc<RwLock<Option<NabState>>>,
    hardware: Arc<NabIO>,
    event_sender: mpsc::UnboundedSender<StateEvent>,
    transition_conditions: Arc<RwLock<HashMap<NabState, Vec<TransitionCondition>>>>,
    inactivity_timer: Arc<RwLock<Option<Instant>>>,
    interaction_timeout: Duration,
    services: Arc<RwLock<HashMap<String, ServiceState>>>,
}

impl NabStateMachine {
    pub fn new(
        hardware: Arc<NabIO>,
        event_sender: mpsc::UnboundedSender<StateEvent>,
    ) -> Self {
        Self {
            current_state: Arc::new(RwLock::new(NabState::Asleep)),
            previous_state: Arc::new(RwLock::new(None)),
            hardware,
            event_sender,
            transition_conditions: Arc::new(RwLock::new(HashMap::new())),
            inactivity_timer: Arc::new(RwLock::new(None)),
            interaction_timeout: Duration::from_secs(30), // 30 second timeout
            services: Arc::new(RwLock::new(HashMap::new())),
        }
    }
    
    pub async fn get_current_state(&self) -> NabState {
        *self.current_state.read().await
    }
    
    pub async fn request_transition(
        &self,
        target_state: NabState,
        trigger: TransitionTrigger,
    ) -> Result<bool, StateMachineError> {
        let current = *self.current_state.read().await;
        
        if current == target_state {
            return Ok(false); // No transition needed
        }
        
        // Check if transition is valid
        if !self.is_transition_valid(current, target_state, &trigger).await? {
            return Err(StateMachineError::InvalidTransition {
                from: current,
                to: target_state,
                trigger,
            });
        }
        
        // Check transition conditions
        if !self.check_transition_conditions(current, target_state).await? {
            return Err(StateMachineError::ConditionsNotMet {
                from: current,
                to: target_state,
            });
        }
        
        // Perform state transition
        self.perform_transition(current, target_state, trigger).await?;
        
        Ok(true)
    }
    
    async fn perform_transition(
        &self,
        from: NabState,
        to: NabState,
        trigger: TransitionTrigger,
    ) -> Result<(), StateMachineError> {
        // Pre-transition actions
        self.execute_pre_transition_actions(from, to).await?;
        
        // Update state
        {
            let mut current = self.current_state.write().await;
            let mut previous = self.previous_state.write().await;
            *previous = Some(*current);
            *current = to;
        }
        
        // Post-transition actions
        self.execute_post_transition_actions(from, to).await?;
        
        // Update timers
        self.update_timers(to).await;
        
        // Broadcast state change event
        let event = StateEvent::StateChanged {
            new_state: to,
            previous_state: from,
            trigger,
        };
        
        let _ = self.event_sender.send(event);
        
        Ok(())
    }
    
    async fn execute_pre_transition_actions(
        &self,
        from: NabState,
        to: NabState,
    ) -> Result<(), StateMachineError> {
        match (from, to) {
            // Entering sleep mode
            (_, NabState::Asleep) => {
                // Dim LEDs
                self.hardware.leds.set_brightness(10).await?; // 10% brightness
                
                // Move ears to neutral position
                self.hardware.ears.move_both(0, 0).await?;
                
                // Lower audio volume
                self.hardware.audio.set_volume(30).await?; // 30% volume
            },
            
            // Leaving sleep mode
            (NabState::Asleep, _) => {
                // Restore LED brightness
                self.hardware.leds.set_brightness(100).await?; // Full brightness
                
                // Restore audio volume
                self.hardware.audio.set_volume(80).await?; // 80% volume
            },
            
            // Entering interactive mode
            (_, NabState::Interactive) => {
                // Optional: Play interaction start sound
                // Optional: LED welcome animation
            },
            
            _ => {
                // No specific pre-transition actions
            }
        }
        
        Ok(())
    }
    
    async fn execute_post_transition_actions(
        &self,
        from: NabState,
        to: NabState,
    ) -> Result<(), StateMachineError> {
        match to {
            NabState::Idle => {
                // Return to idle behavior
                self.hardware.leds.clear_all().await?;
                self.hardware.ears.move_both(0, 0).await?;
            },
            
            NabState::Asleep => {
                // Sleep animations/sounds if desired
                self.hardware.leds.clear_all().await?;
            },
            
            NabState::Interactive => {
                // Interactive mode setup - ready for user interaction
            },
        }
        
        Ok(())
    }
    
    async fn update_timers(&self, new_state: NabState) {
        let mut timer = self.inactivity_timer.write().await;
        
        match new_state {
            NabState::Interactive => {
                *timer = Some(Instant::now());
            },
            _ => {
                *timer = None;
            }
        }
    }
    
    pub async fn handle_user_interaction(&self) -> Result<(), StateMachineError> {
        let current = *self.current_state.read().await;
        
        match current {
            NabState::Asleep => {
                // Wake up from sleep
                self.request_transition(
                    NabState::Interactive,
                    TransitionTrigger::UserInteraction,
                ).await?;
            },
            NabState::Idle => {
                // Enter interactive mode
                self.request_transition(
                    NabState::Interactive,
                    TransitionTrigger::UserInteraction,
                ).await?;
            },
            NabState::Interactive => {
                // Reset inactivity timer
                let mut timer = self.inactivity_timer.write().await;
                *timer = Some(Instant::now());
            },
        }
        
        Ok(())
    }
    
    pub async fn check_inactivity_timeout(&self) -> Result<(), StateMachineError> {
        let current = *self.current_state.read().await;
        
        if current == NabState::Interactive {
            let timer = self.inactivity_timer.read().await;
            
            if let Some(start_time) = *timer {
                if start_time.elapsed() >= self.interaction_timeout {
                    self.request_transition(
                        NabState::Idle,
                        TransitionTrigger::InactivityTimeout,
                    ).await?;
                }
            }
        }
        
        Ok(())
    }
}
```

### Event System

```rust
#[derive(Debug, Clone, PartialEq)]
pub enum StateEvent {
    StateChanged {
        new_state: NabState,
        previous_state: NabState,
        trigger: TransitionTrigger,
    },
    TransitionRequested {
        target_state: NabState,
        trigger: TransitionTrigger,
    },
    TransitionDenied {
        target_state: NabState,
        reason: String,
    },
    HardwareEvent {
        event_type: HardwareEventType,
    },
    ServiceEvent {
        service: String,
        event_type: ServiceEventType,
    },
}

#[derive(Debug, Clone, PartialEq)]
pub enum HardwareEventType {
    ButtonPressed,
    ButtonReleased,
    ButtonClick,
    ButtonDoubleClick,
    ButtonLongPress,
    RfidTagDetected { uid: String },
    RfidTagRemoved,
    EarMovementComplete { ear: String, position: i16 },
    AudioPlaybackFinished,
    AudioRecordingComplete,
    AsrResult { text: String, confidence: f64 },
}

#[derive(Debug, Clone, PartialEq)]
pub enum ServiceEventType {
    ServiceRegistered,
    ServiceDisconnected,
    ChoreographyRequested,
    ChoreographyFinished,
}
```

### Hardware Event Processing

```rust
impl NabStateMachine {
    pub async fn process_hardware_event(
        &self,
        event: HardwareEventType,
    ) -> Result<(), StateMachineError> {
        let current_state = *self.current_state.read().await;
        
        match event {
            HardwareEventType::ButtonClick |
            HardwareEventType::ButtonDoubleClick |
            HardwareEventType::ButtonLongPress |
            HardwareEventType::RfidTagDetected { .. } => {
                self.handle_user_interaction().await?;
            },
            
            HardwareEventType::AsrResult { text, confidence } => {
                if confidence > 0.7 { // Confidence threshold
                    self.handle_user_interaction().await?;
                    
                    // Process ASR command
                    self.process_voice_command(&text).await?;
                }
            },
            
            HardwareEventType::AudioPlaybackFinished => {
                // Check if this affects state transitions
                self.check_hardware_idle_conditions().await?;
            },
            
            _ => {
                // Other hardware events don't directly affect state
            }
        }
        
        // Broadcast hardware event
        let state_event = StateEvent::HardwareEvent { event_type: event };
        let _ = self.event_sender.send(state_event);
        
        Ok(())
    }
    
    async fn process_voice_command(&self, text: &str) -> Result<(), StateMachineError> {
        // Simple voice command processing
        let text_lower = text.to_lowercase();
        
        if text_lower.contains("sleep") || text_lower.contains("go to bed") {
            self.request_transition(
                NabState::Asleep,
                TransitionTrigger::SleepCommand,
            ).await?;
        } else if text_lower.contains("wake up") || text_lower.contains("hello") {
            if *self.current_state.read().await == NabState::Asleep {
                self.request_transition(
                    NabState::Interactive,
                    TransitionTrigger::WakeupCommand,
                ).await?;
            }
        }
        
        Ok(())
    }
}
```

## Service Integration

### Service State Management

```rust
#[derive(Debug, Clone, PartialEq)]
pub struct ServiceState {
    pub name: String,
    pub active: bool,
    pub requires_interactive: bool,
    pub blocks_sleep: bool,
    pub last_activity: Option<Instant>,
}

impl NabStateMachine {
    pub async fn register_service(&self, service: ServiceState) {
        let mut services = self.services.write().await;
        services.insert(service.name.clone(), service);
    }
    
    pub async fn unregister_service(&self, service_name: &str) {
        let mut services = self.services.write().await;
        services.remove(service_name);
    }
    
    pub async fn can_transition_to_sleep(&self) -> bool {
        let services = self.services.read().await;
        
        // Check if any services block sleep
        !services.values().any(|service| service.active && service.blocks_sleep)
    }
    
    pub async fn get_active_interactive_services(&self) -> Vec<String> {
        let services = self.services.read().await;
        
        services.values()
            .filter(|service| service.active && service.requires_interactive)
            .map(|service| service.name.clone())
            .collect()
    }
}
```

### Choreography State Integration

```rust
pub struct ChoreographyState {
    pub active_choreographies: HashMap<String, ChoreographyExecution>,
    pub hardware_locked: bool,
    pub priority_choreography: Option<String>,
}

impl NabStateMachine {
    pub async fn can_execute_choreography(&self) -> bool {
        let current_state = *self.current_state.read().await;
        current_state.allows_choreography()
    }
    
    pub async fn request_choreography_execution(
        &self,
        choreography_id: String,
        priority: ChoreographyPriority,
    ) -> Result<bool, StateMachineError> {
        if !self.can_execute_choreography().await {
            return Err(StateMachineError::ChoreographyNotAllowed);
        }
        
        // Check if we need to transition to interactive mode for high-priority choreographies
        if priority == ChoreographyPriority::High {
            let current = *self.current_state.read().await;
            if current == NabState::Idle {
                self.request_transition(
                    NabState::Interactive,
                    TransitionTrigger::UserInteraction,
                ).await?;
            }
        }
        
        Ok(true)
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum ChoreographyPriority {
    Low,     // Background animations
    Normal,  // Regular choreographies
    High,    // User-triggered choreographies
    System,  // System-level animations (startup, sleep, etc.)
}
```

## Sleep/Wake Scheduling

### Time-Based Sleep Management

```rust
use chrono::{DateTime, Local, NaiveTime, Timelike};

pub struct SleepSchedule {
    pub sleep_time: Option<NaiveTime>,
    pub wake_time: Option<NaiveTime>,
    pub enabled: bool,
    pub weekdays_only: bool,
}

impl NabStateMachine {
    pub fn set_sleep_schedule(&mut self, schedule: SleepSchedule) {
        self.sleep_schedule = Some(schedule);
    }
    
    pub async fn check_sleep_schedule(&self) -> Result<(), StateMachineError> {
        if let Some(schedule) = &self.sleep_schedule {
            if !schedule.enabled {
                return Ok(());
            }
            
            let now = Local::now();
            let current_time = now.time();
            let current_state = *self.current_state.read().await;
            
            // Check if it's time to sleep
            if let Some(sleep_time) = schedule.sleep_time {
                if self.should_auto_sleep(&current_time, &sleep_time, &now, schedule)? 
                   && current_state != NabState::Asleep {
                    self.request_transition(
                        NabState::Asleep,
                        TransitionTrigger::InactivityTimeout,
                    ).await?;
                }
            }
            
            // Check if it's time to wake up
            if let Some(wake_time) = schedule.wake_time {
                if self.should_auto_wake(&current_time, &wake_time, &now, schedule)?
                   && current_state == NabState::Asleep {
                    self.request_transition(
                        NabState::Idle,
                        TransitionTrigger::WakeupCommand,
                    ).await?;
                }
            }
        }
        
        Ok(())
    }
    
    fn should_auto_sleep(
        &self,
        current_time: &NaiveTime,
        sleep_time: &NaiveTime,
        now: &DateTime<Local>,
        schedule: &SleepSchedule,
    ) -> Result<bool, StateMachineError> {
        // Check weekday restriction
        if schedule.weekdays_only && (now.weekday().number_from_monday() > 5) {
            return Ok(false);
        }
        
        // Check if current time is within sleep time window (5 minutes)
        let sleep_window_start = *sleep_time - chrono::Duration::minutes(2);
        let sleep_window_end = *sleep_time + chrono::Duration::minutes(3);
        
        Ok(current_time >= &sleep_window_start && current_time <= &sleep_window_end)
    }
}
```

## Error Handling

### State Machine Errors

```rust
#[derive(thiserror::Error, Debug)]
pub enum StateMachineError {
    #[error("Invalid state transition from {from:?} to {to:?} with trigger {trigger:?}")]
    InvalidTransition {
        from: NabState,
        to: NabState,
        trigger: TransitionTrigger,
    },
    
    #[error("Transition conditions not met from {from:?} to {to:?}")]
    ConditionsNotMet {
        from: NabState,
        to: NabState,
    },
    
    #[error("Hardware error during state transition: {0}")]
    HardwareError(#[from] HardwareError),
    
    #[error("Choreography execution not allowed in current state")]
    ChoreographyNotAllowed,
    
    #[error("Service blocking state transition: {service}")]
    ServiceBlocking { service: String },
    
    #[error("Emergency state transition required")]
    Emergency,
}
```

## Testing and Validation

### State Machine Testing

```rust
#[cfg(test)]
mod tests {
    use super::*;
    
    #[tokio::test]
    async fn test_basic_state_transitions() {
        let (tx, _rx) = mpsc::unbounded_channel();
        let hardware = Arc::new(MockNabIO::new());
        let mut state_machine = NabStateMachine::new(hardware, tx);
        
        // Test initial state
        assert_eq!(state_machine.get_current_state().await, NabState::Asleep);
        
        // Test wake up
        let result = state_machine.request_transition(
            NabState::Idle,
            TransitionTrigger::SystemStartup,
        ).await;
        assert!(result.is_ok());
        assert_eq!(state_machine.get_current_state().await, NabState::Idle);
        
        // Test user interaction
        state_machine.handle_user_interaction().await.unwrap();
        assert_eq!(state_machine.get_current_state().await, NabState::Interactive);
    }
    
    #[tokio::test]
    async fn test_invalid_transitions() {
        let (tx, _rx) = mpsc::unbounded_channel();
        let hardware = Arc::new(MockNabIO::new());
        let mut state_machine = NabStateMachine::new(hardware, tx);
        
        // Try invalid transition
        let result = state_machine.request_transition(
            NabState::Interactive,
            TransitionTrigger::SystemStartup, // Wrong trigger for this transition
        ).await;
        
        assert!(result.is_err());
    }
    
    #[tokio::test]
    async fn test_service_blocking() {
        let (tx, _rx) = mpsc::unbounded_channel();
        let hardware = Arc::new(MockNabIO::new());
        let mut state_machine = NabStateMachine::new(hardware, tx);
        
        // Register service that blocks sleep
        let service = ServiceState {
            name: "test_service".to_string(),
            active: true,
            requires_interactive: false,
            blocks_sleep: true,
            last_activity: Some(Instant::now()),
        };
        state_machine.register_service(service).await;
        
        // Attempt to sleep should be blocked
        assert!(!state_machine.can_transition_to_sleep().await);
    }
}
```

## Performance Considerations

### State Machine Optimization

1. **Lock Contention**: Use RwLock for read-heavy operations
2. **Event Processing**: Use unbounded channels for event propagation
3. **Timer Management**: Efficient timer implementation for timeouts
4. **Memory Usage**: Minimize state machine memory footprint

### Monitoring and Metrics

```rust
pub struct StateMachineMetrics {
    pub transition_count: HashMap<(NabState, NabState), u64>,
    pub time_in_state: HashMap<NabState, Duration>,
    pub last_transition: Option<Instant>,
    pub error_count: u64,
}

impl NabStateMachine {
    pub fn get_metrics(&self) -> StateMachineMetrics {
        // Return current metrics
    }
    
    pub fn reset_metrics(&mut self) {
        // Reset all metrics
    }
}
```

This state machine specification provides a robust foundation for managing the Nabaztag's behavior while maintaining compatibility with the existing Python services and enabling new functionality in the Rust implementation.