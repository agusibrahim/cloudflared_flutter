import 'package:flutter_test/flutter_test.dart';
import 'package:cloudflared_tunnel/cloudflared_tunnel.dart';
import 'package:cloudflared_tunnel/cloudflared_tunnel_platform_interface.dart';
import 'package:cloudflared_tunnel/cloudflared_tunnel_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockCloudflaredTunnelPlatform
    with MockPlatformInterfaceMixin
    implements CloudflaredTunnelPlatform {

  @override
  Future<String> getVersion() => Future.value('2024.1.1');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final CloudflaredTunnelPlatform initialPlatform = CloudflaredTunnelPlatform.instance;

  test('$MethodChannelCloudflaredTunnel is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelCloudflaredTunnel>());
  });

  test('getVersion', () async {
    CloudflaredTunnel cloudflaredTunnelPlugin = CloudflaredTunnel();
    MockCloudflaredTunnelPlatform fakePlatform = MockCloudflaredTunnelPlatform();
    CloudflaredTunnelPlatform.instance = fakePlatform;

    expect(await cloudflaredTunnelPlugin.getVersion(), '2024.1.1');
  });
}
