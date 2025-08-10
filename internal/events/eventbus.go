package events

import (
	"context"
	"fmt"
	"io"
	"log"
	"path/filepath"
	"sync"
	"sync/atomic"
	"time"
	
	"github.com/tphakala/birdnet-go/internal/errors"
	"github.com/tphakala/birdnet-go/internal/logging"
	"log/slog"
)

const (
	// slowConsumerThreshold defines the duration after which a consumer is considered slow
	slowConsumerThreshold = 100 * time.Millisecond
)

// Package-level logger for event bus operations
var (
	logger      *slog.Logger
	levelVar    = new(slog.LevelVar) // Dynamic level control
	closeLogger func() error
)

func init() {
	var err error
	// Define log file path for events service
	logFilePath := filepath.Join("logs", "events.log")
	initialLevel := slog.LevelInfo // Default to Info, Debug when debugging
	levelVar.Set(initialLevel)

	// Initialize the service-specific file logger
	logger, closeLogger, err = logging.NewFileLogger(logFilePath, "events", levelVar)
	if err != nil {
		// Fallback to standard logging with enhanced error
		descriptiveErr := errors.Newf("events: failed to initialize file logger: %v", err).
			Component("events").
			Category(errors.CategoryFileIO).
			Context("log_file", logFilePath).
			Context("operation", "logger_initialization").
			Build()
		log.Printf("Failed to initialize events file logger: %v", descriptiveErr)
		
		// Fallback to disabled logger that respects level var
		fbHandler := slog.NewJSONHandler(io.Discard, &slog.HandlerOptions{Level: levelVar})
		logger = slog.New(fbHandler).With("service", "events")
		closeLogger = func() error { return nil }
	}
}

// EventType represents the semantic type of an event for logging and categorization
type EventType string

// Event type constants for logging with semantic meanings
const (
	// EventTypeError represents error events such as failures, exceptions, or operational issues
	EventTypeError EventType = "error"
	
	// EventTypeResource represents resource-related events like file operations, disk usage, or memory events
	EventTypeResource EventType = "resource"
	
	// EventTypeDetection represents bird detection events from the BirdNET analysis engine
	EventTypeDetection EventType = "detection"
	
	// EventTypeUnknown represents events that cannot be categorized into the above types
	EventTypeUnknown EventType = "unknown"
)

// Sentinel errors for event bus operations
var (
	ErrEventBusDisabled = errors.Newf("event bus is disabled").Component("events").Category(errors.CategoryNotFound).Build()
)

// getEventType returns a semantic event type instead of Go type strings
// This provides better observability in logs by showing meaningful event types.
// The function is designed to be extensible - add new cases for future event types.
func getEventType(event any) EventType {
	switch event.(type) {
	// Concrete type checks first (more specific)
	case *errors.EnhancedError:
		return EventTypeError
	// Interface checks (more general)
	case ErrorEvent:
		return EventTypeError
	case ResourceEvent:
		return EventTypeResource
	case DetectionEvent:
		return EventTypeDetection
	default:
		// Return generic constant to avoid exposing internal types
		// Use EventTypeUnknown instead of Go type strings for security
		return EventTypeUnknown
	}
}

// EventBus provides asynchronous event processing with non-blocking guarantees
type EventBus struct {
	// Channels for different event types
	errorEventChan     chan ErrorEvent
	resourceEventChan  chan ResourceEvent
	detectionEventChan chan DetectionEvent
	
	// Configuration
	config     *Config
	bufferSize int
	workers    int
	
	// State management
	ctx         context.Context
	cancel      context.CancelFunc
	wg          sync.WaitGroup
	initialized atomic.Bool
	running     atomic.Bool
	mu          sync.Mutex
	
	// Consumers
	consumers          []EventConsumer
	resourceConsumers  []ResourceEventConsumer  // Separate slice for resource event consumers
	detectionConsumers []DetectionEventConsumer // Separate slice for detection event consumers
	
	// Deduplication
	deduplicator *ErrorDeduplicator
	
	// Metrics
	stats     EventBusStats
	startTime time.Time
	
	// Logging
	logger *slog.Logger
}

// Global event bus instance (lazily initialized)
var (
	globalEventBus *EventBus
	globalMutex    sync.Mutex
	
	// Fast path optimization: track if any consumers are registered
	hasActiveConsumers atomic.Bool
)

// HasActiveConsumers returns true if any consumers are registered
// This is used for fast path optimization to avoid overhead when no consumers exist
func HasActiveConsumers() bool {
	return hasActiveConsumers.Load()
}

// ResetForTesting resets the global event bus state (for testing only)
func ResetForTesting() {
	globalMutex.Lock()
	defer globalMutex.Unlock()
	
	if globalEventBus != nil {
		_ = globalEventBus.Shutdown(1 * time.Second)
	}
	globalEventBus = nil
	hasActiveConsumers.Store(false)
}

// DefaultConfig returns the default event bus configuration
func DefaultConfig() *Config {
	return &Config{
		BufferSize:   10000,
		Workers:      4,
		Enabled:      true,
		Deduplication: DefaultDeduplicationConfig(),
	}
}

// Config holds event bus configuration
type Config struct {
	BufferSize         int  // Buffer size for error events
	ResourceBufferSize int  // Buffer size for resource events (if 0, uses BufferSize)
	Workers            int
	Enabled            bool
	Debug              bool // Enable debug logging
	Deduplication      *DeduplicationConfig
}

// Initialize creates or returns the global event bus instance
func Initialize(config *Config) (*EventBus, error) {
	globalMutex.Lock()
	defer globalMutex.Unlock()
	
	// Return existing instance if already initialized
	if globalEventBus != nil {
		return globalEventBus, nil
	}
	
	// Use default config if none provided
	if config == nil {
		config = DefaultConfig()
	}
	
	// Skip initialization if disabled
	if !config.Enabled {
		return nil, ErrEventBusDisabled
	}
	
	// Set logger level based on debug flag
	if config.Debug {
		levelVar.Set(slog.LevelDebug)
	}
	
	// Create new event bus
	ctx, cancel := context.WithCancel(context.Background())
	
	// Use ResourceBufferSize if specified, otherwise fall back to BufferSize
	resourceBufSize := config.ResourceBufferSize
	if resourceBufSize == 0 {
		resourceBufSize = config.BufferSize
	}
	
	eb := &EventBus{
		config:             config,
		errorEventChan:     make(chan ErrorEvent, config.BufferSize),
		resourceEventChan:  make(chan ResourceEvent, resourceBufSize),
		detectionEventChan: make(chan DetectionEvent, config.BufferSize),
		bufferSize:         config.BufferSize,
		workers:            config.Workers,
		ctx:                ctx,
		cancel:             cancel,
		consumers:          make([]EventConsumer, 0),
		resourceConsumers:  make([]ResourceEventConsumer, 0),
		detectionConsumers: make([]DetectionEventConsumer, 0),
		logger:             logger,
		startTime:          time.Now(),
	}
	
	// Initialize deduplicator if enabled
	if config.Deduplication != nil && config.Deduplication.Enabled {
		eb.deduplicator = NewErrorDeduplicator(config.Deduplication, eb.logger)
	}
	
	// Mark as initialized
	eb.initialized.Store(true)
	
	// Store global instance
	globalEventBus = eb
	
	eb.logger.Info("event bus initialized",
		"buffer_size", config.BufferSize,
		"workers", config.Workers,
		"debug", config.Debug,
		"deduplication", config.Deduplication != nil && config.Deduplication.Enabled,
	)
	
	return eb, nil
}

// GetEventBus returns the global event bus instance
func GetEventBus() *EventBus {
	globalMutex.Lock()
	defer globalMutex.Unlock()
	return globalEventBus
}

// IsInitialized returns true if the event bus has been initialized
func IsInitialized() bool {
	globalMutex.Lock()
	defer globalMutex.Unlock()
	return globalEventBus != nil && globalEventBus.initialized.Load()
}

// RegisterConsumer adds a new event consumer
func (eb *EventBus) RegisterConsumer(consumer EventConsumer) error {
	start := time.Now()
	
	if eb == nil {
		return fmt.Errorf("event bus not initialized")
	}
	
	eb.mu.Lock()
	defer eb.mu.Unlock()
	
	// Check for duplicate
	for _, existing := range eb.consumers {
		if existing.Name() == consumer.Name() {
			return fmt.Errorf("consumer %s already registered", consumer.Name())
		}
	}
	
	eb.consumers = append(eb.consumers, consumer)
	
	// Check if consumer also implements ResourceEventConsumer
	if resourceConsumer, ok := consumer.(ResourceEventConsumer); ok {
		eb.resourceConsumers = append(eb.resourceConsumers, resourceConsumer)
	}
	
	// Check if consumer also implements DetectionEventConsumer
	if detectionConsumer, ok := consumer.(DetectionEventConsumer); ok {
		eb.detectionConsumers = append(eb.detectionConsumers, detectionConsumer)
	}
	
	// Update global flag for fast path optimization
	hasActiveConsumers.Store(true)
	
	duration := time.Since(start)
	eb.logger.Info("registered event consumer",
		"consumer", consumer.Name(),
		"supports_batching", consumer.SupportsBatching(),
		"duration_ms", duration.Milliseconds(),
		"total_consumers", len(eb.consumers),
	)
	
	// Start workers if this is the first consumer and not already running
	if len(eb.consumers) == 1 && !eb.running.Load() {
		eb.start()
	}
	
	return nil
}

// TryPublish attempts to publish an event without blocking
// Returns true if the event was accepted, false if dropped
func (eb *EventBus) TryPublish(event ErrorEvent) bool {
	// Ultra-fast path: check global flag first (lock-free)
	if !hasActiveConsumers.Load() {
		if eb != nil {
			atomic.AddUint64(&eb.stats.FastPathHits, 1)
		}
		return false
	}
	
	if eb == nil || !eb.initialized.Load() || !eb.running.Load() {
		return false
	}
	
	// Debug logging for event publishing
	if eb.config != nil && eb.config.Debug {
		eb.logger.Debug("publishing event",
			"event_type", getEventType(event),
			"component", event.GetComponent(),
			"category", event.GetCategory(),
			"error_buffer_used", len(eb.errorEventChan),
			"error_buffer_capacity", cap(eb.errorEventChan),
			"active_consumers", len(eb.consumers),
		)
	}
	
	// Fast path - check if we have consumers
	eb.mu.Lock()
	hasConsumers := len(eb.consumers) > 0
	eb.mu.Unlock()
	
	if !hasConsumers {
		atomic.AddUint64(&eb.stats.FastPathHits, 1)
		return false
	}
	
	// Check deduplication
	if eb.deduplicator != nil {
		if !eb.deduplicator.ShouldProcess(event) {
			atomic.AddUint64(&eb.stats.EventsSuppressed, 1)
			return true // Return true since we handled it (by suppressing)
		}
	}
	
	// Non-blocking send
	select {
	case eb.errorEventChan <- event:
		atomic.AddUint64(&eb.stats.EventsReceived, 1)
		return true
	default:
		// Channel full, drop the event
		atomic.AddUint64(&eb.stats.EventsDropped, 1)
		
		// Log at debug level to avoid spam
		if eb.logger != nil {
			eb.logger.Debug("event dropped due to full buffer",
				"component", event.GetComponent(),
				"category", event.GetCategory(),
			)
		}
		return false
	}
}

// TryPublishResource attempts to publish a resource event without blocking
// Returns true if the event was accepted, false if dropped
//
//nolint:dupl // Similar to TryPublishDetection but handles different event type
func (eb *EventBus) TryPublishResource(event ResourceEvent) bool {
	// Ultra-fast path: check global flag first (lock-free)
	if !hasActiveConsumers.Load() {
		if eb != nil {
			atomic.AddUint64(&eb.stats.FastPathHits, 1)
		}
		return false
	}
	
	if eb == nil || !eb.initialized.Load() || !eb.running.Load() {
		return false
	}
	
	// Debug logging for event publishing
	if eb.config != nil && eb.config.Debug {
		eb.logger.Debug("publishing resource event",
			"resource_type", event.GetResourceType(),
			"current_value", event.GetCurrentValue(),
			"severity", event.GetSeverity(),
			"buffer_used", len(eb.resourceEventChan),
			"buffer_capacity", cap(eb.resourceEventChan),
			"active_consumers", len(eb.consumers),
		)
	}
	
	// Fast path - check if we have consumers
	eb.mu.Lock()
	hasConsumers := len(eb.consumers) > 0
	eb.mu.Unlock()
	
	if !hasConsumers {
		atomic.AddUint64(&eb.stats.FastPathHits, 1)
		return false
	}
	
	// Non-blocking send
	select {
	case eb.resourceEventChan <- event:
		atomic.AddUint64(&eb.stats.EventsReceived, 1)
		return true
	default:
		// Channel full, drop the event
		atomic.AddUint64(&eb.stats.EventsDropped, 1)
		
		// Log at debug level to avoid spam
		if eb.logger != nil {
			eb.logger.Debug("resource event dropped due to full buffer",
				"resource_type", event.GetResourceType(),
				"severity", event.GetSeverity(),
			)
		}
		return false
	}
}

// TryPublishDetection attempts to publish a detection event without blocking
// Returns true if the event was accepted, false if dropped
//
//nolint:dupl // Similar to TryPublishResource but handles different event type
func (eb *EventBus) TryPublishDetection(event DetectionEvent) bool {
	// Ultra-fast path: check global flag first (lock-free)
	if !hasActiveConsumers.Load() {
		if eb != nil {
			atomic.AddUint64(&eb.stats.FastPathHits, 1)
		}
		return false
	}
	
	if eb == nil || !eb.initialized.Load() || !eb.running.Load() {
		return false
	}
	
	// Debug logging for event publishing
	if eb.config != nil && eb.config.Debug {
		eb.logger.Debug("publishing detection event",
			"species", event.GetSpeciesName(),
			"confidence", event.GetConfidence(),
			"is_new_species", event.IsNewSpecies(),
			"buffer_used", len(eb.detectionEventChan),
			"buffer_capacity", cap(eb.detectionEventChan),
			"active_consumers", len(eb.consumers),
		)
	}
	
	// Fast path - check if we have consumers
	eb.mu.Lock()
	hasConsumers := len(eb.consumers) > 0
	eb.mu.Unlock()
	
	if !hasConsumers {
		atomic.AddUint64(&eb.stats.FastPathHits, 1)
		return false
	}
	
	// Non-blocking send
	select {
	case eb.detectionEventChan <- event:
		atomic.AddUint64(&eb.stats.EventsReceived, 1)
		return true
	default:
		// Channel full, drop the event
		atomic.AddUint64(&eb.stats.EventsDropped, 1)
		
		// Log at debug level to avoid spam
		if eb.logger != nil {
			eb.logger.Debug("detection event dropped due to full buffer",
				"species", event.GetSpeciesName(),
				"is_new_species", event.IsNewSpecies(),
			)
		}
		return false
	}
}

// start begins the worker goroutines
func (eb *EventBus) start() {
	if eb.running.Swap(true) {
		return // Already running
	}
	
	eb.logger.Info("starting event bus workers", "count", eb.workers)
	
	// Start worker goroutines
	for i := 0; i < eb.workers; i++ {
		eb.wg.Add(1)
		go eb.worker(i)
	}
	
	// Start metrics logger (logs performance stats periodically)
	eb.wg.Add(1)
	go eb.metricsLogger()
}

// worker processes events from the channels
func (eb *EventBus) worker(id int) {
	defer eb.wg.Done()
	
	logger := eb.logger.With("worker_id", id)
	logger.Debug("worker started")
	
	for {
		select {
		case <-eb.ctx.Done():
			logger.Debug("worker stopping due to context cancellation")
			return
			
		case event, ok := <-eb.errorEventChan:
			if !ok {
				logger.Debug("worker stopping due to error channel closure")
				return
			}
			
			// Add timing for debug mode
			if eb.config != nil && eb.config.Debug {
				start := time.Now()
				eb.processErrorEvent(event, logger)
				duration := time.Since(start)
				logger.Debug("error event processed",
					"event_type", getEventType(event),
					"component", event.GetComponent(),
					"duration_ms", duration.Milliseconds(),
				)
			} else {
				eb.processErrorEvent(event, logger)
			}
			
		case event, ok := <-eb.resourceEventChan:
			if !ok {
				logger.Debug("worker stopping due to resource channel closure")
				return
			}
			
			// Add timing for debug mode
			if eb.config != nil && eb.config.Debug {
				start := time.Now()
				eb.processResourceEvent(event, logger)
				duration := time.Since(start)
				logger.Debug("resource event processed",
					"event_type", getEventType(event),
					"resource_type", event.GetResourceType(),
					"severity", event.GetSeverity(),
					"duration_ms", duration.Milliseconds(),
				)
			} else {
				eb.processResourceEvent(event, logger)
			}
			
		case event, ok := <-eb.detectionEventChan:
			if !ok {
				logger.Debug("worker stopping due to detection channel closure")
				return
			}
			
			// Add timing for debug mode
			if eb.config != nil && eb.config.Debug {
				start := time.Now()
				eb.processDetectionEvent(event, logger)
				duration := time.Since(start)
				logger.Debug("detection event processed",
					"event_type", getEventType(event),
					"species", event.GetSpeciesName(),
					"is_new_species", event.IsNewSpecies(),
					"duration_ms", duration.Milliseconds(),
				)
			} else {
				eb.processDetectionEvent(event, logger)
			}
		}
	}
}

// processEvent is a generic event processor that handles both error and resource events
func (eb *EventBus) processEvent(
	consumerName string,
	processFunc func() error,
	logFields map[string]any,
	logger *slog.Logger,
) {
	// Process in a recovery wrapper to prevent panics
	defer func() {
		if r := recover(); r != nil {
			atomic.AddUint64(&eb.stats.ConsumerErrors, 1)
			// Pre-allocate fields slice for better performance
			fields := make([]any, 0, 4+len(logFields)*2)
			fields = append(fields, "consumer", consumerName, "panic", r)
			for k, v := range logFields {
				fields = append(fields, k, v)
			}
			logger.Error("consumer panicked", fields...)
		}
	}()
	
	// Time consumer processing
	consumerStart := time.Now()
	err := processFunc()
	consumerDuration := time.Since(consumerStart)
	
	// Warn about slow consumers
	if consumerDuration > slowConsumerThreshold {
		// Pre-allocate fields slice for better performance
		fields := make([]any, 0, 6+len(logFields)*2)
		fields = append(fields, "consumer", consumerName, "duration_ms", consumerDuration.Milliseconds())
		for k, v := range logFields {
			fields = append(fields, k, v)
		}
		logger.Warn("slow consumer detected", fields...)
	}
	
	if err != nil {
		atomic.AddUint64(&eb.stats.ConsumerErrors, 1)
		// Pre-allocate fields slice for better performance
		fields := make([]any, 0, 6+len(logFields)*2)
		fields = append(fields, "consumer", consumerName, "error", err)
		for k, v := range logFields {
			fields = append(fields, k, v)
		}
		logger.Error("consumer error", fields...)
	} else {
		atomic.AddUint64(&eb.stats.EventsProcessed, 1)
	}
}

// processErrorEvent sends the error event to all registered consumers
func (eb *EventBus) processErrorEvent(event ErrorEvent, logger *slog.Logger) {
	eb.mu.Lock()
	consumers := make([]EventConsumer, len(eb.consumers))
	copy(consumers, eb.consumers)
	eb.mu.Unlock()
	
	for _, consumer := range consumers {
		logFields := map[string]any{
			"component": event.GetComponent(),
			"category":  event.GetCategory(),
		}
		eb.processEvent(
			consumer.Name(),
			func() error { return consumer.ProcessEvent(event) },
			logFields,
			logger,
		)
	}
}

// processResourceEvent sends the resource event to all registered resource consumers
func (eb *EventBus) processResourceEvent(event ResourceEvent, logger *slog.Logger) {
	eb.mu.Lock()
	resourceConsumers := make([]ResourceEventConsumer, len(eb.resourceConsumers))
	copy(resourceConsumers, eb.resourceConsumers)
	eb.mu.Unlock()
	
	// No type assertions needed - iterate directly over resource consumers
	for _, consumer := range resourceConsumers {
		logFields := map[string]any{
			"resource_type": event.GetResourceType(),
			"severity":      event.GetSeverity(),
		}
		eb.processEvent(
			consumer.Name(),
			func() error { return consumer.ProcessResourceEvent(event) },
			logFields,
			logger,
		)
	}
}

// processDetectionEvent sends the detection event to all registered detection consumers
func (eb *EventBus) processDetectionEvent(event DetectionEvent, logger *slog.Logger) {
	eb.mu.Lock()
	detectionConsumers := make([]DetectionEventConsumer, len(eb.detectionConsumers))
	copy(detectionConsumers, eb.detectionConsumers)
	eb.mu.Unlock()
	
	// No type assertions needed - iterate directly over detection consumers
	for _, consumer := range detectionConsumers {
		logFields := map[string]any{
			"species":        event.GetSpeciesName(),
			"is_new_species": event.IsNewSpecies(),
		}
		eb.processEvent(
			consumer.Name(),
			func() error { return consumer.ProcessDetectionEvent(event) },
			logFields,
			logger,
		)
	}
}

// Shutdown gracefully shuts down the event bus
func (eb *EventBus) Shutdown(timeout time.Duration) error {
	if eb == nil || !eb.initialized.Load() {
		return nil
	}
	
	eb.logger.Info("shutting down event bus", "timeout", timeout)
	
	// Stop accepting new events
	eb.running.Store(false)
	
	// Shutdown deduplicator
	if eb.deduplicator != nil {
		eb.deduplicator.Shutdown()
	}
	
	// Cancel context to signal workers
	eb.cancel()
	
	// Wait for workers with timeout
	done := make(chan struct{})
	go func() {
		eb.wg.Wait()
		close(done)
	}()
	
	select {
	case <-done:
		eb.logger.Info("event bus shutdown complete",
			"total_events_processed", atomic.LoadUint64(&eb.stats.EventsProcessed),
			"total_events_dropped", atomic.LoadUint64(&eb.stats.EventsDropped),
			"final_error_buffer_size", len(eb.errorEventChan),
			"final_resource_buffer_size", len(eb.resourceEventChan),
			"final_detection_buffer_size", len(eb.detectionEventChan),
			"uptime_seconds", time.Since(eb.startTime).Seconds(),
		)
		return nil
	case <-time.After(timeout):
		eb.logger.Warn("event bus shutdown timeout exceeded")
		return fmt.Errorf("shutdown timeout exceeded")
	}
}

// GetStats returns current event bus statistics
func (eb *EventBus) GetStats() EventBusStats {
	if eb == nil {
		return EventBusStats{}
	}
	
	return EventBusStats{
		EventsReceived:   atomic.LoadUint64(&eb.stats.EventsReceived),
		EventsSuppressed: atomic.LoadUint64(&eb.stats.EventsSuppressed),
		EventsProcessed:  atomic.LoadUint64(&eb.stats.EventsProcessed),
		EventsDropped:    atomic.LoadUint64(&eb.stats.EventsDropped),
		ConsumerErrors:   atomic.LoadUint64(&eb.stats.ConsumerErrors),
		FastPathHits:     atomic.LoadUint64(&eb.stats.FastPathHits),
	}
}

// GetDeduplicationStats returns deduplication statistics
func (eb *EventBus) GetDeduplicationStats() DeduplicationStats {
	if eb == nil || eb.deduplicator == nil {
		return DeduplicationStats{}
	}
	
	return eb.deduplicator.GetStats()
}

// metricsLogger periodically logs performance metrics
func (eb *EventBus) metricsLogger() {
	defer eb.wg.Done()
	
	ticker := time.NewTicker(5 * time.Minute)
	defer ticker.Stop()
	
	for {
		select {
		case <-eb.ctx.Done():
			// Log final stats on shutdown
			eb.logMetrics("final")
			return
			
		case <-ticker.C:
			eb.logMetrics("periodic")
		}
	}
}

// logMetrics logs current performance metrics
func (eb *EventBus) logMetrics(reason string) {
	stats := eb.GetStats()
	dedupStats := eb.GetDeduplicationStats()
	
	// Calculate rates
	uptime := time.Since(eb.startTime).Seconds()
	eventsPerSecond := float64(0)
	if uptime > 0 {
		eventsPerSecond = float64(stats.EventsProcessed) / uptime
	}
	
	totalAttempts := stats.EventsReceived + stats.EventsDropped + stats.FastPathHits
	fastPathPercent := float64(0)
	if totalAttempts > 0 {
		fastPathPercent = float64(stats.FastPathHits) / float64(totalAttempts) * 100
	}
	
	// Calculate buffer utilization for all channels
	errorBufferUtil := float64(len(eb.errorEventChan)) / float64(cap(eb.errorEventChan)) * 100
	resourceBufferUtil := float64(len(eb.resourceEventChan)) / float64(cap(eb.resourceEventChan)) * 100
	detectionBufferUtil := float64(len(eb.detectionEventChan)) / float64(cap(eb.detectionEventChan)) * 100
	avgBufferUtilization := (errorBufferUtil + resourceBufferUtil + detectionBufferUtil) / 3
	maxBufferUtilization := errorBufferUtil
	if resourceBufferUtil > maxBufferUtilization {
		maxBufferUtilization = resourceBufferUtil
	}
	if detectionBufferUtil > maxBufferUtilization {
		maxBufferUtilization = detectionBufferUtil
	}
	
	eb.logger.Info("event bus performance metrics",
		"reason", reason,
		"events_received", stats.EventsReceived,
		"events_processed", stats.EventsProcessed,
		"events_dropped", stats.EventsDropped,
		"events_suppressed", stats.EventsSuppressed,
		"events_per_second", fmt.Sprintf("%.2f", eventsPerSecond),
		"consumer_errors", stats.ConsumerErrors,
		"fast_path_hits", stats.FastPathHits,
		"fast_path_percent", fmt.Sprintf("%.2f%%", fastPathPercent),
		"active_consumers", len(eb.consumers),
		"avg_buffer_utilization", fmt.Sprintf("%.1f%%", avgBufferUtilization),
		"max_buffer_utilization", fmt.Sprintf("%.1f%%", maxBufferUtilization),
		"error_buffer_utilization", fmt.Sprintf("%.1f%%", errorBufferUtil),
		"resource_buffer_utilization", fmt.Sprintf("%.1f%%", resourceBufferUtil),
		"detection_buffer_utilization", fmt.Sprintf("%.1f%%", detectionBufferUtil),
		"dedup_total_seen", dedupStats.TotalSeen,
		"dedup_total_suppressed", dedupStats.TotalSuppressed,
		"dedup_cache_size", dedupStats.CacheSize,
		"uptime_hours", fmt.Sprintf("%.2f", uptime/3600),
	)
}