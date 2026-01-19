# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2024-01-19

### Added
- Initial release of cloudflared_tunnel Flutter plugin
- Cloudflare Tunnel support with token-based authentication
- Built-in Go HTTP file server with request logging
- Android foreground service for background operation (Termux-like behavior)
- Tunnel survives app closure and notification dismissal
- Real-time tunnel state streaming (connecting, connected, disconnected, error)
- Real-time server state streaming
- Request log streaming for the built-in HTTP server
- Directory listing API
- Notification permission handling for Android 13+
- ProGuard rules for release builds
- Shelf server example (Dart-based HTTP server)

### Features
- **Tunnel Management**
  - `startTunnel()` - Start tunnel with Cloudflare token
  - `stopTunnel()` - Stop the running tunnel
  - `getTunnelState()` - Get current tunnel state
  - `isTunnelRunning()` - Check if tunnel is running
  - `validateToken()` - Validate tunnel token without starting

- **Built-in Server** (Optional)
  - `startServer()` - Start local HTTP file server
  - `stopServer()` - Stop the server
  - `getServerState()` - Get server state
  - `getServerUrl()` - Get the server URL
  - `getRequestLogs()` - Get stored request logs
  - `clearRequestLogs()` - Clear request logs
  - `listDirectory()` - List directory contents

- **Service Management**
  - `isServiceRunning()` - Check if background service is running
  - `stopService()` - Stop the background service completely
  - `requestNotificationPermission()` - Request notification permission (Android 13+)
  - `hasNotificationPermission()` - Check notification permission

- **Convenience Methods**
  - `startAll()` - Start both server and tunnel
  - `stopAll()` - Stop both tunnel and server

### Platforms
- Android (API 21+) - Full support with foreground service
- iOS - Coming soon

### Notes
- The AAR is pre-built and included in the package
- No need to build Go code or run gomobile
- Works with both Go server and Dart-based servers (like Shelf)
