import 'package:flutter_test/flutter_test.dart';
import 'package:mira_shell/network/netbird.dart';
import 'package:mira_shell/network/netbird_cli.dart';

void main() {
  test('reads a signed-out daemon: real 0.66 output from a host whose login expired', () {
    final NetbirdStatus s = CliNetbird.parseStatus('''
{"daemonStatus": "NeedsLogin",
 "management": {"url": "https://api.netbird.io:443", "connected": false,
   "error": "rpc error: code = PermissionDenied desc = peer login has expired, please log in once more"},
 "signal": {"url": "https://signal.netbird.io:443", "connected": false, "error": "reset connection"},
 "netbirdIp": "", "fqdn": "", "peers": {"total": 0, "connected": 0, "details": null}}''');
    expect(s.state, NetbirdState.signedOut);
    expect(s.ip, isNull);
    expect(s.managementUrl, 'https://api.netbird.io:443');
    expect(s.detail, contains('login has expired'));
  });

  test('reads a connected daemon and drops the prefix length from the address', () {
    final NetbirdStatus s = CliNetbird.parseStatus('''
{"daemonStatus": "Connected", "management": {"url": "https://api.netbird.io:443", "connected": true, "error": ""},
 "netbirdIp": "100.92.14.7/16", "fqdn": "mira.netbird.cloud", "peers": {"total": 4, "connected": 3, "details": []}}''');
    expect(s.state, NetbirdState.connected);
    expect(s.ip, '100.92.14.7');
    expect(s.peersConnected, 3);
    expect(s.peersTotal, 4);
    expect(s.detail, isNull);
  });

  test('sign-in line with the code in the URL: the QR carries it, the tiles show it', () {
    final LoginCode c = CliNetbird.parseLoginLine('https://login.netbird.io/activate?user_code=KXQM-2PLD')!;
    expect(c.code, 'KXQM-2PLD');
    expect(c.url.toString(), 'https://login.netbird.io/activate');
    expect(c.completeUrl.toString(), 'https://login.netbird.io/activate?user_code=KXQM-2PLD');
  });

  test('sign-in line with a separate code', () {
    final LoginCode c =
        CliNetbird.parseLoginLine('https://idp.example/device and enter the code WDJB-MJHT to authenticate.')!;
    expect(c.code, 'WDJB-MJHT');
    expect(c.url.toString(), 'https://idp.example/device');
    expect(c.completeUrl, isNull);
  });
}
