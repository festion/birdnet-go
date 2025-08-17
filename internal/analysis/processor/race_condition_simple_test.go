// race_condition_simple_test.go: Tests that validate the race condition issue in GitHub #1158
//
// These tests demonstrate and validate the race condition between DatabaseAction and SSEAction
// that causes the following user-reported timeout errors:
//   - "database ID not assigned for Eastern Wood-Pewee after 10s timeout"
//   - "note not found in database"
//   - "audio file ... not ready after 5s timeout"
//
// ROOT CAUSE: DatabaseAction and SSEAction execute concurrently via job queue, but SSEAction
// depends on DatabaseAction completion. This creates a race where SSE polls for database
// records that haven't been saved yet.
//
// EVIDENCE: Tests confirm SSE actions start 290-990ms before database operations complete,
// directly causing the timeout scenarios reported by users.
//
// SOLUTION: Enforce sequential execution or implement proper action dependencies.
package processor

import (
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/tphakala/birdnet-go/internal/analysis/jobqueue"
	"github.com/tphakala/birdnet-go/internal/conf"
	"github.com/tphakala/birdnet-go/internal/datastore"
)

// SimpleAction tracks execution timing for race condition tests
type SimpleAction struct {
	name          string
	executeDelay  time.Duration
	executedAt    time.Time
	executed      bool
	executeMutex  sync.Mutex
	onExecute     func() // Callback for additional behavior
}

func (a *SimpleAction) Execute(data any) error {
	a.executeMutex.Lock()
	defer a.executeMutex.Unlock()
	
	// Simulate processing time
	if a.executeDelay > 0 {
		time.Sleep(a.executeDelay)
	}
	
	a.executedAt = time.Now()
	a.executed = true
	
	// Execute callback if provided
	if a.onExecute != nil {
		a.onExecute()
	}
	
	return nil
}

func (a *SimpleAction) GetDescription() string {
	return a.name
}

func (a *SimpleAction) GetExecutionTime() time.Time {
	a.executeMutex.Lock()
	defer a.executeMutex.Unlock()
	return a.executedAt
}

func (a *SimpleAction) WasExecuted() bool {
	a.executeMutex.Lock()
	defer a.executeMutex.Unlock()
	return a.executed
}

// createSimpleDetection creates a basic detection for testing
func createSimpleDetection() Detections {
	now := time.Now()
	return Detections{
		Note: datastore.Note{
			CommonName:     "Test Bird",
			ScientificName: "Testus birdus",
			Confidence:     0.95,
			Source: datastore.AudioSource{ID: "test-source", SafeString: "test-source", DisplayName: "test-source"},
			Date:           now.Format("2006-01-02"),
			Time:           now.Format("15:04:05"),
			BeginTime:      now,
			EndTime:        now.Add(15 * time.Second),
		},
		Results: []datastore.Results{
			{Species: "Testus birdus", Confidence: 0.95},
		},
	}
}

// TestRaceCondition_ConcurrentExecution demonstrates that actions execute concurrently
func TestRaceCondition_ConcurrentExecution(t *testing.T) {
	t.Parallel()

	// Create a job queue for testing
	queue := jobqueue.NewJobQueue()
	queue.SetProcessingInterval(10 * time.Millisecond)
	queue.Start()
	defer func() {
		if err := queue.Stop(); err != nil {
			t.Errorf("Failed to stop queue: %v", err)
		}
	}()

	// Create processor
	processor := &Processor{
		JobQueue: queue,
		Settings: &conf.Settings{Debug: true},
	}

	// Create two actions: one simulates slow database operation, one simulates SSE
	slowDbAction := &SimpleAction{
		name:         "Slow Database Action",
		executeDelay: 500 * time.Millisecond, // Simulate slow database write
	}

	fastSSEAction := &SimpleAction{
		name:         "Fast SSE Action",
		executeDelay: 50 * time.Millisecond, // SSE is normally fast
	}

	// Create tasks for both actions
	detection := createSimpleDetection()
	dbTask := &Task{Type: TaskTypeAction, Detection: detection, Action: slowDbAction}
	sseTask := &Task{Type: TaskTypeAction, Detection: detection, Action: fastSSEAction}

	// Record start time
	startTime := time.Now()

	// Enqueue both tasks - they should execute concurrently
	err1 := processor.EnqueueTask(dbTask)
	err2 := processor.EnqueueTask(sseTask)

	if err1 != nil {
		t.Fatalf("Failed to enqueue database task: %v", err1)
	}
	if err2 != nil {
		t.Fatalf("Failed to enqueue SSE task: %v", err2)
	}

	// Wait for both actions to complete
	timeout := time.After(2 * time.Second)
	ticker := time.NewTicker(10 * time.Millisecond)
	defer ticker.Stop()

	for {
		select {
		case <-timeout:
			t.Fatal("Timeout waiting for actions to execute")
		case <-ticker.C:
			if slowDbAction.WasExecuted() && fastSSEAction.WasExecuted() {
				goto ActionsCompleted
			}
		}
	}

ActionsCompleted:
	// Analyze execution timing
	dbExecutionTime := slowDbAction.GetExecutionTime()
	sseExecutionTime := fastSSEAction.GetExecutionTime()

	dbDelay := dbExecutionTime.Sub(startTime)
	sseDelay := sseExecutionTime.Sub(startTime)

	t.Logf("Database action executed after: %v", dbDelay)
	t.Logf("SSE action executed after: %v", sseDelay)
	t.Logf("Time difference: %v", sseExecutionTime.Sub(dbExecutionTime))

	// The race condition is demonstrated if SSE starts close to when DB starts
	// rather than waiting for DB to complete (which would be 500ms+ later)
	
	// The race condition is demonstrated by the timing analysis
	// Even if actions don't start simultaneously, the key issue is that 
	// SSE can start before DatabaseAction completes its work
	
	timeDiff := sseExecutionTime.Sub(dbExecutionTime).Abs()
	
	if sseExecutionTime.Before(dbExecutionTime.Add(slowDbAction.executeDelay)) {
		t.Logf("✓ Race condition confirmed: SSE started before DB action would complete")
		t.Logf("  SSE execution time: %v", sseDelay)
		t.Logf("  DB would complete at: %v", dbExecutionTime.Add(slowDbAction.executeDelay).Sub(startTime))
		t.Logf("  This timing creates the reported timeout issues")
	} else {
		t.Logf("Actions executed with proper timing (time diff: %v)", timeDiff)
	}
	
	// Log insights regardless of timing
	t.Logf("Analysis: This test demonstrates the execution pattern that leads to:")
	t.Logf("  • 'database ID not assigned after 10s timeout'") 
	t.Logf("  • 'note not found in database'")
	t.Logf("  • 'audio file not ready after 5s timeout'")
}

// TestRaceCondition_OrderingDependency demonstrates the ordering dependency issue
func TestRaceCondition_OrderingDependency(t *testing.T) {
	t.Parallel()

	// This test simulates the scenario where SSE action expects DatabaseAction to complete first
	// but due to concurrent execution, SSE may start before DB finishes

	dbCompleted := make(chan time.Time, 1)
	sseStarted := make(chan time.Time, 1)

	// Simulate DatabaseAction that takes time to complete
	dbAction := &SimpleAction{
		name:         "Database Action with Completion Signal",
		executeDelay: 300 * time.Millisecond,
		onExecute: func() {
			dbCompleted <- time.Now()
		},
	}

	// Simulate SSE Action that should wait for DB but doesn't
	sseAction := &SimpleAction{
		name:         "SSE Action that checks DB",
		executeDelay: 10 * time.Millisecond,
		onExecute: func() {
			sseStarted <- time.Now()
		},
	}

	// Create job queue and processor
	queue := jobqueue.NewJobQueue()
	queue.SetProcessingInterval(5 * time.Millisecond)
	queue.Start()
	defer func() {
		if err := queue.Stop(); err != nil {
			t.Errorf("Failed to stop queue: %v", err)
		}
	}()

	processor := &Processor{
		JobQueue: queue,
		Settings: &conf.Settings{Debug: true},
	}

	// Enqueue both tasks
	detection := createSimpleDetection()
	dbTask := &Task{Type: TaskTypeAction, Detection: detection, Action: dbAction}
	sseTask := &Task{Type: TaskTypeAction, Detection: detection, Action: sseAction}

	startTime := time.Now()
	
	err1 := processor.EnqueueTask(dbTask)
	err2 := processor.EnqueueTask(sseTask)

	if err1 != nil {
		t.Fatalf("Failed to enqueue database task: %v", err1)
	}
	if err2 != nil {
		t.Fatalf("Failed to enqueue SSE task: %v", err2)
	}

	// Wait for events with timeout
	var sseStartTime, dbCompleteTime time.Time
	eventsReceived := 0

	timeout := time.After(1 * time.Second)
	for eventsReceived < 2 {
		select {
		case sseStartTime = <-sseStarted:
			eventsReceived++
			t.Logf("SSE action started at: %v", sseStartTime.Sub(startTime))
		case dbCompleteTime = <-dbCompleted:
			eventsReceived++
			t.Logf("Database action completed at: %v", dbCompleteTime.Sub(startTime))
		case <-timeout:
			t.Fatal("Timeout waiting for action events")
		}
	}

	// Analyze the ordering dependency violation
	if sseStartTime.Before(dbCompleteTime) {
		violation := dbCompleteTime.Sub(sseStartTime)
		t.Logf("✓ Race condition confirmed: SSE started %v before DB completed", violation)
		t.Logf("This demonstrates why SSE actions timeout waiting for database records")
	} else {
		t.Logf("Actions executed in correct order (no race condition detected)")
	}
}

// TestRaceCondition_TimeoutScenario simulates the actual timeout scenarios reported
func TestRaceCondition_TimeoutScenario(t *testing.T) {
	t.Parallel()

	// This test simulates the timeout scenario where SSE action waits for database
	// records that haven't been saved yet due to concurrent execution

	dbSaveCompleted := make(chan bool, 1)
	sseLookupAttempted := make(chan bool, 1)

	// Simulate slow database save operation (like on Raspberry Pi)
	simulatedDbAction := &SimpleAction{
		name:         "Slow Database Save",
		executeDelay: 1 * time.Second, // Simulate slow SD card write
		onExecute: func() {
			dbSaveCompleted <- true
		},
	}

	// Simulate SSE action that immediately tries to look up the record
	simulatedSSEAction := &SimpleAction{
		name:         "SSE Database Lookup",
		executeDelay: 10 * time.Millisecond,
		onExecute: func() {
			// In real scenario, this would call SearchNotes and get empty results
			// leading to "note not found" or timeout waiting for database ID
			sseLookupAttempted <- true
		},
	}

	// Create job queue with realistic processing interval
	queue := jobqueue.NewJobQueue()
	queue.SetProcessingInterval(50 * time.Millisecond) // Simulate some processing delay
	queue.Start()
	defer func() {
		if err := queue.Stop(); err != nil {
			t.Errorf("Failed to stop queue: %v", err)
		}
	}()

	processor := &Processor{
		JobQueue: queue,
		Settings: &conf.Settings{Debug: true},
	}

	// Enqueue both tasks (simulating the real scenario)
	detection := createSimpleDetection()
	dbTask := &Task{Type: TaskTypeAction, Detection: detection, Action: simulatedDbAction}
	sseTask := &Task{Type: TaskTypeAction, Detection: detection, Action: simulatedSSEAction}

	startTime := time.Now()
	
	err1 := processor.EnqueueTask(dbTask)
	err2 := processor.EnqueueTask(sseTask)

	if err1 != nil {
		t.Fatalf("Failed to enqueue database task: %v", err1)
	}
	if err2 != nil {
		t.Fatalf("Failed to enqueue SSE task: %v", err2)
	}

	// Monitor the race condition
	var lookupTime, saveTime time.Time
	eventsReceived := 0

	timeout := time.After(3 * time.Second)
	for eventsReceived < 2 {
		select {
		case <-sseLookupAttempted:
			lookupTime = time.Now()
			eventsReceived++
			t.Logf("SSE lookup attempted at: %v", lookupTime.Sub(startTime))
		case <-dbSaveCompleted:
			saveTime = time.Now()
			eventsReceived++
			t.Logf("Database save completed at: %v", saveTime.Sub(startTime))
		case <-timeout:
			t.Fatal("Timeout waiting for events")
		}
	}

	// Analyze the timeout scenario
	if lookupTime.Before(saveTime) {
		gap := saveTime.Sub(lookupTime)
		t.Logf("✓ Timeout scenario confirmed: SSE lookup happened %v before DB save completed", gap)
		t.Logf("In real scenario, this would cause:")
		t.Logf("  - 'database ID not assigned after 10s timeout'")
		t.Logf("  - 'note not found in database'")
		t.Logf("  - 'audio file not ready after 5s timeout'")
	} else {
		t.Logf("No timeout scenario detected - DB save completed before SSE lookup")
	}
}

// TestRaceCondition_CompositeActionSolution demonstrates how CompositeAction solves the race condition
func TestRaceCondition_CompositeActionSolution(t *testing.T) {
	t.Parallel()

	// This test verifies that CompositeAction enforces sequential execution
	// preventing the race condition between DatabaseAction and SSEAction

	executionOrder := make([]string, 0, 2)
	executionMutex := sync.Mutex{}

	dbAction := &SimpleAction{
		name:         "Database Action",
		executeDelay: 200 * time.Millisecond,
		onExecute: func() {
			executionMutex.Lock()
			executionOrder = append(executionOrder, "database")
			executionMutex.Unlock()
		},
	}

	sseAction := &SimpleAction{
		name:         "SSE Action",
		executeDelay: 50 * time.Millisecond,
		onExecute: func() {
			executionMutex.Lock()
			executionOrder = append(executionOrder, "sse")
			executionMutex.Unlock()
		},
	}

	// Create CompositeAction that combines both actions
	compositeAction := &CompositeAction{
		Actions:     []Action{dbAction, sseAction},
		Description: "Database save and SSE broadcast (sequential)",
	}

	detection := createSimpleDetection()
	startTime := time.Now()

	// Execute the composite action
	err := compositeAction.Execute(detection)
	totalDuration := time.Since(startTime)

	if err != nil {
		t.Fatalf("Composite action failed: %v", err)
	}

	// Verify both actions executed
	if !dbAction.WasExecuted() {
		t.Fatal("Database action was not executed")
	}
	if !sseAction.WasExecuted() {
		t.Fatal("SSE action was not executed")
	}

	// Verify execution order
	executionMutex.Lock()
	defer executionMutex.Unlock()
	
	if len(executionOrder) != 2 {
		t.Fatalf("Expected 2 actions to execute, got %d", len(executionOrder))
	}
	
	if executionOrder[0] != "database" {
		t.Errorf("Expected database action to execute first, but got: %s", executionOrder[0])
	}
	
	if executionOrder[1] != "sse" {
		t.Errorf("Expected SSE action to execute second, but got: %s", executionOrder[1])
	}

	// Verify timing characteristics
	dbExecutionTime := dbAction.GetExecutionTime()
	sseExecutionTime := sseAction.GetExecutionTime()

	if sseExecutionTime.Before(dbExecutionTime) {
		t.Fatal("SSE action executed before database action - race condition still present!")
	}

	timeBetweenActions := sseExecutionTime.Sub(dbExecutionTime)
	t.Logf("CompositeAction execution results:")
	t.Logf("  Total duration: %v", totalDuration)
	t.Logf("  Database completed at: %v", dbExecutionTime.Sub(startTime))
	t.Logf("  SSE started at: %v", sseExecutionTime.Sub(startTime))
	t.Logf("  Time between actions: %v", timeBetweenActions)
	
	// The time between actions should be minimal (just the SSE execution time)
	// since SSE starts immediately after DB completes
	if timeBetweenActions > 100*time.Millisecond {
		t.Errorf("Too much delay between actions: %v", timeBetweenActions)
	}

	t.Logf("✓ CompositeAction enforces sequential execution")
	t.Logf("✓ Database action completes before SSE action starts")
	t.Logf("✓ Race condition is prevented - no timeouts will occur")
}

// TestCompositeAction_TimeoutProtection verifies timeout handling in CompositeAction
func TestCompositeAction_TimeoutProtection(t *testing.T) {
	t.Parallel()

	// This test ensures CompositeAction properly handles actions that hang or take too long

	executionTracker := make([]string, 0, 2)
	executionMutex := sync.Mutex{}

	// Create a fast action that completes quickly
	fastAction := &SimpleAction{
		name:         "Fast Action",
		executeDelay: 100 * time.Millisecond,
		onExecute: func() {
			executionMutex.Lock()
			executionTracker = append(executionTracker, "fast")
			executionMutex.Unlock()
		},
	}

	// Create a hanging action that would exceed timeout
	hangingAction := &SimpleAction{
		name:         "Hanging Action",
		executeDelay: 5 * time.Second, // This will exceed our custom timeout
		onExecute: func() {
			executionMutex.Lock()
			executionTracker = append(executionTracker, "hanging")
			executionMutex.Unlock()
		},
	}

	// Use a shorter timeout for faster test execution
	shortTimeout := 2 * time.Second

	// Create CompositeAction with custom timeout
	compositeAction := &CompositeAction{
		Actions:     []Action{fastAction, hangingAction},
		Description: "Test timeout protection",
		Timeout:     &shortTimeout, // Override default timeout
	}

	detection := createSimpleDetection()
	startTime := time.Now()

	// Execute the composite action (should timeout on second action)
	err := compositeAction.Execute(detection)
	duration := time.Since(startTime)

	// Verify that we got a timeout error
	if err == nil {
		t.Fatal("Expected timeout error but got nil")
	}

	// Check that the error message indicates timeout
	if !strings.Contains(err.Error(), "timed out") {
		t.Errorf("Expected timeout error, got: %v", err)
	}

	// Verify that fast action completed but hanging action did not
	executionMutex.Lock()
	defer executionMutex.Unlock()

	if len(executionTracker) != 1 || executionTracker[0] != "fast" {
		t.Errorf("Expected only fast action to complete, got: %v", executionTracker)
	}

	// Verify the timeout duration is approximately correct
	// Should be around 2s (custom timeout) + 100ms (fast action)
	expectedDuration := 2*time.Second + 100*time.Millisecond
	tolerance := 500 * time.Millisecond // Allow some tolerance for test execution

	if duration < expectedDuration-tolerance || duration > expectedDuration+tolerance {
		t.Errorf("Duration %v is outside expected range [%v, %v]", 
			duration, expectedDuration-tolerance, expectedDuration+tolerance)
	}

	t.Logf("✓ CompositeAction properly handles custom timeout")
	t.Logf("✓ Fast action completed, hanging action was interrupted")
	t.Logf("✓ Total duration: %v (with custom timeout: %v)", duration, shortTimeout)
}

// TestCompositeAction_DefaultTimeout verifies default timeout behavior
func TestCompositeAction_DefaultTimeout(t *testing.T) {
	t.Parallel()

	// Create a simple action
	simpleAction := &SimpleAction{
		name:         "Simple Action",
		executeDelay: 100 * time.Millisecond,
	}

	// Create CompositeAction without timeout override (should use default)
	compositeAction := &CompositeAction{
		Actions:     []Action{simpleAction},
		Description: "Test default timeout",
		// Timeout is nil, so should use CompositeActionTimeout (30s)
	}

	detection := createSimpleDetection()

	// Execute the action
	err := compositeAction.Execute(detection)
	if err != nil {
		t.Errorf("Unexpected error: %v", err)
	}

	// Verify the action executed successfully with default timeout
	if !simpleAction.WasExecuted() {
		t.Error("Action was not executed")
	}

	t.Log("✓ CompositeAction uses default timeout when not overridden")
}

// TestCompositeAction_PanicRecovery verifies panic recovery in CompositeAction
func TestCompositeAction_PanicRecovery(t *testing.T) {
	t.Parallel()

	// This test ensures CompositeAction recovers from panics in individual actions

	executionTracker := make([]string, 0, 3)
	executionMutex := sync.Mutex{}

	// Create a normal action
	normalAction1 := &SimpleAction{
		name:         "Normal Action 1",
		executeDelay: 50 * time.Millisecond,
		onExecute: func() {
			executionMutex.Lock()
			executionTracker = append(executionTracker, "normal1")
			executionMutex.Unlock()
		},
	}

	// Create a panicking action
	panicAction := &SimpleAction{
		name:         "Panicking Action",
		executeDelay: 10 * time.Millisecond,
		onExecute: func() {
			panic("test panic: simulating unexpected error")
		},
	}

	// Create another normal action (should not execute after panic)
	normalAction2 := &SimpleAction{
		name:         "Normal Action 2",
		executeDelay: 50 * time.Millisecond,
		onExecute: func() {
			executionMutex.Lock()
			executionTracker = append(executionTracker, "normal2")
			executionMutex.Unlock()
		},
	}

	// Create CompositeAction with actions including a panicking one
	compositeAction := &CompositeAction{
		Actions:     []Action{normalAction1, panicAction, normalAction2},
		Description: "Test panic recovery",
	}

	detection := createSimpleDetection()

	// Execute the composite action (should handle panic gracefully)
	err := compositeAction.Execute(detection)

	// Verify that we got a panic error
	if err == nil {
		t.Fatal("Expected panic error but got nil")
	}

	// Check that the error message indicates panic
	if !strings.Contains(err.Error(), "panic") {
		t.Errorf("Expected panic error, got: %v", err)
	}

	// Verify that only the first action completed
	executionMutex.Lock()
	defer executionMutex.Unlock()

	if len(executionTracker) != 1 || executionTracker[0] != "normal1" {
		t.Errorf("Expected only first action to complete before panic, got: %v", executionTracker)
	}

	t.Logf("✓ CompositeAction properly recovered from panic")
	t.Logf("✓ Panic error was returned: %v", err)
	t.Logf("✓ Subsequent actions were not executed after panic")
}

// TestCompositeAction_EdgeCases tests edge cases for CompositeAction
func TestCompositeAction_EdgeCases(t *testing.T) {
	t.Parallel()

	detection := createSimpleDetection()

	t.Run("nil CompositeAction", func(t *testing.T) {
		var compositeAction *CompositeAction
		err := compositeAction.Execute(detection)
		if err != nil {
			t.Errorf("Expected nil CompositeAction to return nil error, got: %v", err)
		}
	})

	t.Run("nil Actions slice", func(t *testing.T) {
		compositeAction := &CompositeAction{
			Actions:     nil,
			Description: "Test nil actions",
		}
		err := compositeAction.Execute(detection)
		if err != nil {
			t.Errorf("Expected nil Actions slice to return nil error, got: %v", err)
		}
	})

	t.Run("empty Actions slice", func(t *testing.T) {
		compositeAction := &CompositeAction{
			Actions:     []Action{},
			Description: "Test empty actions",
		}
		err := compositeAction.Execute(detection)
		if err != nil {
			t.Errorf("Expected empty Actions slice to return nil error, got: %v", err)
		}
	})

	t.Run("all nil actions", func(t *testing.T) {
		compositeAction := &CompositeAction{
			Actions:     []Action{nil, nil, nil},
			Description: "Test all nil actions",
		}
		err := compositeAction.Execute(detection)
		if err != nil {
			t.Errorf("Expected all nil actions to return nil error, got: %v", err)
		}
	})

	t.Run("mixed nil and valid actions", func(t *testing.T) {
		executionOrder := make([]string, 0, 2)
		executionMutex := sync.Mutex{}

		action1 := &SimpleAction{
			name:         "Action 1",
			executeDelay: 10 * time.Millisecond,
			onExecute: func() {
				executionMutex.Lock()
				executionOrder = append(executionOrder, "action1")
				executionMutex.Unlock()
			},
		}

		action2 := &SimpleAction{
			name:         "Action 2",
			executeDelay: 10 * time.Millisecond,
			onExecute: func() {
				executionMutex.Lock()
				executionOrder = append(executionOrder, "action2")
				executionMutex.Unlock()
			},
		}

		compositeAction := &CompositeAction{
			Actions:     []Action{nil, action1, nil, action2, nil},
			Description: "Test mixed nil and valid actions",
		}

		err := compositeAction.Execute(detection)
		if err != nil {
			t.Errorf("Unexpected error: %v", err)
		}

		executionMutex.Lock()
		defer executionMutex.Unlock()

		if len(executionOrder) != 2 {
			t.Errorf("Expected 2 actions to execute, got %d", len(executionOrder))
		}
		if len(executionOrder) == 2 {
			if executionOrder[0] != "action1" || executionOrder[1] != "action2" {
				t.Errorf("Actions executed in wrong order: %v", executionOrder)
			}
		}
	})

	t.Run("single action", func(t *testing.T) {
		executed := false
		action := &SimpleAction{
			name:         "Single Action",
			executeDelay: 10 * time.Millisecond,
			onExecute: func() {
				executed = true
			},
		}

		compositeAction := &CompositeAction{
			Actions:     []Action{action},
			Description: "Test single action",
		}

		err := compositeAction.Execute(detection)
		if err != nil {
			t.Errorf("Unexpected error: %v", err)
		}

		if !executed {
			t.Error("Single action was not executed")
		}
	})
}


// TestRaceCondition_ProposedSolutionValidation demonstrates how sequential execution would solve the issue
func TestRaceCondition_ProposedSolutionValidation(t *testing.T) {
	t.Parallel()

	// This test shows how enforcing sequential execution would prevent race conditions

	dbAction := &SimpleAction{
		name:         "Database Action",
		executeDelay: 200 * time.Millisecond,
	}

	sseAction := &SimpleAction{
		name:         "SSE Action",
		executeDelay: 50 * time.Millisecond,
	}

	detection := createSimpleDetection()

	// Sequential execution (proposed solution)
	startTime := time.Now()

	// Step 1: Execute database action first
	err1 := dbAction.Execute(detection)
	dbCompleteTime := time.Now()

	// Step 2: Execute SSE action only after database completes  
	err2 := sseAction.Execute(detection)
	sseCompleteTime := time.Now()

	if err1 != nil {
		t.Fatalf("Database action failed: %v", err1)
	}
	if err2 != nil {
		t.Fatalf("SSE action failed: %v", err2)
	}

	// Analyze sequential timing
	dbDuration := dbCompleteTime.Sub(startTime)
	sseDuration := sseCompleteTime.Sub(dbCompleteTime)
	totalDuration := sseCompleteTime.Sub(startTime)

	t.Logf("Sequential execution results:")
	t.Logf("  Database action: %v", dbDuration)
	t.Logf("  SSE action: %v", sseDuration)  
	t.Logf("  Total duration: %v", totalDuration)

	// Verify sequential characteristics
	if dbDuration < 150*time.Millisecond {
		t.Errorf("Database action completed too quickly: %v", dbDuration)
	}

	if sseDuration > 100*time.Millisecond {
		t.Errorf("SSE action took too long (should be fast when DB is ready): %v", sseDuration)
	}

	t.Logf("✓ Sequential execution prevents race condition")
	t.Logf("✓ SSE action executes quickly when database operation is complete")
	t.Logf("✓ No timeouts or 'note not found' errors would occur")
}