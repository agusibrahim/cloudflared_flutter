# Cloudflared Tunnel Flutter Plugin

Flutter plugin untuk Cloudflare Tunnel (cloudflared) dengan local HTTP file server. Plugin ini memungkinkan:
- Menjalankan HTTP file server lokal di perangkat mobile
- Logging lengkap semua request (method, headers, body, dll)
- Meng-expose server lokal ke publik via Cloudflare tunnel

## Arsitektur

```
┌─────────────────────────────────────────────────────────────┐
│                     Flutter App                              │
│                         │                                    │
│                    Dart API                                  │
│              (CloudflaredTunnel)                             │
└─────────────────────┬───────────────────────────────────────┘
                      │ Platform Channel
┌─────────────────────┴───────────────────────────────────────┐
│                Android (Kotlin)                              │
│           CloudflaredTunnelPlugin                            │
│                     │                                        │
│              cloudflared.aar                                 │
│         (Go library via gomobile)                            │
│    ┌────────────────┴────────────────┐                       │
│    │                                 │                       │
│  Local HTTP Server           Cloudflared Tunnel              │
│  (port 8080)                 (connects to CF edge)           │
└─────────────────────────────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────┐
│                 Internet (via Cloudflare)                    │
│                                                              │
│   https://your-tunnel.trycloudflare.com                     │
│                      │                                       │
│                      ▼                                       │
│              Your mobile device                              │
│           (serving files locally)                            │
└─────────────────────────────────────────────────────────────┘
```

## Fitur

- **Local HTTP Server**: Serve file dari direktori yang ditentukan
- **Request Logging**: Log lengkap semua request (method, path, headers, body, status code, duration)
- **Cloudflared Tunnel**: Koneksi ke Cloudflare edge network
- **Real-time Events**: Stream events untuk state changes dan request logs
- **Combined API**: Start server + tunnel dalam satu panggilan

## Prasyarat

1. **Go 1.21+** - untuk build mobile library
2. **gomobile** - untuk generate AAR/Framework
3. **Flutter 3.3+** - untuk build aplikasi
4. **Android NDK** - untuk build Android (akan didownload otomatis oleh gomobile)

## Build AAR dengan gomobile

### 1. Install gomobile

```bash
go install golang.org/x/mobile/cmd/gomobile@latest
go install golang.org/x/mobile/cmd/gobind@latest
```

### 2. Build AAR

Dari direktori root cloudflared:

```bash
cd mobile
./build.sh android
```

Script ini akan:
1. Build AAR dengan gomobile
2. Extract classes.jar dan JNI libs
3. Copy ke Flutter plugin secara otomatis

## Instalasi di Flutter Project

### 1. Tambahkan dependency di pubspec.yaml

```yaml
dependencies:
  cloudflared_tunnel:
    path: path/to/cloudflared-master/flutter_plugin/cloudflared_tunnel
```

### 2. Pastikan build sudah dijalankan

Pastikan file-file berikut sudah ada (otomatis dibuat oleh `./build.sh android`):
- `flutter_plugin/cloudflared_tunnel/android/libs/cloudflared-classes.jar`
- `flutter_plugin/cloudflared_tunnel/android/src/main/jniLibs/` (berisi native libraries)

## Penggunaan

### Quick Start - Start All

```dart
import 'package:cloudflared_tunnel/cloudflared_tunnel.dart';

final plugin = CloudflaredTunnel();

// Start server dan tunnel sekaligus
await plugin.startAll(
  token: 'your-tunnel-token',
  rootDir: '/path/to/serve',
  port: 8080,
);

// Sekarang file Anda bisa diakses publik via Cloudflare!

// Stop semua
await plugin.stopAll();
```

### Manual Control

```dart
final plugin = CloudflaredTunnel();

// 1. Start local server dulu
await plugin.startServer(
  rootDir: '/path/to/serve',
  port: 8080,
);

// Dapatkan URL server
final serverUrl = await plugin.getServerUrl();
print('Server running at: $serverUrl'); // http://127.0.0.1:8080

// 2. Start tunnel dengan server sebagai origin
await plugin.startTunnel(
  token: 'your-tunnel-token',
  originUrl: serverUrl,
);

// 3. Listen ke request logs
plugin.requestLogStream.listen((log) {
  print('${log.method} ${log.path} - ${log.statusCode} (${log.durationMs}ms)');
  print('  User-Agent: ${log.userAgent}');
  print('  Headers: ${log.headers}');
  if (log.body.isNotEmpty) {
    print('  Body: ${log.body}');
  }
});

// 4. Stop ketika selesai
await plugin.stopTunnel();
await plugin.stopServer();

// Cleanup
plugin.dispose();
```

### Listen ke State Changes

```dart
// Tunnel state
plugin.tunnelStateStream.listen((state) {
  print('Tunnel: ${state.name}'); // disconnected, connecting, connected, etc.
});

// Server state
plugin.serverStateStream.listen((state) {
  print('Server: ${state.name}'); // stopped, starting, running, error
});

// Errors
plugin.tunnelErrorStream.listen((error) {
  print('Tunnel Error: $error');
});

plugin.serverErrorStream.listen((error) {
  print('Server Error: $error');
});
```

### Get Request Logs

```dart
// Get all stored logs
final logs = await plugin.getRequestLogs();
for (final log in logs) {
  print('${log.timestamp}: ${log.method} ${log.path}');
}

// Clear logs
await plugin.clearRequestLogs();
```

### List Directory

```dart
final files = await plugin.listDirectory('/path/to/dir');
for (final file in files) {
  print('${file.name} - ${file.isDir ? "DIR" : "${file.size} bytes"}');
}
```

## API Reference

### CloudflaredTunnel

#### Tunnel Methods

| Method | Description |
|--------|-------------|
| `startTunnel({token, originUrl, haConnections, enablePostQuantum})` | Start Cloudflare tunnel |
| `stopTunnel()` | Stop tunnel |
| `getTunnelState()` | Get current tunnel state |
| `validateToken(token)` | Validate token tanpa start |
| `getVersion()` | Get library version |
| `isTunnelRunning()` | Check if tunnel running |

#### Server Methods

| Method | Description |
|--------|-------------|
| `startServer({rootDir, port})` | Start local HTTP server |
| `stopServer()` | Stop server |
| `getServerState()` | Get current server state |
| `getServerUrl()` | Get server URL |
| `getRequestLogs()` | Get all stored request logs |
| `clearRequestLogs()` | Clear request logs |
| `listDirectory(path)` | List directory contents |

#### Combined Methods

| Method | Description |
|--------|-------------|
| `startAll({token, rootDir, port, ...})` | Start server + tunnel |
| `stopAll()` | Stop tunnel + server |

#### Streams

| Stream | Type | Description |
|--------|------|-------------|
| `tunnelStateStream` | `Stream<TunnelState>` | Tunnel state changes |
| `serverStateStream` | `Stream<ServerState>` | Server state changes |
| `requestLogStream` | `Stream<RequestLog>` | Real-time request logs |
| `tunnelErrorStream` | `Stream<String>` | Tunnel errors |
| `serverErrorStream` | `Stream<String>` | Server errors |

### TunnelState

```dart
enum TunnelState {
  disconnected,  // 0
  connecting,    // 1
  connected,     // 2
  reconnecting,  // 3
  error,         // 4
}
```

### ServerState

```dart
enum ServerState {
  stopped,   // 0
  starting,  // 1
  running,   // 2
  error,     // 3
}
```

### RequestLog

```dart
class RequestLog {
  final String timestamp;
  final String method;      // GET, POST, etc.
  final String path;        // /index.html
  final String remoteAddr;  // IP address
  final String userAgent;
  final String contentType;
  final Map<String, String> headers;
  final Map<String, String> query;
  final String body;        // Request body (max 10KB)
  final int statusCode;     // 200, 404, etc.
  final int durationMs;     // Response time in ms
}
```

## Mendapatkan Tunnel Token

1. Buka [Cloudflare Zero Trust Dashboard](https://one.dash.cloudflare.com)
2. Pergi ke **Access** > **Tunnels**
3. Buat tunnel baru atau pilih yang sudah ada
4. Copy token dari halaman konfigurasi tunnel

## Troubleshooting

### AAR tidak ditemukan

Pastikan:
1. File `cloudflared.aar` ada di `android/libs/`
2. `build.gradle` sudah dikonfigurasi dengan `flatDir { dirs 'libs' }`

### Build gagal

1. Pastikan Go dan gomobile terinstall dengan benar
2. Jalankan `gomobile init` sebelum build
3. Pastikan Android NDK terinstall

### Server tidak bisa start

1. Pastikan direktori yang di-serve valid dan ada
2. Pastikan port tidak digunakan aplikasi lain
3. Check permission storage jika serve dari external storage

### Tunnel tidak connect

1. Pastikan token valid (gunakan `validateToken()`)
2. Cek koneksi internet
3. Pastikan server sudah running sebelum start tunnel
4. Lihat error di `tunnelErrorStream`

## Limitasi

- Saat ini hanya support Android
- iOS support dalam pengembangan
- Request body logging max 10KB
- Max 1000 request logs disimpan

## License

Apache 2.0 - Lihat file LICENSE untuk detail.
