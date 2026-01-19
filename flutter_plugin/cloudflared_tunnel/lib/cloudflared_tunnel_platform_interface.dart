import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'cloudflared_tunnel_method_channel.dart';

/// Tunnel state enum
enum TunnelState {
  disconnected(0),
  connecting(1),
  connected(2),
  reconnecting(3),
  error(4);

  const TunnelState(this.value);
  final int value;

  static TunnelState fromValue(int value) {
    return TunnelState.values.firstWhere(
      (state) => state.value == value,
      orElse: () => TunnelState.disconnected,
    );
  }

  bool get isConnected => this == TunnelState.connected;
  bool get isTransitioning =>
      this == TunnelState.connecting || this == TunnelState.reconnecting;
}

/// Server state enum
enum ServerState {
  stopped(0),
  starting(1),
  running(2),
  error(3);

  const ServerState(this.value);
  final int value;

  static ServerState fromValue(int value) {
    return ServerState.values.firstWhere(
      (state) => state.value == value,
      orElse: () => ServerState.stopped,
    );
  }

  bool get isRunning => this == ServerState.running;
}

/// Tunnel event types
sealed class TunnelEvent {}

class StateChangedEvent extends TunnelEvent {
  final TunnelState state;
  final String message;
  StateChangedEvent(this.state, this.message);
}

class ErrorEvent extends TunnelEvent {
  final int code;
  final String message;
  ErrorEvent(this.code, this.message);
}

class LogEvent extends TunnelEvent {
  final int level;
  final String message;
  LogEvent(this.level, this.message);
}

/// Server event types
sealed class ServerEvent {}

class ServerStateChangedEvent extends ServerEvent {
  final ServerState state;
  final String message;
  ServerStateChangedEvent(this.state, this.message);
}

class ServerErrorEvent extends ServerEvent {
  final int code;
  final String message;
  ServerErrorEvent(this.code, this.message);
}

class RequestLogEvent extends ServerEvent {
  final RequestLog log;
  RequestLogEvent(this.log);
}

/// Request log model
class RequestLog {
  final String timestamp;
  final String method;
  final String path;
  final String remoteAddr;
  final String userAgent;
  final String contentType;
  final Map<String, String> headers;
  final Map<String, String> query;
  final String body;
  final int statusCode;
  final int durationMs;

  RequestLog({
    required this.timestamp,
    required this.method,
    required this.path,
    required this.remoteAddr,
    required this.userAgent,
    required this.contentType,
    required this.headers,
    required this.query,
    required this.body,
    required this.statusCode,
    required this.durationMs,
  });

  factory RequestLog.fromJson(Map<String, dynamic> json) {
    return RequestLog(
      timestamp: json['timestamp'] ?? '',
      method: json['method'] ?? '',
      path: json['path'] ?? '',
      remoteAddr: json['remoteAddr'] ?? '',
      userAgent: json['userAgent'] ?? '',
      contentType: json['contentType'] ?? '',
      headers: Map<String, String>.from(json['headers'] ?? {}),
      query: Map<String, String>.from(json['query'] ?? {}),
      body: json['body'] ?? '',
      statusCode: json['statusCode'] ?? 0,
      durationMs: json['durationMs'] ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
        'timestamp': timestamp,
        'method': method,
        'path': path,
        'remoteAddr': remoteAddr,
        'userAgent': userAgent,
        'contentType': contentType,
        'headers': headers,
        'query': query,
        'body': body,
        'statusCode': statusCode,
        'durationMs': durationMs,
      };
}

/// File info model for directory listing
class FileInfo {
  final String name;
  final bool isDir;
  final int size;
  final String modTime;

  FileInfo({
    required this.name,
    required this.isDir,
    required this.size,
    required this.modTime,
  });

  factory FileInfo.fromJson(Map<String, dynamic> json) {
    return FileInfo(
      name: json['name'] ?? '',
      isDir: json['isDir'] ?? false,
      size: json['size'] ?? 0,
      modTime: json['modTime'] ?? '',
    );
  }
}

abstract class CloudflaredTunnelPlatform extends PlatformInterface {
  CloudflaredTunnelPlatform() : super(token: _token);

  static final Object _token = Object();

  static CloudflaredTunnelPlatform _instance = MethodChannelCloudflaredTunnel();

  static CloudflaredTunnelPlatform get instance => _instance;

  static set instance(CloudflaredTunnelPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  // =========================================================================
  // Tunnel Methods
  // =========================================================================

  /// Start the tunnel with the given token and origin URL
  Future<void> start({
    required String token,
    String originUrl = '',
    int haConnections = 4,
    bool enablePostQuantum = false,
  }) {
    throw UnimplementedError('start() has not been implemented.');
  }

  /// Stop the tunnel
  Future<void> stop() {
    throw UnimplementedError('stop() has not been implemented.');
  }

  /// Get the current tunnel state
  Future<TunnelState> getState() {
    throw UnimplementedError('getState() has not been implemented.');
  }

  /// Get the version of the native cloudflared library
  Future<String> getVersion() {
    throw UnimplementedError('getVersion() has not been implemented.');
  }

  /// Validate a tunnel token
  Future<String> validateToken(String token) {
    throw UnimplementedError('validateToken() has not been implemented.');
  }

  /// Check if a tunnel is running
  Future<bool> isRunning() {
    throw UnimplementedError('isRunning() has not been implemented.');
  }

  /// Stream of tunnel events
  Stream<TunnelEvent> get tunnelEventStream {
    throw UnimplementedError('tunnelEventStream has not been implemented.');
  }

  // =========================================================================
  // Server Methods
  // =========================================================================

  /// Start the local HTTP file server
  Future<void> startServer({
    required String rootDir,
    int port = 8080,
  }) {
    throw UnimplementedError('startServer() has not been implemented.');
  }

  /// Stop the local HTTP file server
  Future<void> stopServer() {
    throw UnimplementedError('stopServer() has not been implemented.');
  }

  /// Get the current server state
  Future<ServerState> getServerState() {
    throw UnimplementedError('getServerState() has not been implemented.');
  }

  /// Get the server URL
  Future<String> getServerUrl() {
    throw UnimplementedError('getServerUrl() has not been implemented.');
  }

  /// Check if the server is running
  Future<bool> isServerRunning() {
    throw UnimplementedError('isServerRunning() has not been implemented.');
  }

  /// Get request logs
  Future<List<RequestLog>> getRequestLogs() {
    throw UnimplementedError('getRequestLogs() has not been implemented.');
  }

  /// Clear request logs
  Future<void> clearRequestLogs() {
    throw UnimplementedError('clearRequestLogs() has not been implemented.');
  }

  /// List directory contents
  Future<List<FileInfo>> listDirectory(String path) {
    throw UnimplementedError('listDirectory() has not been implemented.');
  }

  /// Stream of server events
  Stream<ServerEvent> get serverEventStream {
    throw UnimplementedError('serverEventStream has not been implemented.');
  }
}
