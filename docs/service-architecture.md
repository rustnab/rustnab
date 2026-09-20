# Service Architecture Specification

## Overview

This document defines the service architecture patterns and framework for the Pynab Rust implementation, ensuring compatibility with the existing Python service ecosystem while providing a robust foundation for new services.

## Service Framework Architecture

### Core Service Traits

```rust
use async_trait::async_trait;
use serde_json::Value;
use std::time::Duration;
use tokio::sync::mpsc;
use chrono::{DateTime, Utc};

#[async_trait]
pub trait NabService: Send + Sync {
    /// Service name for registration with nabd
    fn service_name(&self) -> &'static str;
    
    /// Service version for compatibility checking
    fn service_version(&self) -> &'static str { "1.0" }
    
    /// Initialize the service (called once at startup)
    async fn initialize(&mut self) -> Result<(), ServiceError>;
    
    /// Start the service (begin normal operation)
    async fn start(&self) -> Result<(), ServiceError>;
    
    /// Stop the service gracefully
    async fn stop(&self) -> Result<(), ServiceError>;
    
    /// Handle incoming protocol packets from nabd
    async fn handle_packet(&self, packet: NabPacket) -> Result<Option<NabPacket>, ServiceError>;
    
    /// Get service information for info requests
    async fn get_info(&self) -> Result<ServiceInfo, ServiceError>;
    
    /// Handle service shutdown (cleanup resources)
    async fn shutdown(&mut self) -> Result<(), ServiceError>;
}

#[derive(Debug, Clone)]
pub struct ServiceInfo {
    pub name: String,
    pub version: String,
    pub state: ServiceState,
    pub capabilities: Vec<String>,
    pub config: Option<Value>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum ServiceState {
    Stopped,
    Starting,
    Running,
    Stopping,
    Error(String),
}
```

### Recurrent Service Trait

For services that need to perform periodic tasks:

```rust
#[async_trait]
pub trait NabRecurrentService: NabService {
    /// Perform a scheduled task
    async fn perform(&self, expiration_date: DateTime<Utc>, args: Value) -> Result<(), ServiceError>;
    
    /// Compute the next execution time
    async fn compute_next(
        &self,
        now: DateTime<Utc>,
        last_run: Option<DateTime<Utc>>,
        args: Value,
        config: &ServiceConfig,
    ) -> Result<Option<(DateTime<Utc>, Value)>, ServiceError>;
}

pub struct RecurrentTaskScheduler {
    tasks: HashMap<String, RecurrentTask>,
    scheduler: Arc<Mutex<TaskScheduler>>,
}

#[derive(Debug, Clone)]
pub struct RecurrentTask {
    pub service_name: String,
    pub next_run: DateTime<Utc>,
    pub args: Value,
    pub interval: Option<Duration>,
}
```

### Configuration Management

```rust
use config::{Config, ConfigError, File, Environment};
use serde::{Deserialize, Serialize};

#[derive(Debug, Deserialize)]
pub struct ServiceConfig {
    pub enabled: bool,
    pub debug: bool,
    pub settings: HashMap<String, Value>,
}

pub trait Configurable {
    type Config: for<'de> Deserialize<'de> + Send + Sync;
    
    fn default_config() -> Self::Config;
    fn config_file_name(&self) -> &'static str;
    
    fn load_config(&self) -> Result<Self::Config, ConfigError> {
        let mut config = Config::builder()
            .add_source(File::with_name(&format!("/opt/pynab/{}", self.config_file_name())))
            .add_source(Environment::with_prefix("NAB"))
            .build()?;
        
        config.try_deserialize()
    }
}

// Example service configuration
#[derive(Debug, Deserialize)]
pub struct ClockServiceConfig {
    pub enabled: bool,
    pub chime_hour: bool,
    pub timezone: String,
    pub wakeup_time: Option<String>,
    pub sleep_time: Option<String>,
}

impl Default for ClockServiceConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            chime_hour: false,
            timezone: "UTC".to_string(),
            wakeup_time: None,
            sleep_time: None,
        }
    }
}
```

### Connection Workflow

Services follow a deterministic handshake:

1. `NabdClient::connect` opens the TCP stream and waits for the initial `state` packet.
2. The client immediately sends a `mode` packet with `mode = "idle"` plus desired event subscriptions.
3. Incoming packets are fanned into `handle_packet`, which must process `response` statuses and event payloads.
4. When exclusive access is needed (for example, a voice interaction), the service sends `mode = "interactive"` and waits for the `state` transition to `interactive` before issuing commands.
5. On shutdown or signal handling, services should revert to `mode = "idle"`, flush outstanding work, and close the connection gracefully.

## Service Base Implementation

### Base Service Structure

```rust
pub struct BaseService {
    pub name: &'static str,
    pub version: &'static str,
    pub state: Arc<Mutex<ServiceState>>,
    pub client: Arc<Mutex<Option<NabdClient>>>,
    pub config: Arc<RwLock<ServiceConfig>>,
    pub event_sender: mpsc::UnboundedSender<ServiceEvent>,
    pub shutdown_signal: Arc<AtomicBool>,
}

impl BaseService {
    pub fn new(name: &'static str, version: &'static str) -> Self {
        let (event_sender, _) = mpsc::unbounded_channel();
        
        Self {
            name,
            version,
            state: Arc::new(Mutex::new(ServiceState::Stopped)),
            client: Arc::new(Mutex::new(None)),
            config: Arc::new(RwLock::new(ServiceConfig::default())),
            event_sender,
            shutdown_signal: Arc::new(AtomicBool::new(false)),
        }
    }
    
    pub async fn connect_to_nabd(&self) -> Result<(), ServiceError> {
        let client = NabdClient::connect("127.0.0.1:10543").await?;
        client.send_packet(NabPacket::Mode {
            mode: NabMode::Idle,
            events: Some(vec!["button".into(), "ears".into()]),
            request_id: None,
        }).await?;
        
        let mut client_guard = self.client.lock().await;
        *client_guard = Some(client);
        
        Ok(())
    }
    
    pub async fn send_packet(&self, packet: NabPacket) -> Result<Option<NabPacket>, ServiceError> {
        let client_guard = self.client.lock().await;
        if let Some(client) = client_guard.as_ref() {
            client.send_packet(packet).await
        } else {
            Err(ServiceError::NotConnected)
        }
    }
    
    pub async fn set_state(&self, state: ServiceState) {
        let mut state_guard = self.state.lock().await;
        *state_guard = state;
    }
}
```

### Service Event System

```rust
#[derive(Debug, Clone)]
pub enum ServiceEvent {
    StateChanged(ServiceState),
    ConfigUpdated(ServiceConfig),
    HardwareEvent(HardwareEvent),
    Error(ServiceError),
}

#[derive(Debug, Clone)]
pub enum HardwareEvent {
    Button(ButtonEvent),
    Rfid(RfidEvent),
    Ear(EarEvent),
    AudioPlaybackFinished,
}

pub struct EventBus {
    subscribers: Arc<Mutex<HashMap<String, Vec<mpsc::UnboundedSender<ServiceEvent>>>>>,
}

impl EventBus {
    pub fn new() -> Self {
        Self {
            subscribers: Arc::new(Mutex::new(HashMap::new())),
        }
    }
    
    pub async fn subscribe(&self, service_name: String) -> mpsc::UnboundedReceiver<ServiceEvent> {
        let (sender, receiver) = mpsc::unbounded_channel();
        let mut subscribers = self.subscribers.lock().await;
        subscribers.entry(service_name).or_default().push(sender);
        receiver
    }
    
    pub async fn publish(&self, event: ServiceEvent) {
        let subscribers = self.subscribers.lock().await;
        for senders in subscribers.values() {
            for sender in senders {
                let _ = sender.send(event.clone());
            }
        }
    }
}
```

## Nabd Client Library

### Protocol Client Implementation

```rust
use tokio::net::TcpStream;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader, BufWriter};
use serde_json;

pub struct NabdClient {
    reader: BufReader<tokio::net::tcp::OwnedReadHalf>,
    writer: BufWriter<tokio::net::tcp::OwnedWriteHalf>,
    request_counter: Arc<AtomicU64>,
    pending_requests: Arc<Mutex<HashMap<String, oneshot::Sender<NabPacket>>>>,
}

impl NabdClient {
    pub async fn connect(addr: &str) -> Result<Self, ServiceError> {
        let stream = TcpStream::connect(addr).await?;
        let (read_half, write_half) = stream.into_split();
        
        let reader = BufReader::new(read_half);
        let writer = BufWriter::new(write_half);
        
        Ok(Self {
            reader,
            writer,
            request_counter: Arc::new(AtomicU64::new(0)),
            pending_requests: Arc::new(Mutex::new(HashMap::new())),
        })
    }
    
    pub async fn register(&mut self, service_name: &str) -> Result<(), ServiceError> {
        let request_id = self.generate_request_id();
        
        let registration = NabPacket::Register {
            service: service_name.to_string(),
            request_id: Some(request_id.clone()),
        };
        
        let response = self.send_request(registration).await?;
        match response {
            NabPacket::Response { status: ResponseStatus::Ok, .. } => Ok(()),
            NabPacket::Response { status: ResponseStatus::Error(err), .. } => {
                Err(ServiceError::RegistrationFailed(err))
            },
            _ => Err(ServiceError::UnexpectedResponse),
        }
    }
    
    pub async fn send_packet(&mut self, packet: NabPacket) -> Result<Option<NabPacket>, ServiceError> {
        let json = serde_json::to_string(&packet)?;
        self.writer.write_all(json.as_bytes()).await?;
        self.writer.write_all(b"\n").await?;
        self.writer.flush().await?;
        
        // If packet has request_id, wait for response
        if let Some(request_id) = packet.request_id() {
            let (sender, receiver) = oneshot::channel();
            {
                let mut pending = self.pending_requests.lock().await;
                pending.insert(request_id, sender);
            }
            
            match tokio::time::timeout(Duration::from_secs(30), receiver).await {
                Ok(Ok(response)) => Ok(Some(response)),
                Ok(Err(_)) => Err(ServiceError::ResponseChannelClosed),
                Err(_) => Err(ServiceError::RequestTimeout),
            }
        } else {
            Ok(None)
        }
    }
    
    pub async fn start_event_loop<F>(&mut self, mut event_handler: F) -> Result<(), ServiceError>
    where
        F: FnMut(NabPacket) -> Result<(), ServiceError> + Send,
    {
        let mut line = String::new();
        
        loop {
            line.clear();
            match self.reader.read_line(&mut line).await {
                Ok(0) => break, // EOF
                Ok(_) => {
                    if let Ok(packet) = serde_json::from_str::<NabPacket>(&line.trim()) {
                        // Handle responses to pending requests
                        if let Some(request_id) = packet.request_id() {
                            let mut pending = self.pending_requests.lock().await;
                            if let Some(sender) = pending.remove(&request_id) {
                                let _ = sender.send(packet);
                                continue;
                            }
                        }
                        
                        // Handle events and other packets
                        if let Err(e) = event_handler(packet) {
                            eprintln!("Event handler error: {}", e);
                        }
                    }
                },
                Err(e) => return Err(ServiceError::IoError(e)),
            }
        }
        
        Ok(())
    }
    
    fn generate_request_id(&self) -> String {
        let counter = self.request_counter.fetch_add(1, Ordering::Relaxed);
        format!("req_{}", counter)
    }
}
```

## Service Lifecycle Management

### Service Manager

```rust
pub struct ServiceManager {
    services: HashMap<String, Box<dyn NabService>>,
    recurrent_services: HashMap<String, Box<dyn NabRecurrentService>>,
    scheduler: Arc<Mutex<RecurrentTaskScheduler>>,
    event_bus: Arc<EventBus>,
    shutdown_signal: Arc<AtomicBool>,
}

impl ServiceManager {
    pub fn new() -> Self {
        Self {
            services: HashMap::new(),
            recurrent_services: HashMap::new(),
            scheduler: Arc::new(Mutex::new(RecurrentTaskScheduler::new())),
            event_bus: Arc::new(EventBus::new()),
            shutdown_signal: Arc::new(AtomicBool::new(false)),
        }
    }
    
    pub fn register_service<T>(&mut self, service: T)
    where
        T: NabService + 'static,
    {
        self.services.insert(service.service_name().to_string(), Box::new(service));
    }
    
    pub fn register_recurrent_service<T>(&mut self, service: T)
    where
        T: NabRecurrentService + 'static,
    {
        let name = service.service_name().to_string();
        self.services.insert(name.clone(), Box::new(service));
    }
    
    pub async fn start_all_services(&mut self) -> Result<(), ServiceError> {
        for (name, service) in &mut self.services {
            println!("Starting service: {}", name);
            service.initialize().await?;
            service.start().await?;
        }
        
        // Start scheduler for recurrent services
        self.start_scheduler().await?;
        
        Ok(())
    }
    
    pub async fn stop_all_services(&mut self) -> Result<(), ServiceError> {
        self.shutdown_signal.store(true, Ordering::Relaxed);
        
        for (name, service) in &mut self.services {
            println!("Stopping service: {}", name);
            service.stop().await?;
            service.shutdown().await?;
        }
        
        Ok(())
    }
    
    async fn start_scheduler(&self) -> Result<(), ServiceError> {
        let scheduler = self.scheduler.clone();
        let shutdown_signal = self.shutdown_signal.clone();
        
        tokio::spawn(async move {
            let mut interval = tokio::time::interval(Duration::from_secs(1));
            
            while !shutdown_signal.load(Ordering::Relaxed) {
                interval.tick().await;
                
                let mut scheduler_guard = scheduler.lock().await;
                scheduler_guard.process_due_tasks().await;
            }
        });
        
        Ok(())
    }
}
```

### Service Process Management

```rust
use tokio::process::Command;
use std::process::Stdio;

pub struct ServiceProcess {
    pub name: String,
    pub executable: String,
    pub args: Vec<String>,
    pub working_dir: Option<String>,
    pub env_vars: HashMap<String, String>,
    pub restart_policy: RestartPolicy,
}

#[derive(Debug, Clone)]
pub enum RestartPolicy {
    Never,
    Always,
    OnFailure,
    UnlessStopped,
}

pub struct ProcessManager {
    processes: HashMap<String, ServiceProcess>,
    running: HashMap<String, tokio::process::Child>,
}

impl ProcessManager {
    pub async fn start_service(&mut self, name: &str) -> Result<(), ServiceError> {
        if let Some(process_spec) = self.processes.get(name) {
            let mut cmd = Command::new(&process_spec.executable);
            cmd.args(&process_spec.args);
            
            if let Some(working_dir) = &process_spec.working_dir {
                cmd.current_dir(working_dir);
            }
            
            for (key, value) in &process_spec.env_vars {
                cmd.env(key, value);
            }
            
            cmd.stdout(Stdio::piped())
               .stderr(Stdio::piped());
            
            let child = cmd.spawn()?;
            self.running.insert(name.to_string(), child);
            
            Ok(())
        } else {
            Err(ServiceError::ServiceNotFound(name.to_string()))
        }
    }
    
    pub async fn stop_service(&mut self, name: &str) -> Result<(), ServiceError> {
        if let Some(mut child) = self.running.remove(name) {
            child.kill().await?;
            Ok(())
        } else {
            Err(ServiceError::ServiceNotRunning(name.to_string()))
        }
    }
}
```

## Choreography Service Framework

### Choreography Execution Engine

```rust
use std::time::{Duration, Instant};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Choreography {
    pub steps: Vec<ChoreographyStep>,
    pub loop_count: Option<u32>,
    pub name: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChoreographyStep {
    pub tempo: u32,              // Duration in 10ms units
    pub colors: Option<[String; 5]>, // LED colors
    pub left: Option<i16>,       // Left ear position
    pub right: Option<i16>,      // Right ear position
    pub audio: Option<String>,   // Audio file path
}

pub struct ChoreographyEngine {
    hardware: Arc<NabIO>,
    current_choreography: Option<ChoreographyExecution>,
    is_playing: Arc<AtomicBool>,
}

struct ChoreographyExecution {
    choreography: Choreography,
    current_step: usize,
    step_start_time: Instant,
    loop_count: u32,
}

impl ChoreographyEngine {
    pub fn new(hardware: Arc<NabIO>) -> Self {
        Self {
            hardware,
            current_choreography: None,
            is_playing: Arc::new(AtomicBool::new(false)),
        }
    }
    
    pub async fn play_choreography(&mut self, choreography: Choreography) -> Result<(), ServiceError> {
        self.stop_current().await?;
        
        let execution = ChoreographyExecution {
            choreography,
            current_step: 0,
            step_start_time: Instant::now(),
            loop_count: 0,
        };
        
        self.current_choreography = Some(execution);
        self.is_playing.store(true, Ordering::Relaxed);
        
        // Start execution loop
        let hardware = self.hardware.clone();
        let is_playing = self.is_playing.clone();
        
        tokio::spawn(async move {
            while is_playing.load(Ordering::Relaxed) {
                if let Err(e) = Self::execute_step(&hardware).await {
                    eprintln!("Choreography execution error: {}", e);
                    is_playing.store(false, Ordering::Relaxed);
                }
                
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        });
        
        Ok(())
    }
    
    async fn execute_step(hardware: &NabIO) -> Result<(), ServiceError> {
        // Implementation of step execution logic
        // This would handle timing, LED updates, ear movements, audio playback
        Ok(())
    }
    
    pub async fn stop_current(&mut self) -> Result<(), ServiceError> {
        self.is_playing.store(false, Ordering::Relaxed);
        self.current_choreography = None;
        
        // Stop all hardware activity
        self.hardware.leds.clear_all().await?;
        self.hardware.ears.stop_all().await?;
        self.hardware.audio.stop_all_playback().await?;
        
        Ok(())
    }
}
```

## Error Handling and Logging

### Service Error Types

```rust
#[derive(thiserror::Error, Debug)]
pub enum ServiceError {
    #[error("Service not connected to nabd")]
    NotConnected,
    
    #[error("Registration failed: {0}")]
    RegistrationFailed(String),
    
    #[error("Service not found: {0}")]
    ServiceNotFound(String),
    
    #[error("Service not running: {0}")]
    ServiceNotRunning(String),
    
    #[error("Configuration error: {0}")]
    Configuration(#[from] ConfigError),
    
    #[error("Hardware error: {0}")]
    Hardware(#[from] HardwareError),
    
    #[error("Protocol error: {0}")]
    Protocol(#[from] ProtocolError),
    
    #[error("IO error: {0}")]
    IoError(#[from] std::io::Error),
    
    #[error("JSON serialization error: {0}")]
    Json(#[from] serde_json::Error),
    
    #[error("Request timeout")]
    RequestTimeout,
    
    #[error("Unexpected response")]
    UnexpectedResponse,
    
    #[error("Response channel closed")]
    ResponseChannelClosed,
}
```

### Logging Integration

```rust
use tracing::{info, warn, error, debug, trace};
use tracing_subscriber;

pub fn init_logging(service_name: &str, debug: bool) {
    let level = if debug {
        tracing::Level::DEBUG
    } else {
        tracing::Level::INFO
    };
    
    tracing_subscriber::fmt()
        .with_target(false)
        .with_level(true)
        .with_thread_ids(false)
        .with_file(debug)
        .with_line_number(debug)
        .with_max_level(level)
        .init();
        
    info!("Started {} service", service_name);
}

// Usage in services:
// info!("Service started successfully");
// debug!("Processing packet: {:?}", packet);
// warn!("Configuration file not found, using defaults");
// error!("Failed to connect to hardware: {}", error);
```

## Testing Framework

### Service Testing Utilities

```rust
#[cfg(test)]
pub mod testing {
    use super::*;
    
    pub struct MockNabdClient {
        sent_packets: Arc<Mutex<Vec<NabPacket>>>,
        responses: Arc<Mutex<VecDeque<NabPacket>>>,
    }
    
    impl MockNabdClient {
        pub fn new() -> Self {
            Self {
                sent_packets: Arc::new(Mutex::new(Vec::new())),
                responses: Arc::new(Mutex::new(VecDeque::new())),
            }
        }
        
        pub async fn add_response(&self, packet: NabPacket) {
            let mut responses = self.responses.lock().await;
            responses.push_back(packet);
        }
        
        pub async fn get_sent_packets(&self) -> Vec<NabPacket> {
            let packets = self.sent_packets.lock().await;
            packets.clone()
        }
    }
    
    pub struct ServiceTestHarness<T: NabService> {
        pub service: T,
        pub mock_client: MockNabdClient,
        pub event_receiver: mpsc::UnboundedReceiver<ServiceEvent>,
    }
    
    impl<T: NabService> ServiceTestHarness<T> {
        pub fn new(service: T) -> Self {
            let mock_client = MockNabdClient::new();
            let (_, event_receiver) = mpsc::unbounded_channel();
            
            Self {
                service,
                mock_client,
                event_receiver,
            }
        }
        
        pub async fn initialize(&mut self) -> Result<(), ServiceError> {
            self.service.initialize().await
        }
        
        pub async fn send_packet(&mut self, packet: NabPacket) -> Result<Option<NabPacket>, ServiceError> {
            self.service.handle_packet(packet).await
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use testing::*;
    
    #[tokio::test]
    async fn test_service_registration() {
        let service = TestService::new("test_service");
        let mut harness = ServiceTestHarness::new(service);
        
        harness.initialize().await.unwrap();
        
        let info = harness.service.get_info().await.unwrap();
        assert_eq!(info.name, "test_service");
        assert_eq!(info.state, ServiceState::Running);
    }
    
    #[tokio::test]
    async fn test_packet_handling() {
        let service = TestService::new("test_service");
        let mut harness = ServiceTestHarness::new(service);
        
        let packet = NabPacket::Info {
            request_id: Some("test_req".to_string()),
        };
        
        let response = harness.send_packet(packet).await.unwrap();
        assert!(response.is_some());
    }
}
```

## Performance Considerations

### Memory Management
- Use `Arc` for shared ownership of expensive-to-clone data
- Prefer `Arc<Mutex<T>>` over `Arc<RwLock<T>>` for frequently modified data
- Use channels for message passing between async tasks
- Implement connection pooling for database connections

### Async Best Practices
- Use `tokio::spawn` for CPU-intensive tasks
- Prefer `tokio::time::timeout` for network operations
- Use bounded channels to prevent memory leaks
- Implement proper backpressure handling

### Resource Management
```rust
pub struct ResourceManager {
    hardware_lock: Arc<Mutex<()>>,
    audio_semaphore: Arc<Semaphore>,
    network_pool: Arc<ConnectionPool>,
}

impl ResourceManager {
    pub async fn acquire_hardware(&self) -> HardwareLock {
        let _guard = self.hardware_lock.lock().await;
        HardwareLock::new(_guard)
    }
    
    pub async fn acquire_audio_channel(&self) -> Result<AudioPermit, ServiceError> {
        let permit = self.audio_semaphore.acquire().await?;
        Ok(AudioPermit::new(permit))
    }
}
```

This service architecture provides a robust foundation for implementing Pynab services in Rust while maintaining compatibility with the existing ecosystem.
