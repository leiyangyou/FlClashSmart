import 'dart:convert';
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
  Set<String>? profileKeys,
  bool overrideDns = true,
  bool appendSystemDns = true,
  bool safeMode = false,
}) {
  return makeRealProfileTask(
    MakeRealProfileState(
      profilesPath: '/profiles',
      profileId: 3,
      rawConfig: rawConfig,
      realPatchConfig: _patchConfig,
      overrideDns: overrideDns,
      overrideNtp: true,
      appendSystemDns: appendSystemDns,
      proxyGroups: const [],
      rules: const [],
      addedRules: const [],
      defaultUA: 'Default-UA',
      authentication: const ['app:secret'],
      useProfileSettings: useProfileSettings,
      profileKeys: profileKeys ?? rawConfig.keys.toSet(),
      safeMode: safeMode,
    ),
  );
}

Future<YamlMap> _config(
  Map<String, dynamic> rawConfig, {
  bool useProfileSettings = true,
  bool overrideDns = true,
  bool appendSystemDns = true,
}) async {
  final result = await _build(
    rawConfig,
    useProfileSettings: useProfileSettings,
    overrideDns: overrideDns,
    appendSystemDns: appendSystemDns,
  );
  return loadYaml(result.yaml) as YamlMap;
}

String _golden(String name, {String extension = 'yaml'}) =>
    File('$_fixtureDir/$name.$extension').readAsStringSync();

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
      expect(config['allow-lan'], false);
      expect(config['log-level'], 'warning');
      expect(config['find-process-mode'], 'strict');
      expect(config['interface-name'], 'en9');
      expect(config['tcp-concurrent'], false);
      expect(config['unified-delay'], false);
      expect(config['keep-alive-interval'], 90);
      expect(config['global-ua'], 'Profile-UA');
      expect(config['dns'], {
        'enable': true,
        'listen': '0.0.0.0:1053',
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

    test(
      'a key the core filled in but the profile left out is the app\'s',
      () async {
        final coreFilled = {
          ..._fullProfile(),
          'dns': {
            'enable': false,
            'nameserver': ['https://doh.pub/dns-query'],
          },
        };
        final off = await _build(coreFilled, profileKeys: {});
        final on = await _build(
          coreFilled,
          useProfileSettings: true,
          profileKeys: {'proxies', 'rules'},
        );

        expect(on.profileOwnedKeys, isEmpty);
        expect(on.yaml, off.yaml);
      },
    );

    for (final (name, block) in [
      (
        'a disabled block',
        {
          'enable': false,
          'nameserver': ['9.9.9.9'],
        },
      ),
      ('a block without enable', {'enhanced-mode': 'redir-host'}),
      ('an empty block', <String, dynamic>{}),
    ]) {
      test('$name from the profile is kept as is', () async {
        final config = await _config({'dns': block}, overrideDns: false);

        expect(config['dns'], block);
      });
    }
  });

  group('the dns block', () {
    for (final (name, block) in [
      ('an empty nameserver list', {'enable': true, 'nameserver': []}),
      ('no nameserver list', {'enable': true}),
    ]) {
      for (final (useProfileSettings, overrideDns) in [
        (true, false),
        (true, true),
        (false, true),
      ]) {
        test('an enabled dns block with $name resolves through the app\'s '
            'nameservers, toggle ${useProfileSettings ? 'on' : 'off'}, '
            'Override DNS ${overrideDns ? 'on' : 'off'}', () async {
          final config = await _config(
            {'dns': block},
            useProfileSettings: useProfileSettings,
            overrideDns: overrideDns,
            appendSystemDns: false,
          );

          expect(config['dns']['enable'], true);
          expect(config['dns']['nameserver'], ['1.1.1.1']);
        });
      }
    }

    for (final overrideDns in [false, true]) {
      test('a profile dns block listens where the app would with Override DNS '
          '${overrideDns ? 'on' : 'off'}', () async {
        final profile = {
          'dns': {
            'enable': true,
            'listen': '0.0.0.0:53',
            'nameserver': ['9.9.9.9'],
          },
        };
        final off = await _config(
          profile,
          useProfileSettings: false,
          overrideDns: overrideDns,
        );
        final on = await _config(profile, overrideDns: overrideDns);

        expect(on['dns']['listen'], off['dns']['listen']);
        expect(
          on['dns']['listen'],
          overrideDns ? '0.0.0.0:1053' : '0.0.0.0:53',
        );
        expect(on['dns']['nameserver'], ['9.9.9.9']);
      });
    }

    for (final safeMode in [false, true]) {
      test('a dns block a script removed is the app\'s, '
          'safe mode $safeMode', () async {
        Future<RealProfile> build(bool useProfileSettings) => _build(
          {'ipv6': true},
          useProfileSettings: useProfileSettings,
          profileKeys: {'ipv6', 'dns'},
          safeMode: safeMode,
        );
        final on = await build(true);
        final off = await build(false);
        final onDns = (loadYaml(on.yaml) as YamlMap)['dns'];

        expect(on.profileOwnedKeys, {'ipv6'});
        expect(onDns, (loadYaml(off.yaml) as YamlMap)['dns']);
        expect(onDns['nameserver'], ['1.1.1.1', 'system://']);
        expect(onDns['listen'], safeMode ? '' : '0.0.0.0:1053');
      });
    }
  });

  group('the updateConfig payload', () {
    Map<String, dynamic> payload(Set<String> profileOwnedKeys) => _patchConfig
        .toUpdateParams(
          routeMode: RouteMode.config,
          authentication: const ['app:secret'],
          profileOwnedKeys: profileOwnedKeys,
        )
        .toJson();

    test('with the toggle off matches its golden byte for byte', () {
      final encoded = const JsonEncoder.withIndent('  ').convert(payload({}));

      expect('$encoded\n', _golden('update_params', extension: 'json'));
    });

    test('leaves only the profile-owned keys unchanged', () {
      final app = payload({});
      final owned = payload(profilePreferenceKeys);

      for (final key in app.keys) {
        final leftUnchanged = {
          'ipv6',
          'find-process-mode',
          'tcp-concurrent',
          'unified-delay',
        }.contains(key);
        expect(owned[key], leftUnchanged ? isNull : app[key], reason: key);
      }
    });
  });
}
