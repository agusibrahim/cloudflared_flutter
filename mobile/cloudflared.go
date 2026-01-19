// Package mobile provides gomobile-compatible bindings for cloudflared tunnel.
// This package exposes static functions that can be called from Android/iOS.
package mobile

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"runtime/debug"
	"sync"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/collectors"
	"github.com/rs/zerolog"

	"github.com/cloudflare/cloudflared/client"
	"github.com/cloudflare/cloudflared/config"
	"github.com/cloudflare/cloudflared/connection"
	"github.com/cloudflare/cloudflared/edgediscovery"
	"github.com/cloudflare/cloudflared/edgediscovery/allregions"
	"github.com/cloudflare/cloudflared/features"
	"github.com/cloudflare/cloudflared/ingress"
	"github.com/cloudflare/cloudflared/ingress/origins"
	"github.com/cloudflare/cloudflared/orchestration"
	"github.com/cloudflare/cloudflared/signal"
	"github.com/cloudflare/cloudflared/supervisor"
	"github.com/cloudflare/cloudflared/tunnelrpc/pogs"
)

// metricsResetMu protects the metrics registry reset
var metricsResetMu sync.Mutex
var tunnelStartCount int

// resetPrometheusRegistry creates a fresh Prometheus registry and replaces the default one.
// This is necessary because cloudflared uses MustRegister() which panics on duplicate registration,
// and the Go runtime persists in mobile apps even after stopping the tunnel.
func resetPrometheusRegistry() {
	metricsResetMu.Lock()
	defer metricsResetMu.Unlock()

	tunnelStartCount++

	// Create a completely new registry
	newRegistry := prometheus.NewRegistry()

	// Register the default Go collectors that are normally registered
	newRegistry.MustRegister(collectors.NewGoCollector())
	newRegistry.MustRegister(collectors.NewProcessCollector(collectors.ProcessCollectorOpts{}))

	// Replace the default registerer and gatherer
	// This is a bit of a hack, but it's the only way to reset the registry
	// without modifying cloudflared source code
	prometheus.DefaultRegisterer = newRegistry
	prometheus.DefaultGatherer = newRegistry
}

// cleanupMetricsState is a wrapper for compatibility
func cleanupMetricsState() {
	resetPrometheusRegistry()
}

// init configures the DNS resolver to use Cloudflare's 1.1.1.1
// This is necessary on mobile where the default resolver may not work
func init() {
	net.DefaultResolver = &net.Resolver{
		PreferGo: true,
		Dial: func(ctx context.Context, network, address string) (net.Conn, error) {
			d := net.Dialer{
				Timeout: time.Second * 10,
			}
			// Use Cloudflare's 1.1.1.1 DNS
			return d.DialContext(ctx, "udp", "1.1.1.1:53")
		},
	}
}

// CloudFlare Origin SSL ECC Certificate Authority
// This is the CA that signs certificates for Cloudflare edge servers (quic.cftunnel.com, h2.cftunnel.com)
var cloudflareOriginECCCA = []byte(`-----BEGIN CERTIFICATE-----
MIICiTCCAi6gAwIBAgIUXZP3MWb8MKwBE1Qbawsp1sfA/Y4wCgYIKoZIzj0EAwIw
gY8xCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpDYWxpZm9ybmlhMRYwFAYDVQQHEw1T
YW4gRnJhbmNpc2NvMRkwFwYDVQQKExBDbG91ZEZsYXJlLCBJbmMuMTgwNgYDVQQL
Ey9DbG91ZEZsYXJlIE9yaWdpbiBTU0wgRUNDIENlcnRpZmljYXRlIEF1dGhvcml0
eTAeFw0xOTA4MjMyMTA4MDBaFw0yOTA4MTUxNzAwMDBaMIGPMQswCQYDVQQGEwJV
UzETMBEGA1UECBMKQ2FsaWZvcm5pYTEWMBQGA1UEBxMNU2FuIEZyYW5jaXNjbzEZ
MBcGA1UEChMQQ2xvdWRGbGFyZSwgSW5jLjE4MDYGA1UECxMvQ2xvdWRGbGFyZSBP
cmlnaW4gU1NMIEVDQyBDZXJ0aWZpY2F0ZSBBdXRob3JpdHkwWTATBgcqhkjOPQIB
BggqhkjOPQMBBwNCAASR+sGALuaGshnUbcxKry+0LEXZ4NY6JUAtSeA6g87K3jaA
xpIg9G50PokpfWkhbarLfpcZu0UAoYy2su0EhN7wo2YwZDAOBgNVHQ8BAf8EBAMC
AQYwEgYDVR0TAQH/BAgwBgEB/wIBAjAdBgNVHQ4EFgQUhTBdOypw1O3VkmcH/es5
tBoOOKcwHwYDVR0jBBgwFoAUhTBdOypw1O3VkmcH/es5tBoOOKcwCgYIKoZIzj0E
AwIDSQAwRgIhAKilfntP2ILGZjwajktkBtXE1pB4Y/fjAfLkIRUzrI15AiEA5UCL
XYZZ9m2c3fKwIenMMojL1eqydsgqj/wK4p5kagQ=
-----END CERTIFICATE-----`)

// CloudFlare Origin SSL RSA Certificate Authority
var cloudflareOriginRSACA = []byte(`-----BEGIN CERTIFICATE-----
MIIEADCCAuigAwIBAgIID+rOSdTGfGcwDQYJKoZIhvcNAQELBQAwgYsxCzAJBgNV
BAYTAlVTMRkwFwYDVQQKExBDbG91ZEZsYXJlLCBJbmMuMTQwMgYDVQQLEytDbG91
ZEZsYXJlIE9yaWdpbiBTU0wgQ2VydGlmaWNhdGUgQXV0aG9yaXR5MRYwFAYDVQQH
Ew1TYW4gRnJhbmNpc2NvMRMwEQYDVQQIEwpDYWxpZm9ybmlhMB4XDTE5MDgyMzIx
MDgwMFoXDTI5MDgxNTE3MDAwMFowgYsxCzAJBgNVBAYTAlVTMRkwFwYDVQQKExBD
bG91ZEZsYXJlLCBJbmMuMTQwMgYDVQQLEytDbG91ZEZsYXJlIE9yaWdpbiBTU0wg
Q2VydGlmaWNhdGUgQXV0aG9yaXR5MRYwFAYDVQQHEw1TYW4gRnJhbmNpc2NvMRMw
EQYDVQQIEwpDYWxpZm9ybmlhMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKC
AQEAwEiVZ/UoQpHmFsHvk5isBxRehukP8DG9JhFev3WZtG76WoTthvLJFRKFCHXm
V6Z5/66Z4S09mgsUuFwvJzMnE6Ej6yIsYNCb9r9QORa8BdhrkNn6kdTly3mdnykb
OomnwbUfLlExVgNdlP0XoRoeMwbQ4598foiHblO2B/LKuNfJzAMfS7oZe34b+vLB
yrP/1bgCSLdc1AxQc1AC0EsQQhgcyTJNgnG4va1c7ogPlwKyhbDyZ4e59N5lbYPJ
SmXI/cAe3jXj1FBLJZkwnoDKe0v13xeF+nF32smSH0qB7aJX2tBMW4TWtFPmzs5I
lwrFSySWAdwYdgxw180yKU0dvwIDAQABo2YwZDAOBgNVHQ8BAf8EBAMCAQYwEgYD
VR0TAQH/BAgwBgEB/wIBAjAdBgNVHQ4EFgQUJOhTV118NECHqeuU27rhFnj8KaQw
HwYDVR0jBBgwFoAUJOhTV118NECHqeuU27rhFnj8KaQwDQYJKoZIhvcNAQELBQAD
ggEBAHwOf9Ur1l0Ar5vFE6PNrZWrDfQIMyEfdgSKofCdTckbqXNTiXdgbHs+TWoQ
wAB0pfJDAHJDXOTCWRyTeXOseeOi5Btj5CnEuw3P0oXqdqevM1/+uWp0CM35zgZ8
VD4aITxity0djzE6Qnx3Syzz+ZkoBgTnNum7d9A66/V636x4vTeqbZFBr9erJzgz
hhurjcoacvRNhnjtDRM0dPeiCJ50CP3wEYuvUzDHUaowOsnLCjQIkWbR7Ni6KEIk
MOz2U0OBSif3FTkhCgZWQKOOLo1P42jHC3ssUZAtVNXrCk3fw9/E15k8NPkBazZ6
0iykLhH1trywrKRMVw67F44IE8Y=
-----END CERTIFICATE-----`)

// CloudFlare Origin Pull Certificate Authority
var cloudflareOriginPullCA = []byte(`-----BEGIN CERTIFICATE-----
MIIGCjCCA/KgAwIBAgIIV5G6lVbCLmEwDQYJKoZIhvcNAQENBQAwgZAxCzAJBgNV
BAYTAlVTMRkwFwYDVQQKExBDbG91ZEZsYXJlLCBJbmMuMRQwEgYDVQQLEwtPcmln
aW4gUHVsbDEWMBQGA1UEBxMNU2FuIEZyYW5jaXNjbzETMBEGA1UECBMKQ2FsaWZv
cm5pYTEjMCEGA1UEAxMab3JpZ2luLXB1bGwuY2xvdWRmbGFyZS5uZXQwHhcNMTkx
MDEwMTg0NTAwWhcNMjkxMTAxMTcwMDAwWjCBkDELMAkGA1UEBhMCVVMxGTAXBgNV
BAoTEENsb3VkRmxhcmUsIEluYy4xFDASBgNVBAsTC09yaWdpbiBQdWxsMRYwFAYD
VQQHEw1TYW4gRnJhbmNpc2NvMRMwEQYDVQQIEwpDYWxpZm9ybmlhMSMwIQYDVQQD
ExpvcmlnaW4tcHVsbC5jbG91ZGZsYXJlLm5ldDCCAiIwDQYJKoZIhvcNAQEBBQAD
ggIPADCCAgoCggIBAN2y2zojYfl0bKfhp0AJBFeV+jQqbCw3sHmvEPwLmqDLqynI
42tZXR5y914ZB9ZrwbL/K5O46exd/LujJnV2b3dzcx5rtiQzso0xzljqbnbQT20e
ihx/WrF4OkZKydZzsdaJsWAPuplDH5P7J82q3re88jQdgE5hqjqFZ3clCG7lxoBw
hLaazm3NJJlUfzdk97ouRvnFGAuXd5cQVx8jYOOeU60sWqmMe4QHdOvpqB91bJoY
QSKVFjUgHeTpN8tNpKJfb9LIn3pun3bC9NKNHtRKMNX3Kl/sAPq7q/AlndvA2Kw3
Dkum2mHQUGdzVHqcOgea9BGjLK2h7SuX93zTWL02u799dr6Xkrad/WShHchfjjRn
aL35niJUDr02YJtPgxWObsrfOU63B8juLUphW/4BOjjJyAG5l9j1//aUGEi/sEe5
lqVv0P78QrxoxR+MMXiJwQab5FB8TG/ac6mRHgF9CmkX90uaRh+OC07XjTdfSKGR
PpM9hB2ZhLol/nf8qmoLdoD5HvODZuKu2+muKeVHXgw2/A6wM7OwrinxZiyBk5Hh
CvaADH7PZpU6z/zv5NU5HSvXiKtCzFuDu4/Zfi34RfHXeCUfHAb4KfNRXJwMsxUa
+4ZpSAX2G6RnGU5meuXpU5/V+DQJp/e69XyyY6RXDoMywaEFlIlXBqjRRA2pAgMB
AAGjZjBkMA4GA1UdDwEB/wQEAwIBBjASBgNVHRMBAf8ECDAGAQH/AgECMB0GA1Ud
DgQWBBRDWUsraYuA4REzalfNVzjann3F6zAfBgNVHSMEGDAWgBRDWUsraYuA4REz
alfNVzjann3F6zANBgkqhkiG9w0BAQ0FAAOCAgEAkQ+T9nqcSlAuW/90DeYmQOW1
QhqOor5psBEGvxbNGV2hdLJY8h6QUq48BCevcMChg/L1CkznBNI40i3/6heDn3IS
zVEwXKf34pPFCACWVMZxbQjkNRTiH8iRur9EsaNQ5oXCPJkhwg2+IFyoPAAYURoX
VcI9SCDUa45clmYHJ/XYwV1icGVI8/9b2JUqklnOTa5tugwIUi5sTfipNcJXHhgz
6BKYDl0/UP0lLKbsUETXeTGDiDpxZYIgbcFrRDDkHC6BSvdWVEiH5b9mH2BON60z
0O0j8EEKTwi9jnafVtZQXP/D8yoVowdFDjXcKkOPF/1gIh9qrFR6GdoPVgB3SkLc
5ulBqZaCHm563jsvWb/kXJnlFxW+1bsO9BDD6DweBcGdNurgmH625wBXksSdD7y/
fakk8DagjbjKShYlPEFOAqEcliwjF45eabL0t27MJV61O/jHzHL3dknXeE4BDa2j
bA+JbyJeUMtU7KMsxvx82RmhqBEJJDBCJ3scVptvhDMRrtqDBW5JShxoAOcpFQGm
iYWicn46nPDjgTU0bX1ZPpTpryXbvciVL5RkVBuyX2ntcOLDPlZWgxZCBp96x07F
AnOzKgZk4RzZPNAxCXERVxajn/FLcOhglVAKo5H0ac+AitlQ0ip55D2/mf8o72tM
fVQ6VpyjEXdiIXWUq/o=
-----END CERTIFICATE-----`)

// getMobileRootCAs returns a certificate pool with Cloudflare root CAs for mobile
// These are the same CAs from tlsconfig/cloudflare_ca.go used by cloudflared
func getMobileRootCAs() *x509.CertPool {
	pool := x509.NewCertPool()
	pool.AppendCertsFromPEM(cloudflareOriginECCCA)
	pool.AppendCertsFromPEM(cloudflareOriginRSACA)
	pool.AppendCertsFromPEM(cloudflareOriginPullCA)
	return pool
}

// Version information
const (
	Version   = "mobile-1.0.0"
	UserAgent = "cloudflared-mobile"
)

// TunnelState represents the current state of the tunnel
type TunnelState int

const (
	StateDisconnected TunnelState = iota
	StateConnecting
	StateConnected
	StateReconnecting
	StateError
)

func (s TunnelState) String() string {
	switch s {
	case StateDisconnected:
		return "disconnected"
	case StateConnecting:
		return "connecting"
	case StateConnected:
		return "connected"
	case StateReconnecting:
		return "reconnecting"
	case StateError:
		return "error"
	default:
		return "unknown"
	}
}

// TunnelCallback is the interface for receiving tunnel events.
// Implement this interface in your mobile app to receive callbacks.
type TunnelCallback interface {
	OnStateChanged(state int, message string)
	OnError(code int, message string)
	OnLog(level int, message string)
}

// TunnelConfig holds the configuration for a tunnel
type TunnelConfig struct {
	// Token is the base64-encoded tunnel token from Cloudflare dashboard
	Token string
	// OriginURL is the local URL to proxy traffic to (e.g., "http://localhost:8080")
	OriginURL string
	// HAConnections is the number of high availability connections (default: 4)
	HAConnections int
	// EnablePostQuantum enables post-quantum cryptography
	EnablePostQuantum bool
}

// Tunnel represents a running cloudflared tunnel instance
type Tunnel struct {
	mu             sync.RWMutex
	ctx            context.Context
	cancel         context.CancelFunc
	config         *TunnelConfig
	callback       TunnelCallback
	state          TunnelState
	lastError      error
	connectedAt    time.Time
	log            *zerolog.Logger
	graceShutdownC chan struct{}
}

var (
	// globalTunnel is the singleton tunnel instance
	globalTunnel *Tunnel
	tunnelMu     sync.Mutex
)

// callbackWriter is a custom io.Writer that sends log messages to the callback
type callbackWriter struct {
	callback TunnelCallback
}

func (w *callbackWriter) Write(p []byte) (n int, err error) {
	if w.callback != nil {
		w.callback.OnLog(1, string(p))
	}
	return len(p), nil
}

// logToCallback sends a log message to the callback
func logToCallback(callback TunnelCallback, level int, format string, args ...interface{}) {
	if callback != nil {
		msg := fmt.Sprintf(format, args...)
		callback.OnLog(level, msg)
	}
}

// parseToken decodes the base64 tunnel token
func parseToken(tokenStr string) (*connection.TunnelToken, error) {
	content, err := base64.StdEncoding.DecodeString(tokenStr)
	if err != nil {
		return nil, fmt.Errorf("failed to decode token: %w", err)
	}

	var token connection.TunnelToken
	if err := json.Unmarshal(content, &token); err != nil {
		return nil, fmt.Errorf("failed to parse token: %w", err)
	}

	return &token, nil
}

// NewTunnel creates a new Tunnel instance with the given configuration.
// Call Start() to begin the tunnel connection.
func NewTunnel(token string, originURL string, callback TunnelCallback) (*Tunnel, error) {
	if token == "" {
		return nil, errors.New("token is required")
	}

	config := &TunnelConfig{
		Token:         token,
		OriginURL:     originURL,
		HAConnections: 4,
	}

	// Create logger that sends to callback
	writer := &callbackWriter{callback: callback}
	logger := zerolog.New(writer).With().Timestamp().Logger()

	logToCallback(callback, 0, "[NewTunnel] Creating tunnel instance")
	logToCallback(callback, 0, "[NewTunnel] Token length: %d", len(token))
	logToCallback(callback, 0, "[NewTunnel] OriginURL: %s", originURL)

	t := &Tunnel{
		config:         config,
		callback:       callback,
		state:          StateDisconnected,
		log:            &logger,
		graceShutdownC: make(chan struct{}),
	}

	return t, nil
}

// Start begins the tunnel connection.
// This is a blocking call that will return when the tunnel is stopped.
func (t *Tunnel) Start() (err error) {
	t.logCallback(0, "[Start] Beginning tunnel start sequence")

	// Recover from any panics
	defer func() {
		if r := recover(); r != nil {
			stack := string(debug.Stack())
			errMsg := fmt.Sprintf("tunnel panic: %v\nStack trace:\n%s", r, stack)
			t.logCallback(2, "[Start] PANIC: %s", errMsg)
			err = fmt.Errorf("tunnel panic: %v", r)
			t.setError(err)
		}
		// Ensure we clean up state
		t.mu.Lock()
		t.state = StateDisconnected
		t.mu.Unlock()
		t.logCallback(0, "[Start] Tunnel stopped, state set to disconnected")
	}()

	t.mu.Lock()
	if t.state == StateConnecting || t.state == StateConnected {
		t.mu.Unlock()
		t.logCallback(1, "[Start] Tunnel already running, state: %v", t.state)
		return errors.New("tunnel is already running")
	}

	t.ctx, t.cancel = context.WithCancel(context.Background())
	t.state = StateConnecting
	t.graceShutdownC = make(chan struct{})
	t.mu.Unlock()

	t.logCallback(0, "[Start] State set to connecting")
	t.notifyState(StateConnecting, "Starting tunnel connection...")

	// Parse the token
	t.logCallback(0, "[Start] Parsing token...")
	token, err := parseToken(t.config.Token)
	if err != nil {
		t.logCallback(2, "[Start] Token parse error: %v", err)
		t.setError(err)
		return err
	}
	t.logCallback(0, "[Start] Token parsed successfully, TunnelID: %s", token.TunnelID)

	credentials := token.Credentials()
	t.logCallback(0, "[Start] Got credentials, AccountTag: %s", credentials.AccountTag)

	// Create tunnel properties
	namedTunnel := &connection.TunnelProperties{
		Credentials: credentials,
	}
	t.logCallback(0, "[Start] Created tunnel properties")

	// Run the tunnel
	t.logCallback(0, "[Start] Calling runTunnel...")
	err = t.runTunnel(namedTunnel)
	if err != nil {
		t.logCallback(2, "[Start] runTunnel returned error: %v", err)
	}

	t.notifyState(StateDisconnected, "Tunnel stopped")

	return err
}

// logCallback is a helper to log messages via callback
func (t *Tunnel) logCallback(level int, format string, args ...interface{}) {
	logToCallback(t.callback, level, format, args...)
}

func (t *Tunnel) runTunnel(namedTunnel *connection.TunnelProperties) error {
	ctx := t.ctx
	log := t.log

	t.logCallback(0, "[runTunnel] Starting runTunnel")

	// Nil checks
	if ctx == nil {
		t.logCallback(2, "[runTunnel] ERROR: context is nil")
		return errors.New("context is nil")
	}
	t.logCallback(0, "[runTunnel] context OK")

	if log == nil {
		t.logCallback(2, "[runTunnel] ERROR: logger is nil")
		return errors.New("logger is nil")
	}
	t.logCallback(0, "[runTunnel] logger OK")

	if namedTunnel == nil {
		t.logCallback(2, "[runTunnel] ERROR: namedTunnel is nil")
		return errors.New("namedTunnel is nil")
	}
	t.logCallback(0, "[runTunnel] namedTunnel OK")

	if namedTunnel.Credentials.AccountTag == "" {
		t.logCallback(2, "[runTunnel] ERROR: account tag is empty")
		return errors.New("account tag is empty")
	}
	t.logCallback(0, "[runTunnel] AccountTag: %s", namedTunnel.Credentials.AccountTag)

	t.logCallback(0, "[runTunnel] Creating feature selector...")
	t.notifyState(StateConnecting, "Creating feature selector...")

	// Create feature selector
	featureSelector, err := features.NewFeatureSelector(ctx, namedTunnel.Credentials.AccountTag, nil, t.config.EnablePostQuantum, log)
	if err != nil {
		t.logCallback(2, "[runTunnel] ERROR creating feature selector: %v", err)
		return fmt.Errorf("failed to create feature selector: %w", err)
	}
	if featureSelector == nil {
		t.logCallback(2, "[runTunnel] ERROR: feature selector is nil")
		return errors.New("feature selector is nil")
	}
	t.logCallback(0, "[runTunnel] Feature selector created OK")

	t.logCallback(0, "[runTunnel] Creating client config...")
	t.notifyState(StateConnecting, "Creating client config...")

	// Create client config
	clientConfig, err := client.NewConfig(Version, "mobile", featureSelector)
	if err != nil {
		t.logCallback(2, "[runTunnel] ERROR creating client config: %v", err)
		return fmt.Errorf("failed to create client config: %w", err)
	}
	if clientConfig == nil {
		t.logCallback(2, "[runTunnel] ERROR: client config is nil")
		return errors.New("client config is nil")
	}
	t.logCallback(0, "[runTunnel] Client config created, ConnectorID: %s", clientConfig.ConnectorID)

	log.Info().Msgf("Generated Connector ID: %s", clientConfig.ConnectorID)

	// Create tags
	tags := []pogs.Tag{
		{Name: "ID", Value: clientConfig.ConnectorID.String()},
		{Name: "platform", Value: "mobile"},
	}
	t.logCallback(0, "[runTunnel] Tags created")

	t.logCallback(0, "[runTunnel] Creating protocol selector...")
	t.notifyState(StateConnecting, "Creating protocol selector...")

	// Determine protocol - use a simpler approach that doesn't require DNS lookup
	protocolSelector, err := connection.NewProtocolSelector(
		connection.QUIC.String(), // Force QUIC protocol instead of auto-select
		namedTunnel.Credentials.AccountTag,
		true, // hasToken
		t.config.EnablePostQuantum,
		func() (edgediscovery.ProtocolPercents, error) {
			// Return default protocol percentages to avoid DNS lookup issues on mobile
			return edgediscovery.ProtocolPercents{
				{Protocol: "quic", Percentage: 100},
			}, nil
		},
		connection.ResolveTTL,
		log,
	)
	if err != nil {
		t.logCallback(2, "[runTunnel] ERROR creating protocol selector: %v", err)
		return fmt.Errorf("failed to create protocol selector: %w", err)
	}
	if protocolSelector == nil {
		t.logCallback(2, "[runTunnel] ERROR: protocol selector is nil")
		return errors.New("protocol selector is nil")
	}
	t.logCallback(0, "[runTunnel] Protocol selector created, current: %s", protocolSelector.Current())

	log.Info().Msgf("Initial protocol: %s", protocolSelector.Current())
	t.notifyState(StateConnecting, fmt.Sprintf("Using protocol: %s", protocolSelector.Current()))

	// Create TLS configs with embedded root CAs for mobile
	t.logCallback(0, "[runTunnel] Creating TLS configs...")
	t.notifyState(StateConnecting, "Creating TLS configs...")
	edgeTLSConfigs := make(map[connection.Protocol]*tls.Config)
	mobileRootCAs := getMobileRootCAs()
	t.logCallback(0, "[runTunnel] Loaded mobile root CAs")
	for _, p := range connection.ProtocolList {
		tlsSettings := p.TLSSettings()
		if tlsSettings == nil {
			continue
		}
		edgeTLSConfig := &tls.Config{
			ServerName: tlsSettings.ServerName,
			RootCAs:    mobileRootCAs, // Use embedded root CAs for mobile
			NextProtos: tlsSettings.NextProtos,
		}
		edgeTLSConfigs[p] = edgeTLSConfig
		t.logCallback(0, "[runTunnel] TLS config for %s: ServerName=%s", p, tlsSettings.ServerName)
	}
	t.logCallback(0, "[runTunnel] TLS configs created, count: %d", len(edgeTLSConfigs))

	// Create ingress rules
	// For remotely-managed tunnels (token-based), the ingress configuration
	// is fetched from the Cloudflare dashboard. We start with an empty ingress
	// and let the orchestrator update it from remote config.
	ingressRules := ingress.Ingress{}
	t.logCallback(0, "[runTunnel] Empty ingress rules created (will be fetched from dashboard)")

	t.logCallback(0, "[runTunnel] Creating origin services...")
	t.notifyState(StateConnecting, "Creating origin services...")

	// Create warp routing config
	t.logCallback(0, "[runTunnel] Creating warp routing config...")
	// Pass empty config instead of nil to avoid nil pointer dereference
	emptyWarpConfig := &config.WarpRoutingConfig{}
	warpRoutingConfig := ingress.NewWarpRoutingConfig(emptyWarpConfig)
	t.logCallback(0, "[runTunnel] Warp routing config created")

	// Create origin dialer service
	t.logCallback(0, "[runTunnel] Creating dialer...")
	dialer := ingress.NewDialer(warpRoutingConfig)
	if dialer == nil {
		t.logCallback(2, "[runTunnel] ERROR: dialer is nil")
		return errors.New("dialer is nil")
	}
	t.logCallback(0, "[runTunnel] Dialer created OK")

	t.logCallback(0, "[runTunnel] Creating origin dialer service...")
	originDialerService := ingress.NewOriginDialer(ingress.OriginConfig{
		DefaultDialer: dialer,
	}, log)
	if originDialerService == nil {
		t.logCallback(2, "[runTunnel] ERROR: origin dialer service is nil")
		return errors.New("origin dialer service is nil")
	}
	t.logCallback(0, "[runTunnel] Origin dialer service created OK")

	// Create DNS service and register it with the origin dialer
	t.logCallback(0, "[runTunnel] Creating DNS dialer...")
	dnsDialer := origins.NewDNSDialer()
	if dnsDialer == nil {
		t.logCallback(2, "[runTunnel] ERROR: DNS dialer is nil")
		return errors.New("DNS dialer is nil")
	}
	t.logCallback(0, "[runTunnel] DNS dialer created OK")

	t.logCallback(0, "[runTunnel] Creating DNS service...")
	dnsService := origins.NewDNSResolverService(dnsDialer, log, nil)
	if dnsService == nil {
		t.logCallback(2, "[runTunnel] ERROR: DNS service is nil")
		return errors.New("DNS service is nil")
	}
	t.logCallback(0, "[runTunnel] DNS service created OK")

	t.logCallback(0, "[runTunnel] Adding reserved service for DNS...")
	originDialerService.AddReservedService(dnsService, []netip.AddrPort{origins.VirtualDNSServiceAddr})
	t.logCallback(0, "[runTunnel] Reserved service added OK")

	// Create observer
	t.logCallback(0, "[runTunnel] Creating observer...")
	t.notifyState(StateConnecting, "Creating observer...")
	observer := connection.NewObserver(log, log)
	if observer == nil {
		t.logCallback(2, "[runTunnel] ERROR: observer is nil")
		return errors.New("observer is nil")
	}
	t.logCallback(0, "[runTunnel] Observer created OK")

	// HA connections
	haConnections := t.config.HAConnections
	if haConnections < 1 {
		haConnections = 4
	}
	t.logCallback(0, "[runTunnel] HA connections: %d", haConnections)

	t.logCallback(0, "[runTunnel] Creating tunnel config...")
	t.notifyState(StateConnecting, "Creating tunnel config...")

	// Create tunnel config
	tunnelConfig := &supervisor.TunnelConfig{
		ClientConfig:     clientConfig,
		GracePeriod:      30 * time.Second,
		EdgeAddrs:        nil,
		Region:           namedTunnel.Credentials.Endpoint,
		EdgeIPVersion:    allregions.Auto,
		EdgeBindAddr:     nil,
		HAConnections:    haConnections,
		IsAutoupdated:    false,
		LBPool:           "",
		Tags:             tags,
		Log:              log,
		LogTransport:     log,
		Observer:         observer,
		ReportedVersion:  Version,
		Retries:          5,
		RunFromTerminal:  false,
		NamedTunnel:      namedTunnel,
		ProtocolSelector: protocolSelector,
		EdgeTLSConfigs:   edgeTLSConfigs,
		MaxEdgeAddrRetries: 8,
		RPCTimeout:       5 * time.Second,
		WriteStreamTimeout: 0,
		DisableQUICPathMTUDiscovery: false,
		QUICConnectionLevelFlowControlLimit: 30 * (1 << 20),
		QUICStreamLevelFlowControlLimit:     6 * (1 << 20),
		OriginDNSService:     dnsService,
		OriginDialerService:  originDialerService,
	}

	t.logCallback(0, "[runTunnel] Tunnel config created OK")
	t.logCallback(0, "[runTunnel] Creating orchestrator...")
	t.notifyState(StateConnecting, "Creating orchestrator...")

	// Create orchestrator config
	orchestratorConfig := &orchestration.Config{
		Ingress:             &ingressRules,
		WarpRouting:         warpRoutingConfig,
		OriginDialerService: originDialerService,
		ConfigurationFlags:  make(map[string]string),
	}
	t.logCallback(0, "[runTunnel] Orchestrator config created")

	// Create orchestrator
	t.logCallback(0, "[runTunnel] Creating orchestrator instance...")
	orchestrator, err := orchestration.NewOrchestrator(ctx, orchestratorConfig, tags, nil, log)
	if err != nil {
		t.logCallback(2, "[runTunnel] ERROR creating orchestrator: %v", err)
		return fmt.Errorf("failed to create orchestrator: %w", err)
	}
	if orchestrator == nil {
		t.logCallback(2, "[runTunnel] ERROR: orchestrator is nil")
		return errors.New("orchestrator is nil")
	}
	t.logCallback(0, "[runTunnel] Orchestrator created OK")

	t.logCallback(0, "[runTunnel] Starting tunnel daemon...")
	t.notifyState(StateConnecting, "Starting tunnel daemon...")

	// Create reconnect channel
	reconnectCh := make(chan supervisor.ReconnectSignal, haConnections)
	t.logCallback(0, "[runTunnel] Reconnect channel created")

	// Create connected signal
	connectedSignal := signal.New(make(chan struct{}))
	t.logCallback(0, "[runTunnel] Connected signal created")

	// Watch for connection
	go func() {
		t.logCallback(0, "[runTunnel] Waiting for connected signal...")
		<-connectedSignal.Wait()
		t.logCallback(0, "[runTunnel] Connected signal received!")
		t.mu.Lock()
		t.state = StateConnected
		t.connectedAt = time.Now()
		t.mu.Unlock()
		t.notifyState(StateConnected, "Tunnel connected successfully")
	}()

	// Start the tunnel daemon
	t.logCallback(0, "[runTunnel] Calling StartTunnelDaemon...")
	err = supervisor.StartTunnelDaemon(ctx, tunnelConfig, orchestrator, connectedSignal, reconnectCh, t.graceShutdownC)
	if err != nil {
		t.logCallback(2, "[runTunnel] ERROR from StartTunnelDaemon: %v", err)
		return fmt.Errorf("tunnel daemon error: %w", err)
	}
	t.logCallback(0, "[runTunnel] StartTunnelDaemon returned without error")

	return nil
}

// Stop gracefully stops the tunnel
func (t *Tunnel) Stop() {
	t.mu.Lock()
	defer t.mu.Unlock()

	if t.cancel != nil {
		// Signal graceful shutdown
		close(t.graceShutdownC)
		t.cancel()
		t.cancel = nil
	}
	t.state = StateDisconnected
}

// GetState returns the current tunnel state
func (t *Tunnel) GetState() int {
	t.mu.RLock()
	defer t.mu.RUnlock()
	return int(t.state)
}

// GetStateString returns the current tunnel state as a string
func (t *Tunnel) GetStateString() string {
	t.mu.RLock()
	defer t.mu.RUnlock()
	return t.state.String()
}

// IsConnected returns true if the tunnel is connected
func (t *Tunnel) IsConnected() bool {
	t.mu.RLock()
	defer t.mu.RUnlock()
	return t.state == StateConnected
}

func (t *Tunnel) setError(err error) {
	t.mu.Lock()
	t.lastError = err
	t.state = StateError
	t.mu.Unlock()

	t.notifyState(StateError, err.Error())
	if t.callback != nil {
		t.callback.OnError(1, err.Error())
	}
}

func (t *Tunnel) notifyState(state TunnelState, message string) {
	if t.callback != nil {
		t.callback.OnStateChanged(int(state), message)
	}
	if t.log != nil {
		t.log.Info().Int("state", int(state)).Msg(message)
	}
}

// ============================================================================
// Static functions for gomobile binding (simpler API)
// ============================================================================

// StartTunnel is a simple static function to start a tunnel with a token.
// This blocks until the tunnel is stopped or encounters an error.
// Use StartTunnelAsync for non-blocking operation.
func StartTunnel(token string, originURL string) error {
	tunnelMu.Lock()
	if globalTunnel != nil {
		tunnelMu.Unlock()
		return errors.New("tunnel is already running")
	}

	tunnel, err := NewTunnel(token, originURL, nil)
	if err != nil {
		tunnelMu.Unlock()
		return err
	}
	globalTunnel = tunnel
	tunnelMu.Unlock()

	return tunnel.Start()
}

// StartTunnelWithCallback starts a tunnel with a callback for state updates.
// This blocks until the tunnel is stopped or encounters an error.
func StartTunnelWithCallback(token string, originURL string, callback TunnelCallback) (err error) {
	// Recover from any panics in the Go code, including duplicate metrics registration
	defer func() {
		if r := recover(); r != nil {
			errStr := fmt.Sprintf("%v", r)
			// Check if this is a duplicate metrics error - if so, we need to inform user to restart app
			if contains(errStr, "duplicate metrics") || contains(errStr, "already registered") {
				err = fmt.Errorf("metrics already registered - please restart the app completely to start tunnel again")
			} else {
				err = fmt.Errorf("tunnel panic: %v", r)
			}
			if callback != nil {
				callback.OnError(1, err.Error())
			}
		}
	}()

	// Cleanup any existing tunnel state
	cleanupMetricsState()

	tunnelMu.Lock()
	if globalTunnel != nil {
		// Stop existing tunnel first
		globalTunnel.Stop()
		globalTunnel = nil
		// Give some time for cleanup
		time.Sleep(100 * time.Millisecond)
	}
	tunnelMu.Unlock()

	tunnelMu.Lock()
	tunnel, err := NewTunnel(token, originURL, callback)
	if err != nil {
		tunnelMu.Unlock()
		return err
	}
	globalTunnel = tunnel
	tunnelMu.Unlock()

	return tunnel.Start()
}

// contains checks if a string contains a substring (case-insensitive)
func contains(s, substr string) bool {
	return len(s) >= len(substr) && (s == substr || len(s) > 0 && containsHelper(s, substr))
}

func containsHelper(s, substr string) bool {
	for i := 0; i <= len(s)-len(substr); i++ {
		if s[i:i+len(substr)] == substr {
			return true
		}
	}
	return false
}

// StopTunnel stops the currently running tunnel
func StopTunnel() {
	tunnelMu.Lock()
	defer tunnelMu.Unlock()

	if globalTunnel != nil {
		globalTunnel.Stop()
		globalTunnel = nil
	}

	// Reset the Prometheus registry so next start won't have duplicate metrics
	resetPrometheusRegistry()
}

// IsTunnelRunning returns true if a tunnel is currently running
func IsTunnelRunning() bool {
	tunnelMu.Lock()
	defer tunnelMu.Unlock()
	return globalTunnel != nil && globalTunnel.IsConnected()
}

// GetTunnelState returns the current state of the tunnel as an integer
func GetTunnelState() int {
	tunnelMu.Lock()
	defer tunnelMu.Unlock()
	if globalTunnel == nil {
		return int(StateDisconnected)
	}
	return globalTunnel.GetState()
}

// GetTunnelStateString returns the current state of the tunnel as a string
func GetTunnelStateString() string {
	tunnelMu.Lock()
	defer tunnelMu.Unlock()
	if globalTunnel == nil {
		return StateDisconnected.String()
	}
	return globalTunnel.GetStateString()
}

// ValidateToken checks if a token is valid without starting a tunnel
func ValidateToken(token string) (string, error) {
	parsed, err := parseToken(token)
	if err != nil {
		return "", err
	}
	return parsed.TunnelID.String(), nil
}

// GetVersion returns the version of the mobile library
func GetVersion() string {
	return Version
}

// ForceReset performs a complete reset of all tunnel state and metrics.
// This should be called when you want to completely restart from scratch.
func ForceReset() {
	tunnelMu.Lock()
	if globalTunnel != nil {
		globalTunnel.Stop()
		globalTunnel = nil
	}
	tunnelMu.Unlock()

	// Reset Prometheus registry
	resetPrometheusRegistry()

	// Give some time for goroutines to clean up
	time.Sleep(200 * time.Millisecond)
}
