/// Flutter plugin for Cloudflare Tunnel (cloudflared) with optional local HTTP server.
///
/// This plugin provides:
/// - Cloudflared tunnel connection to Cloudflare's global network
/// - Optional: Local HTTP file server with request logging (Go-based)
/// - Tunnel can be used standalone with any Dart HTTP server (shelf, etc.)
library cloudflared_tunnel;

import 'dart:async';
import 'cloudflared_tunnel_platform_interface.dart';

// Re-export types
export 'cloudflared_tunnel_platform_interface.dart'
    show
        TunnelState,
        TunnelEvent,
        StateChangedEvent,
        ErrorEvent,
        LogEvent,
        ServerState,
        ServerEvent,
        ServerStateChangedEvent,
        ServerErrorEvent,
        RequestLogEvent,
        RequestLog,
        FileInfo;

/// Main class for interacting with Cloudflare Tunnel and Local Server.
///
/// The tunnel and server are **independent** - you can use them together or separately.
///
/// ## Example 1: Tunnel only (with your own Dart server like shelf)
/// ```dart
/// import 'package:shelf/shelf.dart' as shelf;
/// import 'package:shelf/shelf_io.dart' as shelf_io;
///
/// // Start your Dart HTTP server first
/// final handler = shelf.Pipeline()
///     .addMiddleware(shelf.logRequests())
///     .addHandler((request) => shelf.Response.ok('Hello from Dart!'));
/// final server = await shelf_io.serve(handler, '127.0.0.1', 3000);
///
/// // Then start tunnel pointing to your Dart server
/// final plugin = CloudflaredTunnel();
/// await plugin.startTunnel(
///   token: 'your-tunnel-token',
///   originUrl: 'http://127.0.0.1:3000',  // Point to your Dart server
/// );
///
/// // Your Dart server is now publicly accessible via Cloudflare!
/// ```
///
/// ## Example 2: Built-in Go file server + Tunnel
/// ```dart
/// final plugin = CloudflaredTunnel();
///
/// // Start the built-in Go file server
/// await plugin.startServer(
///   rootDir: '/path/to/serve',
///   port: 8080,
/// );
///
/// // Start tunnel with the Go server as origin
/// await plugin.startTunnel(
///   token: 'your-tunnel-token',
///   originUrl: 'http://127.0.0.1:8080',
/// );
///
/// // Listen to request logs from Go server
/// plugin.requestLogStream.listen((log) {
///   print('${log.method} ${log.path} - ${log.statusCode}');
/// });
/// ```
///
/// ## Example 3: Convenience method for both
/// ```dart
/// final plugin = CloudflaredTunnel();
/// await plugin.startAll(
///   token: 'your-tunnel-token',
///   rootDir: '/path/to/serve',
///   port: 8080,
/// );
/// ```
class CloudflaredTunnel {
  static CloudflaredTunnel? _instance;

  // Tunnel state
  final StreamController<TunnelState> _tunnelStateController =
      StreamController<TunnelState>.broadcast();
  final StreamController<String> _tunnelErrorController =
      StreamController<String>.broadcast();
  final StreamController<String> _tunnelLogController =
      StreamController<String>.broadcast();
  TunnelState _currentTunnelState = TunnelState.disconnected;

  // Server state
  final StreamController<ServerState> _serverStateController =
      StreamController<ServerState>.broadcast();
  final StreamController<String> _serverErrorController =
      StreamController<String>.broadcast();
  final StreamController<RequestLog> _requestLogController =
      StreamController<RequestLog>.broadcast();
  ServerState _currentServerState = ServerState.stopped;

  StreamSubscription<TunnelEvent>? _tunnelEventSubscription;
  StreamSubscription<ServerEvent>? _serverEventSubscription;

  /// Get the singleton instance of CloudflaredTunnel.
  factory CloudflaredTunnel() {
    _instance ??= CloudflaredTunnel._internal();
    return _instance!;
  }

  CloudflaredTunnel._internal() {
    _setupEventListening();
  }

  void _setupEventListening() {
    _tunnelEventSubscription =
        CloudflaredTunnelPlatform.instance.tunnelEventStream.listen((event) {
      switch (event) {
        case StateChangedEvent(:final state, :final message):
          _currentTunnelState = state;
          _tunnelStateController.add(state);
          break;
        case ErrorEvent(:final message):
          _tunnelErrorController.add(message);
          break;
        case LogEvent(:final message):
          _tunnelLogController.add(message);
          break;
      }
    });

    _serverEventSubscription =
        CloudflaredTunnelPlatform.instance.serverEventStream.listen((event) {
      switch (event) {
        case ServerStateChangedEvent(:final state, :final message):
          _currentServerState = state;
          _serverStateController.add(state);
          break;
        case ServerErrorEvent(:final message):
          _serverErrorController.add(message);
          break;
        case RequestLogEvent(:final log):
          _requestLogController.add(log);
          break;
      }
    });
  }

  // ===========================================================================
  // Tunnel API
  // ===========================================================================

  /// Stream of tunnel state changes.
  Stream<TunnelState> get tunnelStateStream => _tunnelStateController.stream;

  /// Stream of tunnel error messages.
  Stream<String> get tunnelErrorStream => _tunnelErrorController.stream;

  /// Stream of tunnel log messages (for debugging).
  Stream<String> get tunnelLogStream => _tunnelLogController.stream;

  /// Stream of all tunnel events.
  Stream<TunnelEvent> get tunnelEventStream =>
      CloudflaredTunnelPlatform.instance.tunnelEventStream;

  /// Current tunnel state.
  TunnelState get currentTunnelState => _currentTunnelState;

  /// Whether the tunnel is currently connected.
  bool get isTunnelConnected => _currentTunnelState == TunnelState.connected;

  /// Start the tunnel with the given configuration.
  ///
  /// This can be used **independently** without starting the built-in Go server.
  /// Point [originUrl] to any local HTTP server (shelf, dart:io HttpServer, etc.)
  ///
  /// [token] - The tunnel token from Cloudflare dashboard (required)
  /// [originUrl] - The local URL to proxy traffic to (e.g., 'http://127.0.0.1:3000')
  ///               This should point to your running HTTP server.
  /// [haConnections] - Number of high availability connections (default: 4)
  /// [enablePostQuantum] - Enable post-quantum cryptography (default: false)
  ///
  /// Example with shelf:
  /// ```dart
  /// // First start shelf server on port 3000
  /// final server = await shelf_io.serve(handler, '127.0.0.1', 3000);
  ///
  /// // Then start tunnel pointing to shelf
  /// await plugin.startTunnel(
  ///   token: 'your-token',
  ///   originUrl: 'http://127.0.0.1:3000',
  /// );
  /// ```
  Future<void> startTunnel({
    required String token,
    String originUrl = '',
    int haConnections = 4,
    bool enablePostQuantum = false,
  }) async {
    await CloudflaredTunnelPlatform.instance.start(
      token: token,
      originUrl: originUrl,
      haConnections: haConnections,
      enablePostQuantum: enablePostQuantum,
    );
  }

  /// Stop the tunnel.
  Future<void> stopTunnel() async {
    await CloudflaredTunnelPlatform.instance.stop();
  }

  /// Get the current tunnel state from native code.
  Future<TunnelState> getTunnelState() async {
    return CloudflaredTunnelPlatform.instance.getState();
  }

  /// Validate a tunnel token without starting the tunnel.
  Future<String> validateToken(String token) async {
    return CloudflaredTunnelPlatform.instance.validateToken(token);
  }

  /// Get the version of the native cloudflared library.
  Future<String> getVersion() async {
    return CloudflaredTunnelPlatform.instance.getVersion();
  }

  /// Check if a tunnel is currently running.
  Future<bool> isTunnelRunning() async {
    return CloudflaredTunnelPlatform.instance.isRunning();
  }

  // ===========================================================================
  // Server API
  // ===========================================================================

  /// Stream of server state changes.
  Stream<ServerState> get serverStateStream => _serverStateController.stream;

  /// Stream of server error messages.
  Stream<String> get serverErrorStream => _serverErrorController.stream;

  /// Stream of request logs (real-time).
  Stream<RequestLog> get requestLogStream => _requestLogController.stream;

  /// Stream of all server events.
  Stream<ServerEvent> get serverEventStream =>
      CloudflaredTunnelPlatform.instance.serverEventStream;

  /// Current server state.
  ServerState get currentServerState => _currentServerState;

  /// Whether the server is currently running.
  bool get isServerRunning => _currentServerState == ServerState.running;

  /// Start the local HTTP file server.
  ///
  /// [rootDir] - The directory to serve files from (required)
  /// [port] - The port to listen on (default: 8080)
  Future<void> startServer({
    required String rootDir,
    int port = 8080,
  }) async {
    await CloudflaredTunnelPlatform.instance.startServer(
      rootDir: rootDir,
      port: port,
    );
  }

  /// Stop the local HTTP file server.
  Future<void> stopServer() async {
    await CloudflaredTunnelPlatform.instance.stopServer();
  }

  /// Get the current server state from native code.
  Future<ServerState> getServerState() async {
    return CloudflaredTunnelPlatform.instance.getServerState();
  }

  /// Get the server URL (e.g., 'http://127.0.0.1:8080').
  Future<String> getServerUrl() async {
    return CloudflaredTunnelPlatform.instance.getServerUrl();
  }

  /// Get all stored request logs.
  Future<List<RequestLog>> getRequestLogs() async {
    return CloudflaredTunnelPlatform.instance.getRequestLogs();
  }

  /// Clear all stored request logs.
  Future<void> clearRequestLogs() async {
    await CloudflaredTunnelPlatform.instance.clearRequestLogs();
  }

  /// List contents of a directory.
  Future<List<FileInfo>> listDirectory(String path) async {
    return CloudflaredTunnelPlatform.instance.listDirectory(path);
  }

  // ===========================================================================
  // Combined API
  // ===========================================================================

  /// Start both server and tunnel.
  ///
  /// This is a convenience method to start the local server and connect it
  /// to Cloudflare tunnel in one call.
  Future<void> startAll({
    required String token,
    required String rootDir,
    int port = 8080,
    int haConnections = 4,
    bool enablePostQuantum = false,
  }) async {
    // Start server first
    await startServer(rootDir: rootDir, port: port);

    // Wait a bit for server to start
    await Future.delayed(const Duration(milliseconds: 500));

    // Start tunnel with server as origin
    await startTunnel(
      token: token,
      originUrl: 'http://127.0.0.1:$port',
      haConnections: haConnections,
      enablePostQuantum: enablePostQuantum,
    );
  }

  /// Stop both tunnel and server.
  Future<void> stopAll() async {
    await stopTunnel();
    await stopServer();
  }

  // ===========================================================================
  // Service API (Android Background Service)
  // ===========================================================================

  /// Check if the background service is running.
  ///
  /// On Android, the tunnel and server run in a foreground service that
  /// survives app closure (similar to Termux). This method checks if that
  /// service is currently running.
  ///
  /// On iOS, this always returns false as iOS doesn't use foreground services.
  Future<bool> isServiceRunning() async {
    return CloudflaredTunnelPlatform.instance.isServiceRunning();
  }

  /// Stop the background service completely.
  ///
  /// This stops both the tunnel and server, and terminates the foreground
  /// service on Android. Use this when you want to completely shut down
  /// all background operations.
  ///
  /// Note: Calling [stopTunnel] and [stopServer] individually will also
  /// automatically stop the service if nothing else is running.
  Future<void> stopService() async {
    await CloudflaredTunnelPlatform.instance.stopService();
  }

  /// Request notification permission (Android 13+).
  ///
  /// On Android 13 (API 33) and above, apps must request the POST_NOTIFICATIONS
  /// permission at runtime to show notifications. Call this method before
  /// starting the tunnel or server to ensure the notification can be shown.
  ///
  /// Returns true if permission is granted, false otherwise.
  /// On older Android versions, this always returns true.
  Future<bool> requestNotificationPermission() async {
    return CloudflaredTunnelPlatform.instance.requestNotificationPermission();
  }

  /// Check if notification permission is granted.
  ///
  /// Returns true if notification permission is granted or not required
  /// (Android < 13), false if denied.
  Future<bool> hasNotificationPermission() async {
    return CloudflaredTunnelPlatform.instance.hasNotificationPermission();
  }

  /// Dispose of resources.
  void dispose() {
    _tunnelEventSubscription?.cancel();
    _serverEventSubscription?.cancel();
    _tunnelStateController.close();
    _tunnelErrorController.close();
    _tunnelLogController.close();
    _serverStateController.close();
    _serverErrorController.close();
    _requestLogController.close();
    _instance = null;
  }
}
