import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart' as shelf_router;

import 'package:cloudflared_tunnel/cloudflared_tunnel.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Cloudflared Tunnel Demo',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.orange),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

/// Server mode enum
enum ServerMode { goServer, shelfServer }

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final CloudflaredTunnel _plugin = CloudflaredTunnel();

  // Shared preferences keys
  static const String _tokenKey = 'cloudflared_token';
  static const String _portKey = 'cloudflared_port';
  static const String _serverModeKey = 'cloudflared_server_mode';

  // Controllers
  final TextEditingController _tokenController = TextEditingController();
  final TextEditingController _portController =
      TextEditingController(text: '8080');

  // Server mode
  ServerMode _serverMode = ServerMode.goServer;

  // Shelf server instance
  HttpServer? _shelfServer;
  bool _isShelfServerRunning = false;

  // State
  TunnelState _tunnelState = TunnelState.disconnected;
  ServerState _serverState = ServerState.stopped;
  String _version = 'Unknown';
  String? _serverDir;
  String? _serverUrl;
  String? _errorMessage;
  final List<RequestLog> _requestLogs = [];
  final List<String> _debugLogs = [];

  // Shelf request logs
  final List<Map<String, dynamic>> _shelfRequestLogs = [];

  // Subscriptions
  StreamSubscription<TunnelState>? _tunnelStateSub;
  StreamSubscription<ServerState>? _serverStateSub;
  StreamSubscription<String>? _tunnelErrorSub;
  StreamSubscription<String>? _serverErrorSub;
  StreamSubscription<RequestLog>? _requestLogSub;
  StreamSubscription<String>? _tunnelLogSub;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _setupListeners();
    _loadVersion();
    _initServerDir();
    _requestNotificationPermission();
    _loadSavedSettings();
  }

  Future<void> _loadSavedSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedToken = prefs.getString(_tokenKey);
      final savedPort = prefs.getString(_portKey);
      final savedServerMode = prefs.getInt(_serverModeKey);

      if (savedToken != null && savedToken.isNotEmpty) {
        _tokenController.text = savedToken;
      }
      if (savedPort != null && savedPort.isNotEmpty) {
        _portController.text = savedPort;
      }
      if (savedServerMode != null) {
        setState(() {
          _serverMode = ServerMode.values[savedServerMode];
        });
      }
    } catch (e) {
      // Ignore load errors
    }
  }

  Future<void> _saveToken(String token) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_tokenKey, token);
    } catch (e) {
      // Ignore save errors
    }
  }

  Future<void> _saveSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_portKey, _portController.text);
      await prefs.setInt(_serverModeKey, _serverMode.index);
    } catch (e) {
      // Ignore save errors
    }
  }

  Future<void> _requestNotificationPermission() async {
    try {
      final hasPermission = await _plugin.hasNotificationPermission();
      if (!hasPermission) {
        final granted = await _plugin.requestNotificationPermission();
        if (!granted && mounted) {
          _showSnackBar(
              'Notification permission denied. Service may run silently.',
              isError: true);
        }
      }
    } catch (e) {
      // Ignore - permission handling is optional
    }
  }

  void _setupListeners() {
    _tunnelStateSub = _plugin.tunnelStateStream.listen((state) {
      setState(() => _tunnelState = state);
      // Save token when tunnel is connected (token is valid)
      if (state == TunnelState.connected) {
        final token = _tokenController.text.trim();
        if (token.isNotEmpty) {
          _saveToken(token);
          _saveSettings();
        }
      }
    });

    _serverStateSub = _plugin.serverStateStream.listen((state) async {
      setState(() => _serverState = state);
      if (state == ServerState.running) {
        final url = await _plugin.getServerUrl();
        setState(() => _serverUrl = url);
      }
    });

    _tunnelErrorSub = _plugin.tunnelErrorStream.listen((error) {
      setState(() => _errorMessage = error);
      _showSnackBar(error, isError: true);
    });

    _serverErrorSub = _plugin.serverErrorStream.listen((error) {
      setState(() => _errorMessage = error);
      _showSnackBar(error, isError: true);
    });

    _requestLogSub = _plugin.requestLogStream.listen((log) {
      setState(() {
        _requestLogs.insert(0, log);
        if (_requestLogs.length > 100) {
          _requestLogs.removeLast();
        }
      });
    });

    _tunnelLogSub = _plugin.tunnelLogStream.listen((log) {
      setState(() {
        final timestamp = DateTime.now().toString().substring(11, 19);
        _debugLogs.insert(0, '[$timestamp] $log');
        if (_debugLogs.length > 500) {
          _debugLogs.removeLast();
        }
      });
    });
  }

  Future<void> _loadVersion() async {
    try {
      final version = await _plugin.getVersion();
      setState(() => _version = version);
    } catch (e) {
      setState(() => _version = 'Error');
    }
  }

  Future<void> _initServerDir() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final serverDir = Directory('${dir.path}/server_files');
      if (!await serverDir.exists()) {
        await serverDir.create(recursive: true);
      }
      // Create/update sample index.html
      final indexFile = File('${serverDir.path}/index.html');
      await indexFile.writeAsString(_generateGoServerHtml());
      setState(() => _serverDir = serverDir.path);
    } catch (e) {
      _showSnackBar('Failed to init server dir: $e', isError: true);
    }
  }

  String _generateGoServerHtml() {
    return '''
<!DOCTYPE html>
<html>
<head>
  <title>Cloudflared Go Server</title>
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <style>
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
      padding: 20px;
      max-width: 600px;
      margin: 0 auto;
      background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
      min-height: 100vh;
      color: white;
    }
    .container {
      background: rgba(255,255,255,0.95);
      border-radius: 16px;
      padding: 24px;
      color: #333;
      box-shadow: 0 10px 40px rgba(0,0,0,0.2);
    }
    h1 { color: #f38020; margin-top: 0; }
    .badge {
      display: inline-block;
      background: #f38020;
      color: white;
      padding: 4px 12px;
      border-radius: 20px;
      font-size: 12px;
      font-weight: bold;
    }
    .status {
      background: #e8f5e9;
      padding: 16px;
      border-radius: 8px;
      margin: 16px 0;
      border-left: 4px solid #4caf50;
    }
    .info {
      background: #e3f2fd;
      padding: 16px;
      border-radius: 8px;
      margin: 16px 0;
      border-left: 4px solid #2196f3;
    }
    code {
      background: #f5f5f5;
      padding: 2px 6px;
      border-radius: 4px;
      font-family: 'SF Mono', Monaco, monospace;
    }
    .footer {
      text-align: center;
      margin-top: 24px;
      color: #999;
      font-size: 12px;
    }
  </style>
</head>
<body>
  <div class="container">
    <span class="badge">GO SERVER</span>
    <h1>🚀 Cloudflared Mobile</h1>

    <div class="status">
      <strong>✅ Server Status:</strong> Running<br>
      <strong>📁 Mode:</strong> Static File Server (Go)
    </div>

    <div class="info">
      <strong>ℹ️ About Go Server Mode:</strong><br>
      This page is served from the Go-based HTTP server built into the cloudflared plugin.
      Files are served from the app's documents directory.
    </div>

    <p>
      <strong>Features:</strong>
    </p>
    <ul>
      <li>Static file serving</li>
      <li>Request logging</li>
      <li>Directory listing</li>
      <li>MIME type detection</li>
    </ul>

    <div class="footer">
      Generated: ${DateTime.now().toIso8601String()}<br>
      Powered by Cloudflare Tunnel
    </div>
  </div>
</body>
</html>
''';
  }

  void _showSnackBar(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red : null,
      ),
    );
  }

  // =========================================================================
  // Go Server Methods
  // =========================================================================

  Future<void> _startGoServer() async {
    if (_serverDir == null) return;

    try {
      // Update index.html with fresh timestamp
      final indexFile = File('$_serverDir/index.html');
      await indexFile.writeAsString(_generateGoServerHtml());

      final port = int.tryParse(_portController.text) ?? 8080;
      await _plugin.startServer(rootDir: _serverDir!, port: port);
    } catch (e) {
      _showSnackBar('Server error: $e', isError: true);
    }
  }

  Future<void> _stopGoServer() async {
    try {
      await _plugin.stopServer();
      setState(() => _serverUrl = null);
    } catch (e) {
      _showSnackBar('Stop error: $e', isError: true);
    }
  }

  // =========================================================================
  // Shelf Server Methods
  // =========================================================================

  shelf.Handler _createShelfHandler() {
    final router = shelf_router.Router();

    // Root route
    router.get('/', (shelf.Request request) {
      _logShelfRequest(request, 200);
      return shelf.Response.ok(
        _generateShelfHtml('/'),
        headers: {'Content-Type': 'text/html'},
      );
    });

    // API routes
    router.get('/api/status', (shelf.Request request) {
      _logShelfRequest(request, 200);
      return shelf.Response.ok(
        '{"status": "ok", "server": "shelf", "timestamp": "${DateTime.now().toIso8601String()}"}',
        headers: {'Content-Type': 'application/json'},
      );
    });

    router.get('/api/info', (shelf.Request request) {
      _logShelfRequest(request, 200);
      return shelf.Response.ok(
        '{"name": "Cloudflared Shelf Server", "version": "1.0.0", "platform": "Dart"}',
        headers: {'Content-Type': 'application/json'},
      );
    });

    router.post('/api/echo', (shelf.Request request) async {
      final body = await request.readAsString();
      _logShelfRequest(request, 200, body: body);
      return shelf.Response.ok(
        '{"echo": ${body.isEmpty ? '""' : body}, "received_at": "${DateTime.now().toIso8601String()}"}',
        headers: {'Content-Type': 'application/json'},
      );
    });

    // Hello route with name parameter
    router.get('/hello/<name>', (shelf.Request request, String name) {
      _logShelfRequest(request, 200);
      return shelf.Response.ok(
        _generateShelfHtml('/hello/$name', name: name),
        headers: {'Content-Type': 'text/html'},
      );
    });

    // Catch all for 404
    router.all('/<ignored|.*>', (shelf.Request request) {
      _logShelfRequest(request, 404);
      return shelf.Response.notFound(
        _generateShelf404Html(request.url.path),
        headers: {'Content-Type': 'text/html'},
      );
    });

    // Add logging middleware
    return const shelf.Pipeline()
        .addMiddleware(shelf.logRequests())
        .addHandler(router.call);
  }

  void _logShelfRequest(shelf.Request request, int statusCode, {String? body}) {
    final log = {
      'timestamp': DateTime.now().toIso8601String(),
      'method': request.method,
      'path': '/${request.url.path}',
      'statusCode': statusCode,
      'headers': request.headers,
      'body': body ?? '',
    };
    setState(() {
      _shelfRequestLogs.insert(0, log);
      if (_shelfRequestLogs.length > 100) {
        _shelfRequestLogs.removeLast();
      }
    });
  }

  String _generateShelfHtml(String path, {String? name}) {
    final greeting = name != null ? 'Hello, $name!' : 'Welcome!';
    return '''
<!DOCTYPE html>
<html>
<head>
  <title>Cloudflared Shelf Server</title>
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <style>
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
      padding: 20px;
      max-width: 600px;
      margin: 0 auto;
      background: linear-gradient(135deg, #11998e 0%, #38ef7d 100%);
      min-height: 100vh;
      color: white;
    }
    .container {
      background: rgba(255,255,255,0.95);
      border-radius: 16px;
      padding: 24px;
      color: #333;
      box-shadow: 0 10px 40px rgba(0,0,0,0.2);
    }
    h1 { color: #11998e; margin-top: 0; }
    .badge {
      display: inline-block;
      background: #11998e;
      color: white;
      padding: 4px 12px;
      border-radius: 20px;
      font-size: 12px;
      font-weight: bold;
    }
    .status {
      background: #e8f5e9;
      padding: 16px;
      border-radius: 8px;
      margin: 16px 0;
      border-left: 4px solid #4caf50;
    }
    .routes {
      background: #fff3e0;
      padding: 16px;
      border-radius: 8px;
      margin: 16px 0;
      border-left: 4px solid #ff9800;
    }
    .route {
      font-family: 'SF Mono', Monaco, monospace;
      background: #f5f5f5;
      padding: 8px 12px;
      border-radius: 4px;
      margin: 4px 0;
      display: block;
    }
    .method {
      display: inline-block;
      padding: 2px 8px;
      border-radius: 4px;
      font-size: 11px;
      font-weight: bold;
      margin-right: 8px;
    }
    .get { background: #4caf50; color: white; }
    .post { background: #2196f3; color: white; }
    .greeting {
      font-size: 24px;
      text-align: center;
      padding: 20px;
      background: linear-gradient(135deg, #11998e 0%, #38ef7d 100%);
      color: white;
      border-radius: 8px;
      margin: 16px 0;
    }
    .footer {
      text-align: center;
      margin-top: 24px;
      color: #999;
      font-size: 12px;
    }
  </style>
</head>
<body>
  <div class="container">
    <span class="badge">SHELF SERVER</span>
    <h1>🎯 Dart Shelf Server</h1>

    <div class="greeting">$greeting</div>

    <div class="status">
      <strong>✅ Server Status:</strong> Running<br>
      <strong>📍 Current Path:</strong> <code>$path</code><br>
      <strong>🔧 Mode:</strong> Dart Shelf Router
    </div>

    <div class="routes">
      <strong>📡 Available Routes:</strong>
      <div class="route"><span class="method get">GET</span> / - This page</div>
      <div class="route"><span class="method get">GET</span> /hello/:name - Personalized greeting</div>
      <div class="route"><span class="method get">GET</span> /api/status - Server status JSON</div>
      <div class="route"><span class="method get">GET</span> /api/info - Server info JSON</div>
      <div class="route"><span class="method post">POST</span> /api/echo - Echo request body</div>
    </div>

    <p><strong>Try it:</strong> <a href="/hello/World">/hello/World</a></p>

    <div class="footer">
      Generated: ${DateTime.now().toIso8601String()}<br>
      Powered by Dart Shelf + Cloudflare Tunnel
    </div>
  </div>
</body>
</html>
''';
  }

  String _generateShelf404Html(String path) {
    return '''
<!DOCTYPE html>
<html>
<head>
  <title>404 - Not Found</title>
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <style>
    body {
      font-family: -apple-system, sans-serif;
      padding: 20px;
      max-width: 600px;
      margin: 0 auto;
      background: #f5f5f5;
      min-height: 100vh;
    }
    .container {
      background: white;
      border-radius: 16px;
      padding: 24px;
      text-align: center;
      box-shadow: 0 4px 20px rgba(0,0,0,0.1);
    }
    h1 { color: #e53935; }
    .path {
      background: #ffebee;
      padding: 12px;
      border-radius: 8px;
      font-family: monospace;
      margin: 16px 0;
    }
    a { color: #11998e; }
  </style>
</head>
<body>
  <div class="container">
    <h1>😕 404 Not Found</h1>
    <div class="path">/$path</div>
    <p>The requested path was not found.</p>
    <p><a href="/">← Back to Home</a></p>
  </div>
</body>
</html>
''';
  }

  Future<void> _startShelfServer() async {
    if (_isShelfServerRunning) return;

    try {
      final port = int.tryParse(_portController.text) ?? 8080;
      final handler = _createShelfHandler();

      _shelfServer = await shelf_io.serve(handler, '127.0.0.1', port);
      setState(() {
        _isShelfServerRunning = true;
        _serverUrl = 'http://127.0.0.1:$port';
      });

      _addDebugLog('Shelf server started on port $port');
      _showSnackBar('Shelf server started on port $port');
    } catch (e) {
      _showSnackBar('Failed to start Shelf server: $e', isError: true);
      _addDebugLog('Shelf server error: $e');
    }
  }

  Future<void> _stopShelfServer() async {
    if (_shelfServer != null) {
      await _shelfServer!.close(force: true);
      _shelfServer = null;
    }
    setState(() {
      _isShelfServerRunning = false;
      _serverUrl = null;
    });
    _addDebugLog('Shelf server stopped');
  }

  void _addDebugLog(String message) {
    setState(() {
      final timestamp = DateTime.now().toString().substring(11, 19);
      _debugLogs.insert(0, '[$timestamp] $message');
      if (_debugLogs.length > 500) {
        _debugLogs.removeLast();
      }
    });
  }

  // =========================================================================
  // Combined Methods
  // =========================================================================

  Future<void> _startServer() async {
    if (_serverMode == ServerMode.goServer) {
      await _startGoServer();
    } else {
      await _startShelfServer();
    }
  }

  Future<void> _stopServer() async {
    if (_serverMode == ServerMode.goServer) {
      await _stopGoServer();
    } else {
      await _stopShelfServer();
    }
  }

  bool get _isServerRunning {
    if (_serverMode == ServerMode.goServer) {
      return _serverState == ServerState.running;
    } else {
      return _isShelfServerRunning;
    }
  }

  Future<void> _startTunnel() async {
    final token = _tokenController.text.trim();
    if (token.isEmpty) {
      _showSnackBar('Please enter a tunnel token', isError: true);
      return;
    }

    try {
      await _plugin.startTunnel(
        token: token,
        originUrl: _serverUrl ?? '',
      );
    } catch (e) {
      _showSnackBar('Tunnel error: $e', isError: true);
    }
  }

  Future<void> _stopTunnel() async {
    try {
      await _plugin.stopTunnel();
    } catch (e) {
      _showSnackBar('Stop error: $e', isError: true);
    }
  }

  Future<void> _startAll() async {
    final token = _tokenController.text.trim();
    if (token.isEmpty) {
      _showSnackBar('Please enter a tunnel token', isError: true);
      return;
    }

    try {
      // Start server first
      await _startServer();

      // Wait for server to start
      await Future.delayed(const Duration(milliseconds: 500));

      // Start tunnel with server as origin
      final port = int.tryParse(_portController.text) ?? 8080;
      await _plugin.startTunnel(
        token: token,
        originUrl: 'http://127.0.0.1:$port',
      );
    } catch (e) {
      _showSnackBar('Error: $e', isError: true);
    }
  }

  Future<void> _stopAll() async {
    try {
      await _plugin.stopTunnel();
      await _stopServer();
      setState(() => _serverUrl = null);
    } catch (e) {
      _showSnackBar('Error: $e', isError: true);
    }
  }

  @override
  void dispose() {
    _tunnelStateSub?.cancel();
    _serverStateSub?.cancel();
    _tunnelErrorSub?.cancel();
    _serverErrorSub?.cancel();
    _requestLogSub?.cancel();
    _tunnelLogSub?.cancel();
    _tokenController.dispose();
    _portController.dispose();
    _tabController.dispose();
    _shelfServer?.close(force: true);
    _plugin.dispose();
    super.dispose();
  }

  Color _stateColor(dynamic state) {
    if (state == TunnelState.connected || state == ServerState.running) {
      return Colors.green;
    }
    if (state == TunnelState.connecting ||
        state == TunnelState.reconnecting ||
        state == ServerState.starting) {
      return Colors.orange;
    }
    if (state == TunnelState.error || state == ServerState.error) {
      return Colors.red;
    }
    return Colors.grey;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Cloudflared Tunnel'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(icon: Icon(Icons.home), text: 'Overview'),
            Tab(icon: Icon(Icons.dns), text: 'Server'),
            Tab(icon: Icon(Icons.list), text: 'Requests'),
            Tab(icon: Icon(Icons.bug_report), text: 'Debug'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildOverviewTab(),
          _buildServerTab(),
          _buildLogsTab(),
          _buildDebugTab(),
        ],
      ),
    );
  }

  Widget _buildOverviewTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Server Mode Selector
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Server Mode',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  SegmentedButton<ServerMode>(
                    segments: const [
                      ButtonSegment(
                        value: ServerMode.goServer,
                        label: Text('Go Server'),
                        icon: Icon(Icons.folder),
                      ),
                      ButtonSegment(
                        value: ServerMode.shelfServer,
                        label: Text('Shelf Server'),
                        icon: Icon(Icons.code),
                      ),
                    ],
                    selected: {_serverMode},
                    onSelectionChanged: _isServerRunning
                        ? null
                        : (Set<ServerMode> newSelection) {
                            setState(() {
                              _serverMode = newSelection.first;
                            });
                          },
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _serverMode == ServerMode.goServer
                        ? '📁 Serves static files from app directory'
                        : '🎯 Serves dynamic routes from Dart code',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Status Cards
          Row(
            children: [
              Expanded(
                child: _buildStatusCard(
                  'Server',
                  _serverMode == ServerMode.goServer
                      ? _serverState
                      : (_isShelfServerRunning
                          ? ServerState.running
                          : ServerState.stopped),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(child: _buildStatusCard('Tunnel', _tunnelState)),
            ],
          ),
          const SizedBox(height: 16),

          // Version
          Text(
            'Library Version: $_version',
            style: Theme.of(context).textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),

          // Token Input
          TextField(
            controller: _tokenController,
            decoration: const InputDecoration(
              labelText: 'Tunnel Token',
              hintText: 'Paste your Cloudflare tunnel token',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.vpn_key),
            ),
            maxLines: 2,
          ),
          const SizedBox(height: 12),

          // Port Input
          TextField(
            controller: _portController,
            decoration: const InputDecoration(
              labelText: 'Server Port',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.numbers),
            ),
            keyboardType: TextInputType.number,
          ),
          const SizedBox(height: 16),

          // Server URL
          if (_serverUrl != null)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _serverMode == ServerMode.goServer
                    ? Colors.purple.shade50
                    : Colors.teal.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: _serverMode == ServerMode.goServer
                      ? Colors.purple.shade200
                      : Colors.teal.shade200,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        _serverMode == ServerMode.goServer
                            ? Icons.folder
                            : Icons.code,
                        size: 16,
                        color: _serverMode == ServerMode.goServer
                            ? Colors.purple
                            : Colors.teal,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _serverMode == ServerMode.goServer
                            ? 'Go Server URL:'
                            : 'Shelf Server URL:',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(_serverUrl!,
                      style: const TextStyle(fontFamily: 'monospace')),
                ],
              ),
            ),
          const SizedBox(height: 16),

          // Quick Actions
          ElevatedButton.icon(
            onPressed:
                _tunnelState == TunnelState.disconnected && !_isServerRunning
                    ? _startAll
                    : null,
            icon: const Icon(Icons.rocket_launch),
            label: const Text('Start All'),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.all(16),
              backgroundColor: Colors.green.shade100,
            ),
          ),
          const SizedBox(height: 8),
          ElevatedButton.icon(
            onPressed:
                _tunnelState != TunnelState.disconnected || _isServerRunning
                    ? _stopAll
                    : null,
            icon: const Icon(Icons.stop),
            label: const Text('Stop All'),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.all(16),
              backgroundColor: Colors.red.shade100,
            ),
          ),
          const SizedBox(height: 16),

          // Error Message
          if (_errorMessage != null)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.red.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.red.shade200),
              ),
              child: Row(
                children: [
                  Icon(Icons.error, color: Colors.red.shade700),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _errorMessage!,
                      style: TextStyle(color: Colors.red.shade700),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => setState(() => _errorMessage = null),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildStatusCard(String title, dynamic state) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: _stateColor(state),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Text(title, style: Theme.of(context).textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              state.toString().split('.').last.toUpperCase(),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildServerTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Server Mode Info Card
          Card(
            color: _serverMode == ServerMode.goServer
                ? Colors.purple.shade50
                : Colors.teal.shade50,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        _serverMode == ServerMode.goServer
                            ? Icons.folder
                            : Icons.code,
                        color: _serverMode == ServerMode.goServer
                            ? Colors.purple
                            : Colors.teal,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _serverMode == ServerMode.goServer
                            ? 'Go Static File Server'
                            : 'Dart Shelf Router Server',
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Status: ${_isServerRunning ? 'Running' : 'Stopped'}',
                    style: TextStyle(
                      color: _isServerRunning ? Colors.green : Colors.grey,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  if (_serverMode == ServerMode.goServer &&
                      _serverDir != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      'Directory: $_serverDir',
                      style:
                          const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                    ),
                  ],
                  if (_serverUrl != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      'URL: $_serverUrl',
                      style:
                          const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                    ),
                  ],
                  if (_serverMode == ServerMode.shelfServer) ...[
                    const Divider(height: 24),
                    const Text(
                      'Available Routes:',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    _buildRouteChip('GET', '/'),
                    _buildRouteChip('GET', '/hello/:name'),
                    _buildRouteChip('GET', '/api/status'),
                    _buildRouteChip('GET', '/api/info'),
                    _buildRouteChip('POST', '/api/echo'),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: !_isServerRunning ? _startServer : null,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Start'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _isServerRunning ? _stopServer : null,
                  icon: const Icon(Icons.stop),
                  label: const Text('Stop'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red.shade100,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),

          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Cloudflare Tunnel',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Text('Status: ${_tunnelState.name}'),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _tunnelState == TunnelState.disconnected
                      ? _startTunnel
                      : null,
                  icon: const Icon(Icons.cloud_upload),
                  label: const Text('Connect'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _tunnelState != TunnelState.disconnected
                      ? _stopTunnel
                      : null,
                  icon: const Icon(Icons.cloud_off),
                  label: const Text('Disconnect'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red.shade100,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildRouteChip(String method, String path) {
    final isGet = method == 'GET';
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: isGet ? Colors.green : Colors.blue,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              method,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 10,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            path,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
          ),
        ],
      ),
    );
  }

  Widget _buildLogsTab() {
    // Use shelf logs if in shelf mode, otherwise use go server logs
    final logs = _serverMode == ServerMode.shelfServer
        ? _shelfRequestLogs
        : _requestLogs;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Request Logs (${logs.length})',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              TextButton.icon(
                onPressed: () async {
                  if (_serverMode == ServerMode.goServer) {
                    await _plugin.clearRequestLogs();
                    setState(() => _requestLogs.clear());
                  } else {
                    setState(() => _shelfRequestLogs.clear());
                  }
                },
                icon: const Icon(Icons.delete),
                label: const Text('Clear'),
              ),
            ],
          ),
        ),
        Expanded(
          child: logs.isEmpty
              ? Center(
                  child: Text(
                    'No requests yet.\nStart the server and make some requests!',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey.shade600),
                  ),
                )
              : ListView.builder(
                  itemCount: logs.length,
                  itemBuilder: (context, index) {
                    if (_serverMode == ServerMode.shelfServer) {
                      return _buildShelfLogItem(
                          logs[index] as Map<String, dynamic>);
                    } else {
                      return _buildLogItem(logs[index] as RequestLog);
                    }
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildShelfLogItem(Map<String, dynamic> log) {
    final statusCode = log['statusCode'] as int;
    final statusColor = statusCode < 400
        ? Colors.green
        : statusCode < 500
            ? Colors.orange
            : Colors.red;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: ListTile(
        leading: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: statusColor.withOpacity(0.1),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            statusCode.toString(),
            style: TextStyle(
              color: statusColor,
              fontWeight: FontWeight.bold,
              fontFamily: 'monospace',
            ),
          ),
        ),
        title: Text(
          '${log['method']} ${log['path']}',
          style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
        ),
        subtitle: Text(
          log['timestamp'] ?? '',
          style: const TextStyle(fontSize: 11),
        ),
      ),
    );
  }

  Widget _buildLogItem(RequestLog log) {
    final statusColor = log.statusCode < 400
        ? Colors.green
        : log.statusCode < 500
            ? Colors.orange
            : Colors.red;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: ExpansionTile(
        leading: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: statusColor.withOpacity(0.1),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            log.statusCode.toString(),
            style: TextStyle(
              color: statusColor,
              fontWeight: FontWeight.bold,
              fontFamily: 'monospace',
            ),
          ),
        ),
        title: Text(
          '${log.method} ${log.path}',
          style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
        ),
        subtitle: Text(
          '${log.durationMs}ms • ${log.remoteAddr}',
          style: const TextStyle(fontSize: 12),
        ),
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildLogDetail('Timestamp', log.timestamp),
                _buildLogDetail('User-Agent', log.userAgent),
                _buildLogDetail('Content-Type', log.contentType),
                if (log.headers.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  const Text('Headers:',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  ...log.headers.entries.map(
                    (e) => Text('  ${e.key}: ${e.value}',
                        style: const TextStyle(
                            fontFamily: 'monospace', fontSize: 12)),
                  ),
                ],
                if (log.body.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  const Text('Body:',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      log.body,
                      style:
                          const TextStyle(fontFamily: 'monospace', fontSize: 12),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLogDetail(String label, String value) {
    if (value.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(
              '$label:',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDebugTab() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Debug Logs (${_debugLogs.length})',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              TextButton.icon(
                onPressed: () {
                  setState(() => _debugLogs.clear());
                },
                icon: const Icon(Icons.delete),
                label: const Text('Clear'),
              ),
            ],
          ),
        ),
        Expanded(
          child: _debugLogs.isEmpty
              ? const Center(
                  child: Text(
                    'No debug logs yet.\nStart the tunnel to see logs.',
                    textAlign: TextAlign.center,
                  ),
                )
              : ListView.builder(
                  itemCount: _debugLogs.length,
                  itemBuilder: (context, index) {
                    final log = _debugLogs[index];
                    final isError =
                        log.contains('ERROR') || log.contains('PANIC');
                    final isWarning = log.contains('WARN');
                    return Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 4,
                      ),
                      color: isError
                          ? Colors.red.shade50
                          : isWarning
                              ? Colors.orange.shade50
                              : null,
                      child: Text(
                        log,
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11,
                          color: isError
                              ? Colors.red.shade800
                              : isWarning
                                  ? Colors.orange.shade800
                                  : null,
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
