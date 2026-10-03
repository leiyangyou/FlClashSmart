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
  'geodata-loader': 'standard',
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
        expect(result.profileOwned.keys, isEmpty);
      });
    }
  });

  group('with the toggle on', () {
    test('the profile keeps every key the app writes verbatim', () async {
      final profile = _fullProfile();
      final result = await _build(profile, useProfileSettings: true);
      final config = loadYaml(result.yaml) as YamlMap;
      final off = loadYaml((await _build(profile)).yaml) as YamlMap;
      final stated = profile.keys.toSet().difference(overwriteKeys);
      final appWritten = (loadYaml(_golden('empty_profile')) as YamlMap).keys
          .cast<String>()
          .toSet()
          .difference(overwriteKeys);

      expect(stated, containsAll(appWritten));
      expect(result.profileOwned.keys, stated);
      for (final key in stated) {
        expect(jsonDecode(jsonEncode(config[key])), profile[key], reason: key);
        expect(
          jsonDecode(jsonEncode(off[key])),
          isNot(profile[key]),
          reason: '$key: the fixture must differ from the app\'s value',
        );
      }
    });

    for (final useProfileSettings in [false, true]) {
      test('provider paths are confined and sniffer ports normalised, '
          'toggle ${useProfileSettings ? 'on' : 'off'}', () async {
        // Decoded like the core's reply, so nested values are dynamic.
        final config = await _config(
          jsonDecode(
            jsonEncode({
              'proxy-providers': {
                'remote': {
                  'type': 'http',
                  'url': 'https://profile.example/proxies.yaml',
                  'path': '/etc/passwd',
                },
                'local': {'type': 'file', 'path': '/etc/passwd'},
              },
              'rule-providers': {
                'remote': {
                  'type': 'http',
                  'url': 'https://profile.example/rules.yaml',
                  'path': '/etc/passwd',
                },
              },
              'sniffer': {
                'sniff': {
                  'HTTP': {
                    'ports': [80, '8080-8880'],
                  },
                  'TLS': {
                    'ports': [443],
                  },
                },
              },
            }),
          ),
          useProfileSettings: useProfileSettings,
        );

        for (final (section, type, name) in [
          ('proxy-providers', proxiesProviderDirectoryName, 'remote'),
          ('proxy-providers', proxiesProviderDirectoryName, 'local'),
          ('rule-providers', rulesProviderDirectoryName, 'remote'),
        ]) {
          expect(
            config[section][name]['path'],
            startsWith('/profiles/$providersDirectoryName/3/$type/'),
            reason: '$section.$name',
          );
        }
        expect(config['sniffer']['sniff']['HTTP']['ports'], [
          '80',
          '8080-8880',
        ]);
        expect(config['sniffer']['sniff']['TLS']['ports'], ['443']);
      });
    }

    test('the overwrite keys are still the app\'s', () async {
      final config = await _config(_fullProfile());
      final golden = loadYaml(_golden('full_profile')) as YamlMap;

      for (final key in overwriteKeys.where(golden.containsKey)) {
        expect(config[key], golden[key], reason: key);
      }
      expect(config['profile']['store-selected'], false);
    });

    test('a preference the profile leaves out is still written', () async {
      final result = await _build({}, useProfileSettings: true);

      expect(result.yaml, _golden('empty_profile'));
      expect(result.profileOwned.keys, isEmpty);

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

        expect(on.profileOwned.keys, isEmpty);
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

  test(
    'safe mode keeps a profile\'s tun, controller and listeners off',
    () async {
      final result = await _build(
        _fullProfile(),
        useProfileSettings: true,
        safeMode: true,
      );
      final config = loadYaml(result.yaml) as YamlMap;

      expect(config['tun']['enable'], false);
      expect(config['tun']['device'], 'utun99');
      expect(config['external-controller'], '');
      expect(config['dns']['listen'], '');
      expect(config['ntp']['write-to-system'], false);
    },
  );

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
            'nameservers only with the toggle off, '
            'toggle ${useProfileSettings ? 'on' : 'off'}, '
            'Override DNS ${overrideDns ? 'on' : 'off'}', () async {
          final config = await _config(
            {'dns': block},
            useProfileSettings: useProfileSettings,
            overrideDns: overrideDns,
            appendSystemDns: false,
          );

          expect(config['dns']['enable'], true);
          expect(
            config['dns']['nameserver'],
            useProfileSettings ? block['nameserver'] : ['1.1.1.1'],
          );
        });
      }
    }

    for (final overrideDns in [false, true]) {
      test('a profile dns block keeps its own listen with Override DNS '
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

        expect(
          off['dns']['listen'],
          overrideDns ? '0.0.0.0:1053' : '0.0.0.0:53',
        );
        expect(on['dns']['listen'], '0.0.0.0:53');
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

        expect(on.profileOwned.keys, {'ipv6'});
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

    test('nulls each key the profile states and only that key', () {
      final app = payload({});

      for (final key in app.keys.where((key) => key != 'geox-url')) {
        final owned = payload({key});
        expect(app[key], isNotNull, reason: key);
        for (final other in app.keys) {
          expect(
            owned[other],
            other == key ? isNull : app[other],
            reason: '$key stated, $other',
          );
        }
      }
    });

    test('geox-url and lgbm-url each withhold only their own links', () {
      final app = payload({})['geox-url'] as Map<String, dynamic>;

      expect(payload({'geox-url'})['geox-url'], {'model': app['model']});
      expect(payload({'lgbm-url'})['geox-url'], Map.of(app)..remove('model'));
      expect(payload({'geox-url', 'lgbm-url'})['geox-url'], isNull);
    });
  });
}
