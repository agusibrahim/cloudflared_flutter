import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

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

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final CloudflaredTunnel _plugin = CloudflaredTunnel();

  // Controllers
  final TextEditingController _tokenController = TextEditingController();
  final TextEditingController _portController =
      TextEditingController(text: '8080');

  // State
  TunnelState _tunnelState = TunnelState.disconnected;
  ServerState _serverState = ServerState.stopped;
  String _version = 'Unknown';
  String? _serverDir;
  String? _serverUrl;
  String? _errorMessage;
  final List<RequestLog> _requestLogs = [];
  final List<String> _debugLogs = [];

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
  }

  void _setupListeners() {
    _tunnelStateSub = _plugin.tunnelStateStream.listen((state) {
      setState(() => _tunnelState = state);
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
        // Create a sample index.html
        final indexFile = File('${serverDir.path}/index.html');
        await indexFile.writeAsString('''
<!DOCTYPE html>
<html>
<head>
  <title>Cloudflared Mobile Server</title>
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <style>
    body { font-family: -apple-system, sans-serif; padding: 20px; max-width: 600px; margin: 0 auto; }
    h1 { color: #f38020; }
    .status { background: #e0f7e0; padding: 10px; border-radius: 8px; }
  </style>
</head>
<body>
  <h1>🚀 Cloudflared Mobile Server</h1>
  <div class="status">
    <p><strong>Status:</strong> Running</p>
    <p><strong>Served from:</strong> Flutter App</p>
  </div>
  <p>This page is served from your mobile device via Cloudflare Tunnel!</p>
  <hr>
  <p><small>Generated at: ${DateTime.now().toIso8601String()}</small></p>
</body>
</html>
''');
      }
      setState(() => _serverDir = serverDir.path);
    } catch (e) {
      _showSnackBar('Failed to init server dir: $e', isError: true);
    }
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

  Future<void> _startServer() async {
    if (_serverDir == null) return;

    try {
      final port = int.tryParse(_portController.text) ?? 8080;
      await _plugin.startServer(rootDir: _serverDir!, port: port);
    } catch (e) {
      _showSnackBar('Server error: $e', isError: true);
    }
  }

  Future<void> _stopServer() async {
    try {
      await _plugin.stopServer();
      setState(() => _serverUrl = null);
    } catch (e) {
      _showSnackBar('Stop error: $e', isError: true);
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
    if (_serverDir == null) {
      _showSnackBar('Server directory not ready', isError: true);
      return;
    }

    try {
      final port = int.tryParse(_portController.text) ?? 8080;
      await _plugin.startAll(
        token: token,
        rootDir: _serverDir!,
        port: port,
      );
    } catch (e) {
      _showSnackBar('Error: $e', isError: true);
    }
  }

  Future<void> _stopAll() async {
    try {
      await _plugin.stopAll();
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
          // Status Cards
          Row(
            children: [
              Expanded(child: _buildStatusCard('Server', _serverState)),
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
                color: Colors.blue.shade50,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Local Server URL:',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  Text(_serverUrl!, style: const TextStyle(fontFamily: 'monospace')),
                ],
              ),
            ),
          const SizedBox(height: 16),

          // Quick Actions
          ElevatedButton.icon(
            onPressed:
                _tunnelState == TunnelState.disconnected && _serverState == ServerState.stopped
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
                _tunnelState != TunnelState.disconnected || _serverState != ServerState.stopped
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
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Local HTTP Server',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Text('Status: ${_serverState.name}'),
                  if (_serverDir != null) ...[
                    const SizedBox(height: 4),
                    Text('Directory: $_serverDir',
                        style: const TextStyle(fontSize: 12, fontFamily: 'monospace')),
                  ],
                  if (_serverUrl != null) ...[
                    const SizedBox(height: 4),
                    Text('URL: $_serverUrl',
                        style: const TextStyle(fontSize: 12, fontFamily: 'monospace')),
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
                  onPressed: _serverState == ServerState.stopped ? _startServer : null,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Start'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _serverState == ServerState.running ? _stopServer : null,
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
                  onPressed: _tunnelState == TunnelState.disconnected ? _startTunnel : null,
                  icon: const Icon(Icons.cloud_upload),
                  label: const Text('Connect'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _tunnelState != TunnelState.disconnected ? _stopTunnel : null,
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

  Widget _buildLogsTab() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Request Logs (${_requestLogs.length})',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              TextButton.icon(
                onPressed: () async {
                  await _plugin.clearRequestLogs();
                  setState(() => _requestLogs.clear());
                },
                icon: const Icon(Icons.delete),
                label: const Text('Clear'),
              ),
            ],
          ),
        ),
        Expanded(
          child: _requestLogs.isEmpty
              ? const Center(
                  child: Text('No requests yet.\nStart the server and make some requests!',
                      textAlign: TextAlign.center),
                )
              : ListView.builder(
                  itemCount: _requestLogs.length,
                  itemBuilder: (context, index) {
                    final log = _requestLogs[index];
                    return _buildLogItem(log);
                  },
                ),
        ),
      ],
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
                        style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
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
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
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
                    final isError = log.contains('ERROR') || log.contains('PANIC');
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
