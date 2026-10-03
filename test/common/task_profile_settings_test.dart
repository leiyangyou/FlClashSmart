import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

const _fixtureDir = 'test/fixtures/profile_settings';

Map<String, dynamic> _fullProfile() => {
  'ipv6': true,
  'allow-lan': true,
  'log-level': 'debug',
  'find-process-mode': 'strict',
  'interface-name': 'en9',
  'tcp-concurrent': false,
  'unified-delay': false,
  'keep-alive-interval': 90,
  'global-ua': 'Profile-UA',
  'dns': {
    'enable': true,
    'listen': '0.0.0.0:53',
    'enhanced-mode': 'redir-host',
    'nameserver': ['9.9.9.9'],
  },
  'ntp': {'enable': true, 'server': 'ntp.aliyun.com', 'write-to-system': true},
  'mixed-port': 1,
  'port': 2,
  'socks-port': 3,
  'redir-port': 4,
  'tproxy-port': 5,
  'mode': 'global',
  'tun': {'enable': true, 'stack': 'system', 'device': 'utun99'},
  'geox-url': {'geoip': 'https://profile.example/geoip.dat'},
  'lgbm-url': 'https://profile.example/model.bin',
  'geo-auto-update': true,
  'geo-update-interval': 1,
  'external-controller': '0.0.0.0:9090',
  'external-ui': 'ui',
  'external-ui-url': 'https://profile.example/ui.zip',
  'authentication': ['profile:secret'],
  'skip-auth-prefixes': ['127.0.0.1/32'],
  'profile': {'store-selected': true},
  'hosts': {'profile.local': '10.0.0.1'},
  'rules': ['MATCH,DIRECT'],
};

const _patchConfig = PatchClashConfig(
  mixedPort: 7893,
  socksPort: 7891,
  port: 7890,
  redirPort: 7892,
  tproxyPort: 7894,
  allowLan: false,
  logLevel: LogLevel.warning,
  findProcessMode: FindProcessMode.always,
  interfaceNameMode: InterfaceNameMode.custom,
  interfaceName: 'eth0',
  keepAliveInterval: 15,
  tcpConcurrent: true,
  unifiedDelay: true,
  globalUa: 'App-UA',
  dns: Dns(nameserver: ['1.1.1.1']),
  dnsOverrideKeys: {DnsOverrideKey.nameserver, DnsOverrideKey.listen},
  ntp: Ntp(server: 'time.cloudflare.com', interval: 60),
  ntpOverrideKeys: {NtpOverrideKey.server, NtpOverrideKey.interval},
  hosts: {'app.local': '10.0.0.2'},
);

Future<RealProfile> _build(
  Map<String, dynamic> rawConfig, {
  bool useProfileSettings = false,
}) {
  return makeRealProfileTask(
    MakeRealProfileState(
      profilesPath: '/profiles',
      profileId: 3,
      rawConfig: rawConfig,
      realPatchConfig: _patchConfig,
      overrideDns: true,
      overrideNtp: true,
      appendSystemDns: true,
      proxyGroups: const [],
      rules: const [],
      addedRules: const [],
      defaultUA: 'Default-UA',
      authentication: const ['app:secret'],
      useProfileSettings: useProfileSettings,
    ),
  );
}

Future<YamlMap> _config(
  Map<String, dynamic> rawConfig, {
  bool useProfileSettings = true,
}) async {
  final result = await _build(
    rawConfig,
    useProfileSettings: useProfileSettings,
  );
  return loadYaml(result.yaml) as YamlMap;
}

String _golden(String name) =>
    File('$_fixtureDir/$name.yaml').readAsStringSync();

void main() {
  group('the generated config with the toggle off', () {
    for (final (name, profile) in [
      ('full_profile', _fullProfile),
      ('empty_profile', () => <String, dynamic>{}),
    ]) {
      test('matches the $name golden byte for byte', () async {
        final result = await _build(profile());
        expect(result.yaml, _golden(name));
        expect(result.profileOwnedKeys, isEmpty);
      });
    }
  });

  test('no plumbing key can be handed to the profile', () {
    expect(profilePreferenceKeys.intersection(appPlumbingKeys), isEmpty);
    expect(profilePreferenceKeys, {
      'ipv6',
      'dns',
      'ntp',
      'allow-lan',
      'log-level',
      'find-process-mode',
      'interface-name',
      'tcp-concurrent',
      'unified-delay',
      'keep-alive-interval',
      'global-ua',
    });
  });

  group('with the toggle on', () {
    test('the profile keeps every preference it sets', () async {
      final result = await _build(_fullProfile(), useProfileSettings: true);
      final config = loadYaml(result.yaml) as YamlMap;

      expect(result.profileOwnedKeys, profilePreferenceKeys);
      expect(config['ipv6'], true);
      expect(config['allow-lan'], true);
      expect(config['log-level'], 'debug');
      expect(config['find-process-mode'], 'strict');
      expect(config['interface-name'], 'en9');
      expect(config['tcp-concurrent'], false);
      expect(config['unified-delay'], false);
      expect(config['keep-alive-interval'], 90);
      expect(config['global-ua'], 'Profile-UA');
      expect(config['dns'], {
        'enable': true,
        'listen': '0.0.0.0:53',
        'enhanced-mode': 'redir-host',
        'nameserver': ['9.9.9.9'],
      });
      expect(config['ntp'], {
        'enable': true,
        'server': 'ntp.aliyun.com',
        'write-to-system': true,
      });
    });

    test('the app still owns the plumbing', () async {
      final config = await _config(_fullProfile());
      final golden = loadYaml(_golden('full_profile')) as YamlMap;

      for (final key in appPlumbingKeys.where(golden.containsKey)) {
        expect(config[key], golden[key], reason: key);
      }
    });

    test('a preference the profile leaves out is still written', () async {
      final result = await _build({}, useProfileSettings: true);

      expect(result.yaml, _golden('empty_profile'));
      expect(result.profileOwnedKeys, isEmpty);

      final config = await _config({'ipv6': true});
      expect(config['ipv6'], true);
      expect(config['log-level'], 'warning');
      expect(config['global-ua'], 'App-UA');
      expect(config['dns']['nameserver'], ['1.1.1.1', 'system://']);
      expect(config['ntp']['server'], 'time.cloudflare.com');
    });

    test('an enabled DNS block without nameservers still resolves', () async {
      final config = await _config({
        'dns': {'enable': true, 'enhanced-mode': 'redir-host'},
      });

      expect(config['dns']['enhanced-mode'], 'redir-host');
      expect(config['dns']['nameserver'], defaultDns.nameserver);
      expect(config['dns']['listen'], isNull);
    });

    test('a disabled DNS block is still turned on', () async {
      final config = await _config({
        'dns': {
          'enable': false,
          'nameserver': ['9.9.9.9'],
          'listen': '0.0.0.0:53',
        },
      });

      expect(config['dns']['enable'], true);
      expect(config['dns']['nameserver'], defaultDns.nameserver);
      expect(config['dns']['listen'], '0.0.0.0:53');
    });
  });
}
