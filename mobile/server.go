// Package mobile provides gomobile-compatible bindings for cloudflared tunnel
// and a local HTTP file server.
package mobile

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// ServerState represents the current state of the local server
type ServerState int

const (
	ServerStopped ServerState = iota
	ServerStarting
	ServerRunning
	ServerError
)

func (s ServerState) String() string {
	switch s {
	case ServerStopped:
		return "stopped"
	case ServerStarting:
		return "starting"
	case ServerRunning:
		return "running"
	case ServerError:
		return "error"
	default:
		return "unknown"
	}
}

// RequestLog represents a logged HTTP request
type RequestLog struct {
	Timestamp   string            `json:"timestamp"`
	Method      string            `json:"method"`
	Path        string            `json:"path"`
	RemoteAddr  string            `json:"remoteAddr"`
	UserAgent   string            `json:"userAgent"`
	ContentType string            `json:"contentType"`
	Headers     map[string]string `json:"headers"`
	Query       map[string]string `json:"query"`
	Body        string            `json:"body"`
	StatusCode  int               `json:"statusCode"`
	Duration    int64             `json:"durationMs"`
}

// ServerCallback is the interface for receiving server events
type ServerCallback interface {
	OnServerStateChanged(state int, message string)
	OnRequestLog(logJson string)
	OnServerError(code int, message string)
}

// LocalServer represents a local HTTP file server
type LocalServer struct {
	mu         sync.RWMutex
	server     *http.Server
	rootDir    string
	port       int
	state      ServerState
	callback   ServerCallback
	ctx        context.Context
	cancel     context.CancelFunc
	requestLog []RequestLog
	maxLogs    int
}

var (
	globalServer *LocalServer
	serverMu     sync.Mutex
)

// NewLocalServer creates a new local HTTP server instance
func NewLocalServer(rootDir string, port int, callback ServerCallback) (*LocalServer, error) {
	// Validate root directory
	info, err := os.Stat(rootDir)
	if err != nil {
		return nil, fmt.Errorf("invalid root directory: %w", err)
	}
	if !info.IsDir() {
		return nil, fmt.Errorf("path is not a directory: %s", rootDir)
	}

	// Validate port
	if port < 1 || port > 65535 {
		return nil, fmt.Errorf("invalid port: %d", port)
	}

	return &LocalServer{
		rootDir:    rootDir,
		port:       port,
		callback:   callback,
		state:      ServerStopped,
		requestLog: make([]RequestLog, 0),
		maxLogs:    1000, // Keep last 1000 logs
	}, nil
}

// Start starts the local HTTP server
func (s *LocalServer) Start() error {
	s.mu.Lock()
	if s.state == ServerRunning {
		s.mu.Unlock()
		return fmt.Errorf("server is already running")
	}

	s.ctx, s.cancel = context.WithCancel(context.Background())
	s.state = ServerStarting
	s.mu.Unlock()

	s.notifyState(ServerStarting, "Starting server...")

	// Create HTTP handler with logging middleware
	handler := s.createHandler()

	s.server = &http.Server{
		Addr:         fmt.Sprintf(":%d", s.port),
		Handler:      handler,
		ReadTimeout:  30 * time.Second,
		WriteTimeout: 30 * time.Second,
		IdleTimeout:  60 * time.Second,
	}

	// Start server in goroutine
	errCh := make(chan error, 1)
	go func() {
		if err := s.server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			errCh <- err
		}
		close(errCh)
	}()

	// Wait a bit to check if server started successfully
	select {
	case err := <-errCh:
		s.mu.Lock()
		s.state = ServerError
		s.mu.Unlock()
		s.notifyState(ServerError, err.Error())
		return err
	case <-time.After(100 * time.Millisecond):
		s.mu.Lock()
		s.state = ServerRunning
		s.mu.Unlock()
		s.notifyState(ServerRunning, fmt.Sprintf("Server running on port %d, serving: %s", s.port, s.rootDir))
	}

	// Monitor for errors
	go func() {
		select {
		case err := <-errCh:
			if err != nil {
				s.mu.Lock()
				s.state = ServerError
				s.mu.Unlock()
				s.notifyState(ServerError, err.Error())
			}
		case <-s.ctx.Done():
		}
	}()

	return nil
}

// Stop stops the local HTTP server
func (s *LocalServer) Stop() error {
	s.mu.Lock()
	if s.state != ServerRunning {
		s.mu.Unlock()
		return nil
	}
	s.mu.Unlock()

	if s.cancel != nil {
		s.cancel()
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	if s.server != nil {
		if err := s.server.Shutdown(ctx); err != nil {
			return err
		}
	}

	s.mu.Lock()
	s.state = ServerStopped
	s.mu.Unlock()

	s.notifyState(ServerStopped, "Server stopped")
	return nil
}

// GetState returns the current server state
func (s *LocalServer) GetState() int {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return int(s.state)
}

// GetPort returns the server port
func (s *LocalServer) GetPort() int {
	return s.port
}

// GetRootDir returns the root directory
func (s *LocalServer) GetRootDir() string {
	return s.rootDir
}

// GetRequestLogs returns all logged requests as JSON
func (s *LocalServer) GetRequestLogs() string {
	s.mu.RLock()
	defer s.mu.RUnlock()

	data, err := json.Marshal(s.requestLog)
	if err != nil {
		return "[]"
	}
	return string(data)
}

// ClearRequestLogs clears all logged requests
func (s *LocalServer) ClearRequestLogs() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.requestLog = make([]RequestLog, 0)
}

func (s *LocalServer) createHandler() http.Handler {
	// Create file server
	fileServer := http.FileServer(http.Dir(s.rootDir))

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()

		// Create response wrapper to capture status code
		wrapper := &responseWrapper{ResponseWriter: w, statusCode: 200}

		// Read body for logging (if not too large)
		var bodyStr string
		if r.Body != nil && r.ContentLength > 0 && r.ContentLength < 10*1024 { // Max 10KB
			body, err := io.ReadAll(r.Body)
			if err == nil {
				bodyStr = string(body)
				// Restore body for potential further use
				r.Body = io.NopCloser(strings.NewReader(bodyStr))
			}
		}

		// Serve the request
		fileServer.ServeHTTP(wrapper, r)

		// Log the request
		duration := time.Since(start)
		s.logRequest(r, wrapper.statusCode, duration, bodyStr)
	})
}

func (s *LocalServer) logRequest(r *http.Request, statusCode int, duration time.Duration, body string) {
	// Build headers map
	headers := make(map[string]string)
	for key, values := range r.Header {
		headers[key] = strings.Join(values, ", ")
	}

	// Build query params map
	query := make(map[string]string)
	for key, values := range r.URL.Query() {
		query[key] = strings.Join(values, ", ")
	}

	log := RequestLog{
		Timestamp:   time.Now().Format(time.RFC3339),
		Method:      r.Method,
		Path:        r.URL.Path,
		RemoteAddr:  r.RemoteAddr,
		UserAgent:   r.UserAgent(),
		ContentType: r.Header.Get("Content-Type"),
		Headers:     headers,
		Query:       query,
		Body:        body,
		StatusCode:  statusCode,
		Duration:    duration.Milliseconds(),
	}

	// Store log
	s.mu.Lock()
	s.requestLog = append(s.requestLog, log)
	// Trim old logs if needed
	if len(s.requestLog) > s.maxLogs {
		s.requestLog = s.requestLog[len(s.requestLog)-s.maxLogs:]
	}
	s.mu.Unlock()

	// Notify callback
	if s.callback != nil {
		logJson, err := json.Marshal(log)
		if err == nil {
			s.callback.OnRequestLog(string(logJson))
		}
	}
}

func (s *LocalServer) notifyState(state ServerState, message string) {
	if s.callback != nil {
		s.callback.OnServerStateChanged(int(state), message)
	}
}

// responseWrapper wraps http.ResponseWriter to capture status code
type responseWrapper struct {
	http.ResponseWriter
	statusCode int
}

func (w *responseWrapper) WriteHeader(code int) {
	w.statusCode = code
	w.ResponseWriter.WriteHeader(code)
}

// ============================================================================
// Static functions for gomobile binding
// ============================================================================

// StartLocalServer starts a local HTTP file server
func StartLocalServer(rootDir string, port int, callback ServerCallback) error {
	serverMu.Lock()
	defer serverMu.Unlock()

	if globalServer != nil {
		state := globalServer.GetState()
		if state == int(ServerRunning) {
			return fmt.Errorf("server is already running")
		}
	}

	server, err := NewLocalServer(rootDir, port, callback)
	if err != nil {
		return err
	}

	globalServer = server
	return server.Start()
}

// StopLocalServer stops the local HTTP server
func StopLocalServer() error {
	serverMu.Lock()
	defer serverMu.Unlock()

	if globalServer == nil {
		return nil
	}

	err := globalServer.Stop()
	globalServer = nil
	return err
}

// GetLocalServerState returns the current server state
func GetLocalServerState() int {
	serverMu.Lock()
	defer serverMu.Unlock()

	if globalServer == nil {
		return int(ServerStopped)
	}
	return globalServer.GetState()
}

// GetLocalServerPort returns the server port
func GetLocalServerPort() int {
	serverMu.Lock()
	defer serverMu.Unlock()

	if globalServer == nil {
		return 0
	}
	return globalServer.GetPort()
}

// GetLocalServerRootDir returns the root directory
func GetLocalServerRootDir() string {
	serverMu.Lock()
	defer serverMu.Unlock()

	if globalServer == nil {
		return ""
	}
	return globalServer.GetRootDir()
}

// GetLocalServerRequestLogs returns all logged requests as JSON
func GetLocalServerRequestLogs() string {
	serverMu.Lock()
	defer serverMu.Unlock()

	if globalServer == nil {
		return "[]"
	}
	return globalServer.GetRequestLogs()
}

// ClearLocalServerRequestLogs clears all logged requests
func ClearLocalServerRequestLogs() {
	serverMu.Lock()
	defer serverMu.Unlock()

	if globalServer != nil {
		globalServer.ClearRequestLogs()
	}
}

// IsLocalServerRunning returns true if the server is running
func IsLocalServerRunning() bool {
	serverMu.Lock()
	defer serverMu.Unlock()

	if globalServer == nil {
		return false
	}
	return globalServer.GetState() == int(ServerRunning)
}

// GetLocalServerURL returns the URL of the local server
func GetLocalServerURL() string {
	serverMu.Lock()
	defer serverMu.Unlock()

	if globalServer == nil || globalServer.GetState() != int(ServerRunning) {
		return ""
	}
	return fmt.Sprintf("http://127.0.0.1:%d", globalServer.GetPort())
}

// ListDirectory returns a JSON list of files in a directory
func ListDirectory(path string) (string, error) {
	info, err := os.Stat(path)
	if err != nil {
		return "", err
	}
	if !info.IsDir() {
		return "", fmt.Errorf("path is not a directory")
	}

	entries, err := os.ReadDir(path)
	if err != nil {
		return "", err
	}

	type FileInfo struct {
		Name    string `json:"name"`
		IsDir   bool   `json:"isDir"`
		Size    int64  `json:"size"`
		ModTime string `json:"modTime"`
	}

	files := make([]FileInfo, 0, len(entries))
	for _, entry := range entries {
		info, err := entry.Info()
		if err != nil {
			continue
		}
		files = append(files, FileInfo{
			Name:    entry.Name(),
			IsDir:   entry.IsDir(),
			Size:    info.Size(),
			ModTime: info.ModTime().Format(time.RFC3339),
		})
	}

	data, err := json.Marshal(files)
	if err != nil {
		return "", err
	}
	return string(data), nil
}

// GetAbsolutePath returns the absolute path of a relative path
func GetAbsolutePath(path string) (string, error) {
	return filepath.Abs(path)
}
