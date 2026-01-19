# Cloudflared Flutter

Flutter plugin for [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/) (cloudflared) with optional local HTTP server.

This project uses the official [cloudflared](https://github.com/cloudflare/cloudflared) source code as a git submodule, allowing easy updates to the latest version.

## Features

- Cloudflared tunnel connection to Cloudflare's global network
- Optional: Built-in Go HTTP file server with request logging
- Tunnel can be used standalone with any Dart HTTP server (shelf, etc.)
- Real-time connection status and logging

## Project Structure

```
cloudflared_flutter/
├── cloudflared/              # Git submodule from cloudflare/cloudflared
├── mobile/                   # Go wrapper for mobile (gomobile bindings)
│   ├── cloudflared.go        # Tunnel wrapper
│   ├── server.go             # Optional HTTP server
│   ├── build.sh              # Build script
│   └── go.mod                # Go module (uses cloudflared submodule)
└── flutter_plugin/           # Flutter plugin
    └── cloudflared_tunnel/
        ├── lib/              # Dart API
        ├── android/          # Android platform code
        ├── ios/              # iOS platform code (planned)
        └── example/          # Example app
```

## Getting Started

### Prerequisites

- [Go](https://golang.org/dl/) 1.22+
- [gomobile](https://pkg.go.dev/golang.org/x/mobile/cmd/gomobile)
- [Flutter](https://flutter.dev/) 3.0+
- Android SDK (for Android builds)
- Xcode (for iOS builds)

### Install gomobile

```bash
go install golang.org/x/mobile/cmd/gomobile@latest
gomobile init
```

### Clone with submodules

```bash
git clone --recursive https://github.com/YOUR_USERNAME/cloudflared_flutter.git
cd cloudflared_flutter

# Or if already cloned without --recursive:
git submodule update --init --recursive
```

### Update cloudflared to latest

```bash
cd cloudflared
git fetch origin
git checkout origin/master  # or specific tag
cd ..
git add cloudflared
git commit -m "Update cloudflared submodule"
```

### Build

```bash
# Build Android AAR
cd mobile
./build.sh android

# Build iOS Framework
./build.sh ios

# Build both
./build.sh all
```

### Run Example App

```bash
cd flutter_plugin/cloudflared_tunnel/example
flutter pub get
flutter run
```

## Usage

### Tunnel Only (with your own Dart server)

```dart
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:cloudflared_tunnel/cloudflared_tunnel.dart';

// Start your Dart HTTP server first
final handler = shelf.Pipeline()
    .addMiddleware(shelf.logRequests())
    .addHandler((request) => shelf.Response.ok('Hello from Dart!'));
final server = await shelf_io.serve(handler, '127.0.0.1', 3000);

// Then start tunnel pointing to your Dart server
final plugin = CloudflaredTunnel();
await plugin.startTunnel(
  token: 'your-tunnel-token',
  originUrl: 'http://127.0.0.1:3000',
);

// Your Dart server is now publicly accessible via Cloudflare!
```

### Built-in Go Server + Tunnel

```dart
final plugin = CloudflaredTunnel();

// Start the built-in Go file server
await plugin.startServer(
  rootDir: '/path/to/serve',
  port: 8080,
);

// Start tunnel with the Go server as origin
await plugin.startTunnel(
  token: 'your-tunnel-token',
  originUrl: 'http://127.0.0.1:8080',
);

// Listen to request logs from Go server
plugin.requestLogStream.listen((log) {
  print('${log.method} ${log.path} - ${log.statusCode}');
});
```

### Convenience Method

```dart
final plugin = CloudflaredTunnel();
await plugin.startAll(
  token: 'your-tunnel-token',
  rootDir: '/path/to/serve',
  port: 8080,
);
```

## Getting a Tunnel Token

1. Go to [Cloudflare Zero Trust Dashboard](https://one.dash.cloudflare.com/)
2. Navigate to Networks > Tunnels
3. Create a new tunnel
4. Copy the tunnel token

## License

This project is licensed under the Apache 2.0 License - same as cloudflared.

## Acknowledgments

- [Cloudflare](https://www.cloudflare.com/) for cloudflared
- [gomobile](https://pkg.go.dev/golang.org/x/mobile/cmd/gomobile) for Go to mobile bindings
