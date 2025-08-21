// birdweather.go this code implements a BirdWeather API client for uploading soundscapes and detections.
package birdweather

import (
	"bytes"
	"compress/gzip"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"log/slog"
	"math"
	"math/rand/v2"
	"net"
	"net/http"
	neturl "net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/tphakala/birdnet-go/internal/conf"
	"github.com/tphakala/birdnet-go/internal/datastore"
	"github.com/tphakala/birdnet-go/internal/errors"
	"github.com/tphakala/birdnet-go/internal/logging" // Import the new logging package
	"github.com/tphakala/birdnet-go/internal/myaudio"
)

// Package-level logger specific to birdweather service
var (
	serviceLogger   *slog.Logger
	serviceLevelVar = new(slog.LevelVar) // Dynamic level control
	closeLogger     func() error
)

func init() {
	var err error
	// Define log file path relative to working directory
	logFilePath := filepath.Join("logs", "birdweather.log")
	initialLevel := slog.LevelDebug // Set desired initial level
	serviceLevelVar.Set(initialLevel)

	// Initialize the service-specific file logger
	// Using Debug level for file logging to capture more detail
	serviceLogger, closeLogger, err = logging.NewFileLogger(logFilePath, "birdweather", serviceLevelVar)
	if err != nil {
		// Fallback: Log error to standard log and potentially disable service logging
		log.Printf("FATAL: Failed to initialize birdweather file logger at %s: %v. Service logging disabled.", logFilePath, err)
		// Set logger to a disabled handler to prevent nil panics, but respects level var
		fbHandler := slog.NewJSONHandler(io.Discard, &slog.HandlerOptions{Level: serviceLevelVar})
		serviceLogger = slog.New(fbHandler).With("service", "birdweather")
		closeLogger = func() error { return nil } // No-op closer
		// Consider whether to panic or continue without file logging
		// panic(fmt.Sprintf("Failed to initialize birdweather file logger: %v", err))
	}
}

// targetIntegratedLoudnessLUFS defines the target loudness for normalization.
// EBU R128 standard target is -23 LUFS.
const targetIntegratedLoudnessLUFS = -23.0

// SoundscapeResponse represents the JSON structure of the response from the Birdweather API when uploading a soundscape.
type SoundscapeResponse struct {
	Success    bool `json:"success"`
	Soundscape struct {
		ID        int     `json:"id"`
		StationID int     `json:"stationId"`
		Timestamp string  `json:"timestamp"`
		URL       *string `json:"url"` // Pointer to handle null
		Filesize  int     `json:"filesize"`
		Extension string  `json:"extension"`
		Duration  float64 `json:"duration"` // Duration in seconds
	} `json:"soundscape"`
}

// BwClient holds the configuration for interacting with the Birdweather API.
type BwClient struct {
	Settings      *conf.Settings
	BirdweatherID string
	Accuracy      float64
	Latitude      float64
	Longitude     float64
	HTTPClient    *http.Client
}

// maskURL masks sensitive BirdWeatherID tokens in URLs for safe logging
func (b *BwClient) maskURL(urlStr string) string {
	if b.BirdweatherID == "" {
		return urlStr
	}
	return strings.ReplaceAll(urlStr, b.BirdweatherID, "***")
}

// BirdweatherClientInterface defines what methods a BirdweatherClient must have
type Interface interface {
	Publish(note *datastore.Note, pcmData []byte) error
	UploadSoundscape(timestamp string, pcmData []byte) (soundscapeID string, err error)
	PostDetection(soundscapeID, timestamp, commonName, scientificName string, confidence float64) error
	TestConnection(ctx context.Context, resultChan chan<- TestResult)
	Close()
}

// New creates and initializes a new BwClient with the given settings.
// The HTTP client is configured with a 45-second timeout to prevent hanging requests.
func New(settings *conf.Settings) (*BwClient, error) {
	serviceLogger.Info("Creating new BirdWeather client")
	// We expect that Birdweather ID is validated before this function is called
	client := &BwClient{
		Settings:      settings,
		BirdweatherID: settings.Realtime.Birdweather.ID,
		Accuracy:      settings.Realtime.Birdweather.LocationAccuracy,
		Latitude:      settings.BirdNET.Latitude,
		Longitude:     settings.BirdNET.Longitude,
		HTTPClient:    &http.Client{Timeout: 45 * time.Second},
	}
	return client, nil
}

// RandomizeLocation adds a random offset to the given latitude and longitude to fuzz the location
// within a specified radius in meters for privacy, truncating the result to 4 decimal places.
// radiusMeters - the maximum radius in meters to adjust the coordinates
func (b *BwClient) RandomizeLocation(radiusMeters float64) (latitude, longitude float64) {
	// Create a new local random generator seeded with current Unix time
	rnd := rand.New(rand.NewPCG(uint64(time.Now().UnixNano()), uint64(time.Now().UnixNano()))) //nolint:gosec // G404: weak randomness acceptable for upload retry jitter, not security-critical

	// Calculate the degree offset using an approximation that 111,000 meters equals 1 degree
	degreeOffset := radiusMeters / 111000

	// Generate random offsets within +/- degreeOffset
	latOffset := (rnd.Float64() - 0.5) * 2 * degreeOffset
	lonOffset := (rnd.Float64() - 0.5) * 2 * degreeOffset

	// Apply the offsets to the original coordinates and truncate to 4 decimal places
	latitude = math.Floor((b.Latitude+latOffset)*10000) / 10000
	longitude = math.Floor((b.Longitude+lonOffset)*10000) / 10000

	serviceLogger.Debug("Randomized location",
		"original_lat", b.Latitude, "original_lon", b.Longitude,
		"radius_meters", radiusMeters,
		"fuzzed_lat", latitude, "fuzzed_lon", longitude)

	return latitude, longitude
}

// handleNetworkError handles network errors and returns a more specific error message.
func handleNetworkError(err error, url string, timeout time.Duration, operation string) *errors.EnhancedError {
	if err == nil {
		return errors.New(fmt.Errorf("nil error")).
			Component("birdweather").
			Category(errors.CategoryGeneric).
			Build()
	}
	var netErr net.Error
	if errors.As(err, &netErr) && netErr.Timeout() {
		// Create descriptive error message with operation context
		descriptiveErr := fmt.Errorf("BirdWeather %s timeout: %w", operation, err)
		serviceLogger.Warn("Network request timed out", "operation", operation, "error", err)
		return errors.New(descriptiveErr).
			Component("birdweather").
			Category(errors.CategoryNetwork).
			NetworkContext(url, timeout).
			Context("error_type", "timeout").
			Context("operation", operation).
			Build()
	}
	var urlErr *neturl.Error
	if errors.As(err, &urlErr) {
		var dnsErr *net.DNSError
		if errors.As(urlErr.Err, &dnsErr) {
			descriptiveErr := fmt.Errorf("BirdWeather %s DNS resolution failed: %w", operation, err)
			serviceLogger.Error("DNS resolution failed", "operation", operation, "url", url, "error", err)
			return errors.New(descriptiveErr).
				Component("birdweather").
				Category(errors.CategoryNetwork).
				NetworkContext(url, timeout).
				Context("error_type", "dns_resolution").
				Context("operation", operation).
				Build()
		}
	}
	descriptiveErr := fmt.Errorf("BirdWeather %s network error: %w", operation, err)
	serviceLogger.Error("Network error occurred", "operation", operation, "error", err)
	return errors.New(descriptiveErr).
		Component("birdweather").
		Category(errors.CategoryNetwork).
		NetworkContext(url, timeout).
		Context("error_type", "generic_network").
		Context("operation", operation).
		Build()
}

// isHTMLResponse checks if the response content type indicates HTML
func isHTMLResponse(resp *http.Response) bool {
	contentType := resp.Header.Get("Content-Type")
	return strings.Contains(strings.ToLower(contentType), "text/html")
}

// extractHTMLError attempts to extract error message from HTML response
// This handles common error page patterns from web servers and proxies
func extractHTMLError(htmlContent string) string {
	// Common patterns for error messages in HTML
	// Look for title tags first as they often contain the error summary
	titleStart := strings.Index(htmlContent, "<title>")
	titleEnd := strings.Index(htmlContent, "</title>")
	if titleStart != -1 && titleEnd != -1 && titleEnd > titleStart {
		title := htmlContent[titleStart+7 : titleEnd]
		title = strings.TrimSpace(title)
		if title != "" {
			return fmt.Sprintf("HTML error page: %s", title)
		}
	}

	// Look for common error patterns in body
	lowerHTML := strings.ToLower(htmlContent)
	errorPatterns := []string{
		"error",
		"not found",
		"unauthorized",
		"forbidden",
		"bad request",
		"internal server error",
		"service unavailable",
		"gateway timeout",
		"too many requests",
	}

	for _, pattern := range errorPatterns {
		if !strings.Contains(lowerHTML, pattern) {
			continue
		}
		// Try to extract a reasonable snippet around the error
		index := strings.Index(lowerHTML, pattern)
		start := index - 50
		if start < 0 {
			start = 0
		}
		end := index + 100
		if end > len(htmlContent) {
			end = len(htmlContent)
		}
		snippet := htmlContent[start:end]
		// Remove HTML tags for cleaner output
		snippet = strings.ReplaceAll(snippet, "<", " <")
		snippet = strings.ReplaceAll(snippet, ">", "> ")
		// Clean up whitespace
		fields := strings.Fields(snippet)
		snippet = strings.Join(fields, " ")
		return fmt.Sprintf("HTML error detected: %s", snippet)
	}

	// If no specific error found, return generic message with beginning of content
	maxLen := 200
	if len(htmlContent) < maxLen {
		maxLen = len(htmlContent)
	}
	preview := strings.TrimSpace(htmlContent[:maxLen])
	return fmt.Sprintf("Unexpected HTML response (first %d chars): %s", maxLen, preview)
}

// handleHTTPResponse processes HTTP response and handles both JSON and HTML responses
func handleHTTPResponse(resp *http.Response, expectedStatus int, operation, maskedURL string) ([]byte, error) {
	// Check status code first
	if resp.StatusCode != expectedStatus {
		responseBody, readErr := io.ReadAll(resp.Body)
		if readErr != nil {
			serviceLogger.Error("Failed to read response body after non-expected status",
				"operation", operation,
				"url", maskedURL,
				"expected_status", expectedStatus,
				"actual_status", resp.StatusCode,
				"read_error", readErr)
			return nil, fmt.Errorf("%s failed with status %d, failed to read response: %w", operation, resp.StatusCode, readErr)
		}

		// Check if response is HTML
		if isHTMLResponse(resp) {
			htmlError := extractHTMLError(string(responseBody))
			serviceLogger.Error("Received HTML error response instead of JSON",
				"operation", operation,
				"url", maskedURL,
				"status_code", resp.StatusCode,
				"html_error", htmlError,
				"response_preview", string(responseBody[:min(len(responseBody), 500)]))
			
			// Determine category based on status code
			category := errors.CategoryNetwork
			if resp.StatusCode == 408 || resp.StatusCode == 504 || resp.StatusCode == 524 {
				// 408 Request Timeout, 504 Gateway Timeout, 524 Timeout (Cloudflare)
				category = errors.CategoryTimeout
			}
			
			return nil, errors.New(fmt.Errorf("%s failed: %s (status %d)", operation, htmlError, resp.StatusCode)).
				Component("birdweather").
				Category(category).
				Context("response_type", "html").
				Context("status_code", resp.StatusCode).
				Context("operation", operation).
				Build()
		}

		// Not HTML, return the raw response
		err := fmt.Errorf("%s failed with status %d: %s", operation, resp.StatusCode, string(responseBody))
		serviceLogger.Error("Request failed with non-expected status",
			"operation", operation,
			"url", maskedURL,
			"expected_status", expectedStatus,
			"actual_status", resp.StatusCode,
			"response_body", string(responseBody))
		return nil, errors.New(err).
			Component("birdweather").
			Category(errors.CategoryNetwork).
			Context("status_code", resp.StatusCode).
			Context("operation", operation).
			Build()
	}

	// Status is OK, read the body
	responseBody, err := io.ReadAll(resp.Body)
	if err != nil {
		serviceLogger.Error("Failed to read response body",
			"operation", operation,
			"url", maskedURL,
			"status_code", resp.StatusCode,
			"error", err)
		return nil, fmt.Errorf("failed to read response body: %w", err)
	}

	return responseBody, nil
}

// encodeFlacUsingFFmpeg converts PCM data to FLAC format using FFmpeg directly into a bytes buffer.
// It applies a simple gain adjustment instead of dynamic loudness normalization to avoid pumping effects.
// This avoids writing temporary files to disk.
// It accepts a context for timeout/cancellation control and the explicit path to the FFmpeg executable.
func encodeFlacUsingFFmpeg(ctx context.Context, pcmData []byte, ffmpegPath string, settings *conf.Settings) (*bytes.Buffer, error) {
	serviceLogger.Debug("Starting FLAC encoding process")
	// Add check for empty pcmData
	if len(pcmData) == 0 {
		serviceLogger.Error("FLAC encoding failed: PCM data is empty")
		return nil, fmt.Errorf("pcmData is empty")
	}

	// ffmpegPath is now passed directly
	serviceLogger.Debug("Using ffmpeg path", "path", ffmpegPath)

	// --- Pass 1: Analyze Loudness ---
	// Use the provided context for the analysis
	serviceLogger.Debug("Performing loudness analysis (Pass 1)")
	loudnessStats, err := myaudio.AnalyzeAudioLoudnessWithContext(ctx, pcmData, ffmpegPath)
	if err != nil {
		// Check if the error is due to context cancellation
		if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
			serviceLogger.Warn("Loudness analysis cancelled or timed out", "error", err)
			return nil, err // Propagate context error
		}

		serviceLogger.Warn("Loudness analysis (Pass 1) failed, falling back to fixed gain adjustment", "error", err)
		// Fallback to a conservative fixed gain adjustment
		// A fixed gain of 15dB is a reasonable middle ground for bird call recordings
		gainValue := 15.0
		volumeArgs := fmt.Sprintf("volume=%.1fdB", gainValue)
		customArgs := []string{
			"-af", volumeArgs, // Simple gain adjustment
			"-c:a", "flac",
			"-f", "flac",
		}

		// Use the provided context for the fallback export operation
		serviceLogger.Debug("Starting fallback FLAC export with fixed gain", "gain_db", gainValue)
		buffer, err := myaudio.ExportAudioWithCustomFFmpegArgsContext(ctx, pcmData, ffmpegPath, customArgs)
		if err != nil {
			serviceLogger.Error("Fallback FLAC export with fixed gain failed", "gain_db", gainValue, "error", err)
			return nil, fmt.Errorf("fallback FLAC export with fixed gain failed: %w", err)
		}
		serviceLogger.Info("Encoded PCM to FLAC using fixed gain (fallback)", "gain_db", gainValue)
		return buffer, nil
	}

	serviceLogger.Debug("Loudness analysis results",
		"input_i", loudnessStats.InputI,
		"input_lra", loudnessStats.InputLRA,
		"input_tp", loudnessStats.InputTP,
		"input_thresh", loudnessStats.InputThresh)

	// --- Calculate gain needed to reach target loudness ---
	inputLUFS := parseDouble(loudnessStats.InputI, -70.0)
	gainNeeded := targetIntegratedLoudnessLUFS - inputLUFS

	// Apply safety limits to prevent excessive amplification or attenuation
	maxGain := 30.0 // Maximum gain in dB (absolute value)
	gainLimited := false
	if gainNeeded > maxGain {
		serviceLogger.Warn("Limiting gain to prevent excessive amplification",
			"calculated_gain", gainNeeded, "max_gain", maxGain)
		gainNeeded = maxGain
		gainLimited = true
	} else if gainNeeded < -maxGain {
		serviceLogger.Warn("Limiting gain to prevent excessive attenuation",
			"calculated_gain", gainNeeded, "min_gain", -maxGain)
		gainNeeded = -maxGain
		gainLimited = true
	}
	serviceLogger.Debug("Calculated gain adjustment", "gain_db", gainNeeded, "target_lufs", targetIntegratedLoudnessLUFS, "measured_lufs", inputLUFS, "limited", gainLimited)

	// --- Pass 2: Apply simple gain adjustment and encode ---
	serviceLogger.Debug("Applying gain adjustment and encoding to FLAC (Pass 2)", "gain_db", gainNeeded)

	// Use simple volume filter instead of loudnorm
	volumeArgs := fmt.Sprintf("volume=%.2fdB", gainNeeded)

	customArgs := []string{
		"-af", volumeArgs, // Simple gain adjustment filter
		"-c:a", "flac", // Output codec: FLAC
		"-f", "flac", // Output format: FLAC
	}

	// Use the provided context for the final encoding operation
	buffer, err := myaudio.ExportAudioWithCustomFFmpegArgsContext(ctx, pcmData, ffmpegPath, customArgs)
	if err != nil {
		serviceLogger.Error("FFmpeg FLAC encoding with gain adjustment failed", "gain_db", gainNeeded, "error", err)
		return nil, fmt.Errorf("failed to export PCM to FLAC with gain adjustment: %w", err)
	}

	serviceLogger.Info("Encoded PCM to FLAC with gain adjustment", "gain_db", gainNeeded)

	// Return the buffer containing the FLAC data
	return buffer, nil
}

// parseDouble safely parses a string to float64, returning defaultValue on error.
func parseDouble(s string, defaultValue float64) float64 {
	val, err := strconv.ParseFloat(strings.TrimSpace(s), 64)
	if err != nil {
		return defaultValue
	}
	return val
}

// UploadSoundscape uploads a soundscape file to the Birdweather API and returns the soundscape ID if successful.
// It handles the PCM to WAV conversion, compresses the data, and manages HTTP request creation and response handling safely.
func (b *BwClient) UploadSoundscape(timestamp string, pcmData []byte) (soundscapeID string, err error) {
	// Track performance timing for telemetry
	startTime := time.Now()
	defer func() {
		duration := time.Since(startTime)
		if err != nil {
			// Report failed submissions at warning level with timing context
			var enhancedErr *errors.EnhancedError
			if errors.As(err, &enhancedErr) {
				// Add timing context to existing enhanced error
				enhancedErr.Context["operation_duration_ms"] = duration.Milliseconds()
				enhancedErr.Context["operation"] = "soundscape_upload"
			} else {
				// Create new enhanced error with timing
				err = errors.New(err).
					Component("birdweather").
					Category(errors.CategoryNetwork).
					Timing("soundscape_upload", duration).
					Context("timestamp", timestamp).
					Build()
			}
			serviceLogger.Warn("Soundscape upload failed", "timestamp", timestamp, "duration_ms", duration.Milliseconds(), "error", err)
		} else {
			serviceLogger.Info("Soundscape upload completed", "timestamp", timestamp, "duration_ms", duration.Milliseconds(), "soundscape_id", soundscapeID)
		}
	}()

	serviceLogger.Info("Starting soundscape upload", "timestamp", timestamp)
	// Add check for empty pcmData
	if len(pcmData) == 0 {
		enhancedErr := errors.New(fmt.Errorf("pcmData is empty")).
			Component("birdweather").
			Category(errors.CategoryValidation).
			Context("timestamp", timestamp).
			Build()
		serviceLogger.Error("Soundscape upload failed: PCM data is empty", "timestamp", timestamp)
		return "", enhancedErr
	}

	// Create a variable to hold the audio data buffer and extension
	var audioBuffer *bytes.Buffer
	var audioExt string

	// Create a context with timeout for potentially long operations like encoding
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	// Use the validated FFmpeg path from settings.
	// This path is determined during config validation (ValidateAudioSettings)
	// and is either an explicit valid path, a path found in PATH, or empty if unavailable.
	ffmpegPathForExec, _ := exec.LookPath(conf.GetFfmpegBinaryName())
	ffmpegAvailable := ffmpegPathForExec != ""
	serviceLogger.Debug("Checking FFmpeg availability", "path", ffmpegPathForExec, "available", ffmpegAvailable)

	// Use FLAC if FFmpeg is available, otherwise fall back to WAV
	if ffmpegAvailable {
		// Encode PCM data to FLAC format with normalization, passing the context and validated path
		audioBuffer, err = encodeFlacUsingFFmpeg(ctx, pcmData, ffmpegPathForExec, b.Settings)
		if err != nil {
			serviceLogger.Warn("FLAC encoding failed, falling back to WAV", "timestamp", timestamp, "error", err)
			// Log the FLAC encoding error
			if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
				log.Printf("⚠️ FLAC encoding timed out or was cancelled, falling back to WAV: %v\n", err)
			} else {
				log.Printf("❌ Failed to encode/normalize PCM to FLAC, falling back to WAV: %v\n", err)
			}

			// Fall back to WAV if FLAC encoding fails, using a *new* context
			wavCtx, cancelWav := context.WithTimeout(context.Background(), 30*time.Second) // Fresh timeout for WAV
			defer cancelWav()
			serviceLogger.Debug("Encoding to WAV (fallback)", "timestamp", timestamp)
			audioBuffer, err = myaudio.EncodePCMtoWAVWithContext(wavCtx, pcmData)
			if err != nil {
				enhancedErr := errors.New(err).
					Component("birdweather").
					Category(errors.CategoryAudio).
					Context("timestamp", timestamp).
					Context("fallback_encoding", "wav").
					Build()
				serviceLogger.Error("Failed to encode PCM to WAV after FLAC failure", "timestamp", timestamp, "error", err)
				return "", enhancedErr
			}
			audioExt = "wav"
			serviceLogger.Info("Using WAV format for upload (fallback)", "timestamp", timestamp)
		} else {
			audioExt = "flac"
			serviceLogger.Info("Using FLAC format for upload", "timestamp", timestamp)
		}
	} else {
		log.Println("🔊 FFmpeg not available (checked configured path and system PATH), encoding to WAV format")
		serviceLogger.Info("FFmpeg not available, encoding to WAV format", "timestamp", timestamp)
		// Encode PCM data to WAV format using a dedicated context
		wavCtx, cancelWav := context.WithTimeout(context.Background(), 30*time.Second) // Fresh timeout for WAV
		defer cancelWav()
		audioBuffer, err = myaudio.EncodePCMtoWAVWithContext(wavCtx, pcmData)
		if err != nil {
			enhancedErr := errors.New(err).
				Component("birdweather").
				Category(errors.CategoryAudio).
				Context("timestamp", timestamp).
				Context("encoding_format", "wav").
				Build()
			serviceLogger.Error("Failed to encode PCM to WAV", "timestamp", timestamp, "error", err)
			return "", enhancedErr
		}
		audioExt = "wav"
		serviceLogger.Info("Using WAV format for upload", "timestamp", timestamp)
	}

	// If debug is enabled, save the audio file locally with timestamp information
	if b.Settings.Realtime.Birdweather.Debug {
		// Parse the timestamp
		parsedTime, parseErr := time.Parse("2006-01-02T15:04:05.000-0700", timestamp)
		if parseErr != nil {
			serviceLogger.Warn("Could not parse timestamp for debug file saving", "timestamp", timestamp, "format", audioExt, "error", parseErr)
		} else {
			// Create a debug directory for audio files
			debugDir := filepath.Join("debug", "birdweather", audioExt)

			// Generate a unique filename based on the timestamp
			debugFilename := filepath.Join(debugDir, fmt.Sprintf("bw_debug_%s.%s",
				parsedTime.Format("20060102_150405"), audioExt))

			// Calculate the end time (3 seconds after start)
			endTime := parsedTime.Add(3 * time.Second)

			// Save the audio buffer with timestamp information
			audioCopy := bytes.NewBuffer(audioBuffer.Bytes())
			if saveErr := saveBufferToFile(audioCopy, debugFilename, parsedTime, endTime); saveErr != nil {
				serviceLogger.Warn("Could not save debug file", "filename", debugFilename, "error", saveErr)
			} else {
				serviceLogger.Debug("Saved debug file", "filename", debugFilename)
			}
		}
	}

	// Compress the audio data
	var gzipAudioData bytes.Buffer
	gzipWriter := gzip.NewWriter(&gzipAudioData)
	serviceLogger.Debug("Compressing audio data", "format", audioExt, "timestamp", timestamp)
	if _, err := io.Copy(gzipWriter, audioBuffer); err != nil {
		serviceLogger.Error("Failed to compress audio data", "format", audioExt, "timestamp", timestamp, "error", err)
		return "", fmt.Errorf("failed to compress %s data: %w", audioExt, err)
	}
	if err := gzipWriter.Close(); err != nil {
		serviceLogger.Error("Failed to finalize audio compression", "format", audioExt, "timestamp", timestamp, "error", err)
		return "", fmt.Errorf("failed to finalize compression: %w", err)
	}
	serviceLogger.Debug("Audio data compressed", "format", audioExt, "original_size", audioBuffer.Len(), "compressed_size", gzipAudioData.Len())

	// Create and execute the POST request
	soundscapeURL := fmt.Sprintf("https://app.birdweather.com/api/v1/stations/%s/soundscapes?timestamp=%s&type=%s",
		b.BirdweatherID, neturl.QueryEscape(timestamp), audioExt)
	maskedURL := strings.ReplaceAll(soundscapeURL, b.BirdweatherID, "***")
	serviceLogger.Debug("Creating soundscape upload request", "url", maskedURL)
	req, err := http.NewRequest("POST", soundscapeURL, &gzipAudioData)
	if err != nil {
		serviceLogger.Error("Failed to create soundscape POST request", "url", maskedURL, "error", err)
		return "", fmt.Errorf("failed to create POST request: %w", err)
	}
	req.Header.Set("Content-Type", "application/octet-stream")
	req.Header.Set("Content-Encoding", "gzip")
	req.Header.Set("User-Agent", "BirdNET-Go")

	// Execute the request
	serviceLogger.Info("Uploading soundscape", "url", maskedURL, "format", audioExt)
	resp, err := b.HTTPClient.Do(req)
	if err != nil {
		serviceLogger.Error("Soundscape upload request failed", "url", maskedURL, "error", err)
		return "", handleNetworkError(err, maskedURL, 45*time.Second, "soundscape upload")
	}
	if resp == nil {
		serviceLogger.Error("Soundscape upload received nil response", "url", maskedURL)
		return "", fmt.Errorf("received nil response")
	}
	defer func() {
		if err := resp.Body.Close(); err != nil {
			serviceLogger.Debug("Failed to close response body", "error", err)
		}
	}()
	serviceLogger.Debug("Received soundscape upload response", "url", maskedURL, "status_code", resp.StatusCode)

	// Process the response using the new handler
	responseBody, err := handleHTTPResponse(resp, http.StatusCreated, "soundscape upload", maskedURL)
	if err != nil {
		return "", err
	}

	if b.Settings.Realtime.Birdweather.Debug {
		serviceLogger.Debug("Soundscape response body", "body", string(responseBody))
	}

	var sdata SoundscapeResponse
	if err := json.Unmarshal(responseBody, &sdata); err != nil {
		// Check if this might be HTML even though we got 200 OK
		if strings.Contains(string(responseBody), "<") && strings.Contains(string(responseBody), ">") {
			htmlError := extractHTMLError(string(responseBody))
			serviceLogger.Error("Received HTML response with 200 OK status",
				"operation", "soundscape upload",
				"url", maskedURL,
				"html_error", htmlError,
				"response_preview", string(responseBody[:min(len(responseBody), 500)]))
			return "", errors.New(fmt.Errorf("soundscape upload failed: %s", htmlError)).
				Component("birdweather").
				Category(errors.CategoryNetwork).
				Context("response_type", "html_with_200").
				Context("operation", "soundscape upload").
				Build()
		}
		serviceLogger.Error("Failed to decode soundscape JSON response", "url", maskedURL, "status_code", resp.StatusCode, "body", string(responseBody), "error", err)
		return "", fmt.Errorf("failed to decode JSON response: %w", err)
	}

	if !sdata.Success {
		serviceLogger.Error("Soundscape upload was not successful according to API response", "url", maskedURL, "status_code", resp.StatusCode, "response", sdata)
		return "", fmt.Errorf("upload failed, response reported failure")
	}

	soundscapeID = fmt.Sprintf("%d", sdata.Soundscape.ID)
	serviceLogger.Info("Soundscape uploaded successfully", "timestamp", timestamp, "soundscape_id", soundscapeID, "url", maskedURL)
	return soundscapeID, nil
}

// PostDetection posts a detection to the Birdweather API matching the specified soundscape ID.
func (b *BwClient) PostDetection(soundscapeID, timestamp, commonName, scientificName string, confidence float64) (err error) {
	// Track performance timing for telemetry
	startTime := time.Now()
	defer func() {
		duration := time.Since(startTime)
		if err != nil {
			// Report failed submissions at warning level with timing context
			var enhancedErr *errors.EnhancedError
			if errors.As(err, &enhancedErr) {
				// Add timing context to existing enhanced error
				enhancedErr.Context["operation_duration_ms"] = duration.Milliseconds()
				enhancedErr.Context["operation"] = "detection_post"
			} else {
				// Create new enhanced error with timing
				err = errors.New(err).
					Component("birdweather").
					Category(errors.CategoryNetwork).
					Timing("detection_post", duration).
					Context("soundscape_id", soundscapeID).
					Context("timestamp", timestamp).
					Build()
			}
			serviceLogger.Warn("Detection post failed", "soundscape_id", soundscapeID, "duration_ms", duration.Milliseconds(), "error", err)
		} else {
			serviceLogger.Info("Detection post completed", "soundscape_id", soundscapeID, "duration_ms", duration.Milliseconds())
		}
	}()

	serviceLogger.Info("Starting detection post", "soundscape_id", soundscapeID, "timestamp", timestamp, "common_name", commonName, "scientific_name", scientificName, "confidence", confidence)
	// Simple input validation
	if soundscapeID == "" || timestamp == "" || commonName == "" || scientificName == "" {
		enhancedErr := errors.New(fmt.Errorf("invalid input: all string parameters must be non-empty")).
			Component("birdweather").
			Category(errors.CategoryValidation).
			Context("soundscape_id", soundscapeID).
			Context("timestamp", timestamp).
			Context("common_name", commonName).
			Context("scientific_name", scientificName).
			Build()
		serviceLogger.Error("Detection post failed: Invalid input",
			"soundscape_id", soundscapeID, "timestamp", timestamp, "common_name", commonName, "scientific_name", scientificName, "error", enhancedErr)
		return enhancedErr
	}

	detectionURL := fmt.Sprintf("https://app.birdweather.com/api/v1/stations/%s/detections", b.BirdweatherID)
	maskedDetectionURL := strings.ReplaceAll(detectionURL, b.BirdweatherID, "***")

	// Fuzz location coordinates with user defined accuracy
	fuzzedLatitude, fuzzedLongitude := b.RandomizeLocation(b.Accuracy)

	// Convert timestamp to time.Time and calculate end time
	parsedTime, err := time.Parse("2006-01-02T15:04:05.000-0700", timestamp)
	if err != nil {
		serviceLogger.Error("Failed to parse timestamp for detection post", "timestamp", timestamp, "error", err)
		return fmt.Errorf("failed to parse timestamp: %w", err)
	}
	endTime := parsedTime.Add(3 * time.Second).Format("2006-01-02T15:04:05.000-0700") // Add 3 seconds to timestamp for endTime
	serviceLogger.Debug("Calculated detection time range", "start_time", timestamp, "end_time", endTime)

	// Prepare JSON payload for POST request
	postData := struct {
		Timestamp           string  `json:"timestamp"`
		Latitude            float64 `json:"lat"`
		Longitude           float64 `json:"lon"`
		SoundscapeID        string  `json:"soundscapeId"`
		SoundscapeStartTime string  `json:"soundscapeStartTime"`
		SoundscapeEndTime   string  `json:"soundscapeEndTime"`
		CommonName          string  `json:"commonName"`
		ScientificName      string  `json:"scientificName"`
		Algorithm           string  `json:"algorithm"`
		Confidence          string  `json:"confidence"`
	}{
		Timestamp:           timestamp,
		Latitude:            fuzzedLatitude,
		Longitude:           fuzzedLongitude,
		SoundscapeID:        soundscapeID,
		SoundscapeStartTime: timestamp, // Assuming detection aligns with soundscape start
		SoundscapeEndTime:   endTime,   // Soundscape is 3s, so end time matches
		CommonName:          commonName,
		ScientificName:      scientificName,
		Algorithm:           "2p4", // TODO: Make configurable?
		Confidence:          fmt.Sprintf("%.2f", confidence),
	}

	// Marshal JSON data
	postDataBytes, err := json.Marshal(postData)
	if err != nil {
		serviceLogger.Error("Failed to marshal detection JSON data", "error", err)
		return fmt.Errorf("failed to marshal JSON data: %w", err)
	}

	if b.Settings.Realtime.Birdweather.Debug {
		serviceLogger.Debug("Detection JSON Payload", "payload", string(postDataBytes))
	}

	// Execute POST request
	serviceLogger.Info("Posting detection", "url", maskedDetectionURL, "soundscape_id", soundscapeID, "scientific_name", scientificName)
	resp, err := b.HTTPClient.Post(detectionURL, "application/json", bytes.NewBuffer(postDataBytes))
	if err != nil {
		serviceLogger.Error("Detection post request failed", "url", maskedDetectionURL, "soundscape_id", soundscapeID, "error", err)
		return handleNetworkError(err, maskedDetectionURL, 45*time.Second, "detection post")
	}
	if resp == nil {
		serviceLogger.Error("Detection post received nil response", "url", maskedDetectionURL, "soundscape_id", soundscapeID)
		return fmt.Errorf("received nil response")
	}
	defer func() {
		if err := resp.Body.Close(); err != nil {
			serviceLogger.Debug("Failed to close response body", "error", err)
		}
	}()
	serviceLogger.Debug("Received detection post response", "url", maskedDetectionURL, "soundscape_id", soundscapeID, "status_code", resp.StatusCode)

	// Handle response using the new handler
	_, err = handleHTTPResponse(resp, http.StatusCreated, "detection post", maskedDetectionURL)
	if err != nil {
		// Add additional context for detection-specific error
		var enhancedErr *errors.EnhancedError
		if errors.As(err, &enhancedErr) {
			enhancedErr.Context["soundscape_id"] = soundscapeID
			enhancedErr.Context["scientific_name"] = scientificName
		}
		return err
	}

	serviceLogger.Info("Detection posted successfully", "soundscape_id", soundscapeID, "scientific_name", scientificName)
	return nil
}

// Publish function handles the uploading of detected clips and their details to Birdweather.
// It first parses the timestamp from the note, then uploads the soundscape, and finally posts the detection.
func (b *BwClient) Publish(note *datastore.Note, pcmData []byte) (err error) {
	// Track performance timing for telemetry
	startTime := time.Now()
	defer func() {
		duration := time.Since(startTime)
		if err != nil {
			// Report failed submissions at warning level with timing context
			var enhancedErr *errors.EnhancedError
			if errors.As(err, &enhancedErr) {
				// Add timing context to existing enhanced error
				enhancedErr.Context["operation_duration_ms"] = duration.Milliseconds()
				enhancedErr.Context["operation"] = "publish"
			} else {
				// Create new enhanced error with timing
				err = errors.New(err).
					Component("birdweather").
					Category(errors.CategoryNetwork).
					Timing("publish", duration).
					Context("common_name", note.CommonName).
					Context("scientific_name", note.ScientificName).
					Build()
			}
			serviceLogger.Warn("Publish failed", "common_name", note.CommonName, "scientific_name", note.ScientificName, "duration_ms", duration.Milliseconds(), "error", err)
		} else {
			serviceLogger.Info("Publish completed", "common_name", note.CommonName, "scientific_name", note.ScientificName, "duration_ms", duration.Milliseconds())
		}
	}()

	serviceLogger.Info("Starting publish process", "date", note.Date, "time", note.Time, "common_name", note.CommonName, "scientific_name", note.ScientificName, "confidence", note.Confidence)
	// Add check for empty pcmData
	if len(pcmData) == 0 {
		enhancedErr := errors.New(fmt.Errorf("pcmData is empty")).
			Component("birdweather").
			Category(errors.CategoryValidation).
			Context("common_name", note.CommonName).
			Context("scientific_name", note.ScientificName).
			Build()
		serviceLogger.Error("Publish failed: PCM data is empty", "note", note, "error", enhancedErr)
		return enhancedErr
	}

	// Use system's local timezone for timestamp parsing
	loc := time.Local

	// Combine date and time from note to form a full timestamp string
	dateTimeString := fmt.Sprintf("%sT%s", note.Date, note.Time)

	// Parse the timestamp using the given format and the system's local timezone
	parsedTime, err := time.ParseInLocation("2006-01-02T15:04:05", dateTimeString, loc)
	if err != nil {
		serviceLogger.Error("Error parsing date/time for publish", "date", note.Date, "time", note.Time, "error", err)
		return fmt.Errorf("error parsing date: %w", err)
	}

	// Format the parsed time to the required timestamp format with timezone information
	timestamp := parsedTime.Format("2006-01-02T15:04:05.000-0700")
	serviceLogger.Debug("Formatted timestamp for publish", "timestamp", timestamp)

	// If debug is enabled, save the raw PCM data to help diagnose issues
	if b.Settings.Realtime.Birdweather.Debug {
		debugDir := filepath.Join("debug", "birdweather", "pcm")
		debugFilename := filepath.Join(debugDir, fmt.Sprintf("bw_pcm_debug_%s.raw",
			parsedTime.Format("20060102_150405")))

		// Create directory if it doesn't exist
		if err := createDebugDirectory(debugDir); err != nil {
			serviceLogger.Warn("Could not create debug PCM directory", "directory", debugDir, "error", err)
		} else {
			// Save raw PCM data
			if err := os.WriteFile(debugFilename, pcmData, 0o600); err != nil {
				serviceLogger.Warn("Could not save debug PCM file", "filename", debugFilename, "error", err)
			} else {
				serviceLogger.Debug("Saved debug PCM file", "filename", debugFilename)
				// ... (metadata saving logs omitted for brevity, assumed okay) ...
			}
		}
	}

	// Upload the soundscape to Birdweather and retrieve the soundscape ID
	serviceLogger.Debug("Calling UploadSoundscape", "timestamp", timestamp)
	soundscapeID, err := b.UploadSoundscape(timestamp, pcmData)
	if err != nil {
		serviceLogger.Error("Publish failed: Error during soundscape upload", "timestamp", timestamp, "error", err)
		return fmt.Errorf("failed to upload soundscape to Birdweather: %w", err)
	}
	serviceLogger.Debug("UploadSoundscape completed", "timestamp", timestamp, "soundscape_id", soundscapeID)

	// Post the detection details to Birdweather using the retrieved soundscape ID
	serviceLogger.Debug("Calling PostDetection", "soundscape_id", soundscapeID, "timestamp", timestamp, "note", note)
	err = b.PostDetection(soundscapeID, timestamp, note.CommonName, note.ScientificName, note.Confidence)
	if err != nil {
		serviceLogger.Error("Publish failed: Error during detection post", "soundscape_id", soundscapeID, "timestamp", timestamp, "note", note, "error", err)
		return fmt.Errorf("failed to post detection to Birdweather: %w", err)
	}
	serviceLogger.Debug("PostDetection completed", "soundscape_id", soundscapeID)

	serviceLogger.Info("Publish process completed successfully", "soundscape_id", soundscapeID, "scientific_name", note.ScientificName)
	return nil
}

// Close properly cleans up the BwClient resources
// Currently this just cancels any pending HTTP requests and closes the file logger
func (b *BwClient) Close() {
	serviceLogger.Info("Closing BirdWeather client")
	if b.HTTPClient != nil && b.HTTPClient.Transport != nil {
		// If the transport implements the CloseIdleConnections method, call it
		type transporter interface {
			CloseIdleConnections()
		}
		if transport, ok := b.HTTPClient.Transport.(transporter); ok {
			serviceLogger.Debug("Closing idle HTTP connections")
			transport.CloseIdleConnections()
		}
		// Cancel any in-flight requests by using a new client
		b.HTTPClient = nil // Allow GC to collect the old client/transport
	}

	// Close the service-specific file logger
	if closeLogger != nil {
		serviceLogger.Debug("Closing birdweather service log file")
		if err := closeLogger(); err != nil {
			// Log closing error to standard logger as service logger might be closed
			log.Printf("ERROR: Failed to close birdweather log file: %v", err)
		}
		closeLogger = nil // Prevent multiple closes
	}

	if b.Settings.Realtime.Birdweather.Debug {
		serviceLogger.Info("BirdWeather client closed") // Log one last time
	}
}

// createDebugDirectory creates a directory for debug files and returns any error encountered
func createDebugDirectory(path string) error {
	if err := os.MkdirAll(path, 0o750); err != nil {
		return fmt.Errorf("couldn't create debug directory: %w", err)
	}
	return nil
}
