import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';

import 'cloudflared_tunnel_platform_interface.dart';

/// Method channel implementation of [CloudflaredTunnelPlatform].
class MethodChannelCloudflaredTunnel extends CloudflaredTunnelPlatform {
  static const MethodChannel _methodChannel =
      MethodChannel('com.cloudflare.cloudflared_tunnel/methods');

  static const EventChannel _eventChannel =
      EventChannel('com.cloudflare.cloudflared_tunnel/events');

  StreamController<TunnelEvent>? _tunnelEventController;
  StreamController<ServerEvent>? _serverEventController;
  StreamSubscription? _eventSubscription;
  bool _isListening = false;

  // =========================================================================
  // Tunnel Methods
  // =========================================================================

  @override
  Future<void> start({
    required String token,
    String originUrl = '',
    int haConnections = 4,
    bool enablePostQuantum = false,
  }) async {
    await _methodChannel.invokeMethod('start', {
      'token': token,
      'originUrl': originUrl,
      'haConnections': haConnections,
      'enablePostQuantum': enablePostQuantum,
    });
  }

  @override
  Future<void> stop() async {
    await _methodChannel.invokeMethod('stop');
  }

  @override
  Future<TunnelState> getState() async {
    final stateValue = await _methodChannel.invokeMethod<int>('getState');
    return TunnelState.fromValue(stateValue ?? 0);
  }

  @override
  Future<String> getVersion() async {
    final version = await _methodChannel.invokeMethod<String>('getVersion');
    return version ?? 'unknown';
  }

  @override
  Future<String> validateToken(String token) async {
    final tunnelId =
        await _methodChannel.invokeMethod<String>('validateToken', {
      'token': token,
    });
    return tunnelId ?? '';
  }

  @override
  Future<bool> isRunning() async {
    final running = await _methodChannel.invokeMethod<bool>('isRunning');
    return running ?? false;
  }

  @override
  Stream<TunnelEvent> get tunnelEventStream {
    _tunnelEventController ??= StreamController<TunnelEvent>.broadcast();
    _ensureListening();
    return _tunnelEventController!.stream;
  }

  // =========================================================================
  // Server Methods
  // =========================================================================

  @override
  Future<void> startServer({
    required String rootDir,
    int port = 8080,
  }) async {
    await _methodChannel.invokeMethod('startServer', {
      'rootDir': rootDir,
      'port': port,
    });
  }

  @override
  Future<void> stopServer() async {
    await _methodChannel.invokeMethod('stopServer');
  }

  @override
  Future<ServerState> getServerState() async {
    final stateValue =
        await _methodChannel.invokeMethod<int>('getServerState');
    return ServerState.fromValue(stateValue ?? 0);
  }

  @override
  Future<String> getServerUrl() async {
    final url = await _methodChannel.invokeMethod<String>('getServerUrl');
    return url ?? '';
  }

  @override
  Future<bool> isServerRunning() async {
    final running = await _methodChannel.invokeMethod<bool>('isServerRunning');
    return running ?? false;
  }

  @override
  Future<List<RequestLog>> getRequestLogs() async {
    final logsJson =
        await _methodChannel.invokeMethod<String>('getRequestLogs');
    if (logsJson == null || logsJson.isEmpty || logsJson == '[]') {
      return [];
    }

    try {
      final List<dynamic> logsList = json.decode(logsJson);
      return logsList
          .map((e) => RequestLog.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      return [];
    }
  }

  @override
  Future<void> clearRequestLogs() async {
    await _methodChannel.invokeMethod('clearRequestLogs');
  }

  @override
  Future<List<FileInfo>> listDirectory(String path) async {
    final filesJson =
        await _methodChannel.invokeMethod<String>('listDirectory', {
      'path': path,
    });

    if (filesJson == null || filesJson.isEmpty || filesJson == '[]') {
      return [];
    }

    try {
      final List<dynamic> filesList = json.decode(filesJson);
      return filesList
          .map((e) => FileInfo.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      return [];
    }
  }

  @override
  Stream<ServerEvent> get serverEventStream {
    _serverEventController ??= StreamController<ServerEvent>.broadcast();
    _ensureListening();
    return _serverEventController!.stream;
  }

  // =========================================================================
  // Event Handling
  // =========================================================================

  void _ensureListening() {
    if (_isListening) return;
    _isListening = true;

    _eventSubscription = _eventChannel.receiveBroadcastStream().listen(
      (dynamic event) {
        if (event is Map) {
          final type = event['type'] as String?;
          switch (type) {
            // Tunnel events
            case 'stateChanged':
              final stateValue = event['state'] as int? ?? 0;
              final message = event['message'] as String? ?? '';
              _tunnelEventController?.add(
                StateChangedEvent(TunnelState.fromValue(stateValue), message),
              );
              break;
            case 'error':
              final code = event['code'] as int? ?? 0;
              final message = event['message'] as String? ?? '';
              _tunnelEventController?.add(ErrorEvent(code, message));
              break;
            case 'log':
              final level = event['level'] as int? ?? 0;
              final message = event['message'] as String? ?? '';
              _tunnelEventController?.add(LogEvent(level, message));
              break;

            // Server events
            case 'serverStateChanged':
              final stateValue = event['state'] as int? ?? 0;
              final message = event['message'] as String? ?? '';
              _serverEventController?.add(
                ServerStateChangedEvent(
                    ServerState.fromValue(stateValue), message),
              );
              break;
            case 'serverError':
              final code = event['code'] as int? ?? 0;
              final message = event['message'] as String? ?? '';
              _serverEventController?.add(ServerErrorEvent(code, message));
              break;
            case 'requestLog':
              final logJson = event['log'] as String? ?? '{}';
              try {
                final logMap = json.decode(logJson) as Map<String, dynamic>;
                final log = RequestLog.fromJson(logMap);
                _serverEventController?.add(RequestLogEvent(log));
              } catch (e) {
                // Ignore parse errors
              }
              break;
          }
        }
      },
      onError: (error) {
        _tunnelEventController?.addError(error);
        _serverEventController?.addError(error);
      },
    );
  }

  void dispose() {
    _eventSubscription?.cancel();
    _eventSubscription = null;
    _tunnelEventController?.close();
    _tunnelEventController = null;
    _serverEventController?.close();
    _serverEventController = null;
    _isListening = false;
  }
}
