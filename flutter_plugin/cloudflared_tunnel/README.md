# Cloudflared Tunnel Flutter Plugin

[![pub package](https://img.shields.io/pub/v/cloudflared_tunnel.svg)](https://pub.dev/packages/cloudflared_tunnel)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Flutter plugin for [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/) (cloudflared). Expose your local servers to the internet securely via Cloudflare's global network.

## Features

- **Cloudflare Tunnel** - Connect to Cloudflare's edge network with token-based authentication
- **Built-in HTTP Server** - Optional Go-based file server with request logging
- **Works with Any Server** - Use with Shelf, dart:io HttpServer, or any local HTTP server
- **Background Service** - Android foreground service keeps tunnel running even when app is closed (Termux-like behavior)
- **Real-time Events** - Stream tunnel state changes, server events, and request logs
- **Pre-built Binaries** - No need to build Go code or install gomobile

## Platform Support

| Platform | Status |
|----------|--------|
| Android  | ✅ Full support (API 21+) |
| iOS      | ❌ Not supported in this version |

### Android Architecture Support

| Architecture | Supported |
|--------------|-----------|
| arm64-v8a    | ✅ Yes (most modern devices) |
| armeabi-v7a  | ✅ Yes (older 32-bit devices) |
| x86_64       | ❌ No (emulator only) |
| x86          | ❌ No (emulator only) |

> **Note**: x86/x86_64 are excluded to keep package size under pub.dev limits. Most physical Android devices use ARM architecture. If you need x86 support for emulators, build from source using gomobile.

## Installation

Add this to your `pubspec.yaml`:

```yaml
dependencies:
  cloudflared_tunnel: ^1.0.0
```

Then run:

```bash
flutter pub get
```

That's it! The native libraries are pre-built and included in the package.

## Quick Start

### Option 1: Use with Built-in Go Server

```dart
import 'package:cloudflared_tunnel/cloudflared_tunnel.dart';

final plugin = CloudflaredTunnel();

// Start server and tunnel together
await plugin.startAll(
  token: 'your-tunnel-token',
  rootDir: '/path/to/serve',
  port: 8080,
);

// Your files are now accessible via Cloudflare!
// Listen to request logs
plugin.requestLogStream.listen((log) {
  print('${log.method} ${log.path} - ${log.statusCode}');
});

// Stop when done
await plugin.stopAll();
```

### Option 2: Use with Dart Shelf Server

```dart
import 'package:cloudflared_tunnel/cloudflared_tunnel.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;

// Start your Shelf server first
final handler = const shelf.Pipeline()
    .addMiddleware(shelf.logRequests())
    .addHandler((request) => shelf.Response.ok('Hello from Dart!'));

final server = await shelf_io.serve(handler, '127.0.0.1', 3000);

// Then start tunnel pointing to your Shelf server
final plugin = CloudflaredTunnel();
await plugin.startTunnel(
  token: 'your-tunnel-token',
  originUrl: 'http://127.0.0.1:3000',
);

// Your Shelf server is now publicly accessible!
```

## Android Setup

### Notification Permission (Android 13+)

For Android 13 and above, request notification permission before starting the tunnel:

```dart
// Check and request permission
final hasPermission = await plugin.hasNotificationPermission();
if (!hasPermission) {
  await plugin.requestNotificationPermission();
}

// Then start tunnel
await plugin.startTunnel(...);
```

### Foreground Service

The plugin runs as a foreground service on Android, which means:
- Tunnel survives when app is closed or swiped from recent apps
- A persistent notification shows tunnel status
- Users can stop the tunnel from the notification
- Service restarts automatically if killed by system

## API Reference

### Tunnel Methods

```dart
// Start tunnel with Cloudflare token
await plugin.startTunnel(
  token: 'your-token',           // Required: Cloudflare tunnel token
  originUrl: 'http://127.0.0.1:8080',  // Local server to proxy to
);

// Stop tunnel
await plugin.stopTunnel();

// Check tunnel state
final state = await plugin.getTunnelState();
final isRunning = await plugin.isTunnelRunning();

// Validate token without starting
final tunnelId = await plugin.validateToken('your-token');

// Get cloudflared version
final version = await plugin.getVersion();
```

### Server Methods (Built-in Go Server)

```dart
// Start local HTTP file server
await plugin.startServer(
  rootDir: '/path/to/serve',  // Directory to serve
  port: 8080,                 // Port number
);

// Stop server
await plugin.stopServer();

// Get server info
final state = await plugin.getServerState();
final url = await plugin.getServerUrl();  // e.g., "http://127.0.0.1:8080"

// Request logs
final logs = await plugin.getRequestLogs();
await plugin.clearRequestLogs();

// List directory
final files = await plugin.listDirectory('/path');
```

### Service Methods

```dart
// Check if background service is running
final isRunning = await plugin.isServiceRunning();

// Stop service completely (stops tunnel and server)
await plugin.stopService();

// Notification permission (Android 13+)
final has = await plugin.hasNotificationPermission();
final granted = await plugin.requestNotificationPermission();
```

### Streams

```dart
// Tunnel state changes
plugin.tunnelStateStream.listen((TunnelState state) {
  // disconnected, connecting, connected, reconnecting, error
});

// Server state changes
plugin.serverStateStream.listen((ServerState state) {
  // stopped, starting, running, error
});

// Request logs (real-time)
plugin.requestLogStream.listen((RequestLog log) {
  print('${log.method} ${log.path} - ${log.statusCode}');
});

// Errors
plugin.tunnelErrorStream.listen((String error) { });
plugin.serverErrorStream.listen((String error) { });
```

## Getting a Tunnel Token

1. Go to [Cloudflare Zero Trust Dashboard](https://one.dash.cloudflare.com)
2. Navigate to **Networks** > **Tunnels**
3. Create a new tunnel or select existing one
4. Copy the token from the tunnel configuration page

## Troubleshooting

### Tunnel won't connect

1. Verify your token is valid using `validateToken()`
2. Check internet connectivity
3. Ensure your local server is running before starting tunnel
4. Listen to `tunnelErrorStream` for detailed errors

### Notification not showing (Android)

1. Request notification permission on Android 13+
2. Check notification settings in system app settings
3. Ensure FOREGROUND_SERVICE permission in AndroidManifest

### Release build crashes

The plugin includes ProGuard rules automatically. If you still have issues:

```groovy
// android/app/build.gradle
android {
    buildTypes {
        release {
            minifyEnabled true
            proguardFiles getDefaultProguardFile('proguard-android.txt'), 'proguard-rules.pro'
        }
    }
}
```

## Example App

See the [example](example/) directory for a complete demo app showing:
- Go server mode (static file serving)
- Shelf server mode (dynamic Dart routes)
- Auto-save/load tunnel token
- Request log viewer

## License

MIT License - see [LICENSE](LICENSE) for details.

This plugin includes cloudflared which is licensed under the Apache License 2.0.

## Contributing

Contributions are welcome! Please read our contributing guidelines before submitting PRs.

## Acknowledgments

- [Cloudflare](https://www.cloudflare.com/) for the amazing cloudflared tunnel
- [gomobile](https://pkg.go.dev/golang.org/x/mobile/cmd/gomobile) for Go mobile bindings
