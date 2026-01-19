import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cloudflared_tunnel/cloudflared_tunnel_method_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  MethodChannelCloudflaredTunnel platform = MethodChannelCloudflaredTunnel();
  const MethodChannel channel = MethodChannel('cloudflared_tunnel');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (MethodCall methodCall) async {
        return '42';
      },
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  test('getPlatformVersion', () async {
    expect(await platform.getPlatformVersion(), '42');
  });
}
