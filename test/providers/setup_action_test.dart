import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/database/database.dart' as db;
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/action.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/providers/core.dart';
import 'package:fl_clash/providers/database.dart';
import 'package:fl_clash/providers/state.dart';
import 'package:fl_clash/state.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:riverpod/riverpod.dart';
import 'package:yaml/yaml.dart';

import '../helpers/test_profiles.dart';

class _MockCoreHandlerInterface extends Mock implements CoreHandlerInterface {}

// checkAndUpdateAndCopy checks the file system before it refreshes, so its
// failure tests need appPath to resolve to a real, writable directory.
class _FakePathProvider extends PathProviderPlatform {
  final String root;

  _FakePathProvider(this.root);

  @override
  Future<String?> getTemporaryPath() async => root;

  @override
  Future<String?> getApplicationSupportPath() async => root;

  @override
  Future<String?> getApplicationCachePath() async => root;
}

class _ListenerHandoffFailureSetupAction extends SetupAction {
  final List<bool> coreRunningCalls = [];

  @override
  Future<bool> setCoreRunning(bool running) async {
    coreRunningCalls.add(running);
    if (running) {
      throw StateError('listener handoff failed');
    }
    return true;
  }
}

class _MessageFailureSetupAction extends SetupAction {
  final List<bool> coreRunningCalls = [];

  @override
  Future<bool> setCoreRunning(bool running) async {
    coreRunningCalls.add(running);
    return true;
  }
}

class TestCommonAction extends CommonAction {
  int trafficUpdates = 0;

  @override
  Future<void> updateTraffic() async {
    trafficUpdates++;
  }
}

class TestSetupAction extends SetupAction {
  final List<bool> coreRunningCalls = [];
  final List<Completer<void>> pendingCoreCalls = [];
  int trafficResets = 0;
  int applyProfileCalls = 0;
  bool blockCoreCalls = false;
  Error? coreRunningError;
  int authorizeCalls = 0;
  AuthorizeCode authorizeResult = AuthorizeCode.none;

  @override
  Future<AuthorizeCode> authorizeCore() async {
    authorizeCalls++;
    return authorizeResult;
  }

  @override
  Future<bool> setCoreRunning(bool running) async {
    coreRunningCalls.add(running);
    if (blockCoreCalls) {
      final gate = Completer<void>();
      pendingCoreCalls.add(gate);
      await gate.future;
    }
    final error = coreRunningError;
    if (error != null) {
      throw error;
    }
    return true;
  }

  @override
  void resetCoreTraffic() => trafficResets++;

  @override
  Future<bool> applyProfile({
    bool silence = false,
    bool force = false,
    Future<void> Function()? preloadInvoke,
  }) async {
    applyProfileCalls++;
    await preloadInvoke?.call();
    return true;
  }
}

const nullProfileSetupState = SetupState(
  profileId: null,
  profileLastUpdateDate: null,
  overwriteType: OverwriteType.standard,
  rules: [],
  proxyGroups: [],
  addedRules: [],
  script: null,
  overrideDns: false,
  dns: Dns(),
  dnsOverrideKeys: {},
);

/// Lets the real setupStateProvider derive a profile's setup from its row.
void _useMemoryDatabase() {
  final previous = db.database;
  db.database = db.Database(NativeDatabase.memory());
  addTearDown(() async {
    await db.database.close();
    db.database = previous;
  });
}

class TestAuthorizingSetupAction extends SetupAction {
  int authorizeCalls = 0;
  AuthorizeCode authorizeResult = AuthorizeCode.none;

  @override
  Future<AuthorizeCode> authorizeCore() async {
    authorizeCalls++;
    return authorizeResult;
  }
}

class _AndroidSetupAction extends TestAuthorizingSetupAction {
  _AndroidSetupAction() {
    authorizeResult = AuthorizeCode.error;
  }

  @override
  bool get coreCreatesTun => false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    registerFallbackValue(const SetupParams(selectedMap: {}, testUrl: ''));
    registerFallbackValue(
      const UpdateParams(
        tun: Tun(),
        mixedPort: 7890,
        allowLan: false,
        findProcessMode: FindProcessMode.off,
        mode: Mode.rule,
        logLevel: LogLevel.info,
        ipv6: false,
        tcpConcurrent: false,
        externalController: ExternalControllerStatus.close,
        unifiedDelay: false,
      ),
    );
  });

  late TestSetupAction action;
  late ProviderContainer container;

  setUp(() {
    action = TestSetupAction();
    container = ProviderContainer(
      overrides: [
        profilesProvider.overrideWith(TestProfiles.new),
        setupActionProvider.overrideWith(() => action),
        commonActionProvider.overrideWith(TestCommonAction.new),
      ],
    );
    globalState.container = container;
    globalState.needInitStatus = true;
    container.read(setupActionProvider.notifier);
  });

  tearDown(() async {
    action.blockCoreCalls = false;
    action.coreRunningError = null;
    for (final gate in action.pendingCoreCalls) {
      if (!gate.isCompleted) {
        gate.complete();
      }
    }
    await container.read(setupActionProvider.notifier).setRunning(false);
    container.dispose();
    globalState.needInitStatus = true;
  });

  void markInitialized() {
    container.read(initProvider.notifier).value = true;
  }

  group('setRunning gating', () {
    test('ignores a start request before initialization completes', () async {
      await container.read(setupActionProvider.notifier).setRunning(true);

      expect(action.coreRunningCalls, isEmpty);
      expect(container.read(runTimeProvider), isNull);
    });

    test('an initialize request bypasses the init gate', () async {
      await container
          .read(setupActionProvider.notifier)
          .setRunning(true, initialize: true);

      expect(action.coreRunningCalls, [true]);
      expect(action.applyProfileCalls, 1);
      expect(globalState.needInitStatus, isFalse);
    });

    test('safe mode runs the profile but never touches the listener', () async {
      final scopedAction = TestSetupAction();
      final scoped = ProviderContainer(
        overrides: [
          profilesProvider.overrideWith(TestProfiles.new),
          setupActionProvider.overrideWith(() => scopedAction),
          commonActionProvider.overrideWith(TestCommonAction.new),
          safeModeProvider.overrideWithValue(true),
        ],
      );
      addTearDown(scoped.dispose);
      globalState.container = scoped;
      scoped.read(setupActionProvider.notifier);

      await scoped
          .read(setupActionProvider.notifier)
          .setRunning(true, initialize: true);

      expect(scopedAction.coreRunningCalls, isEmpty);
      expect(scopedAction.applyProfileCalls, 1);
      expect(scoped.read(isStartProvider), isTrue);

      await scoped.read(setupActionProvider.notifier).setRunning(false);

      expect(scopedAction.coreRunningCalls, isEmpty);
      expect(scoped.read(isStartProvider), isFalse);
    });

    test('starts the core once initialization is done', () async {
      markInitialized();

      await container.read(setupActionProvider.notifier).setRunning(true);

      expect(action.coreRunningCalls, [true]);
      expect(container.read(runTimeProvider), isNotNull);
    });

    test('a stop request is never gated on initialization', () async {
      await container.read(setupActionProvider.notifier).setRunning(false);

      expect(action.coreRunningCalls, [false]);
    });
  });

  group('run failures', () {
    test('a start the core rejects stops reporting a run time', () async {
      markInitialized();
      action.coreRunningError = StateError('start failed');

      await expectLater(
        container.read(setupActionProvider.notifier).setRunning(true),
        throwsStateError,
      );

      expect(container.read(runTimeProvider), isNull);
    });

    test(
      'a stop the core rejects keeps the run time it started with',
      () async {
        markInitialized();
        await container.read(setupActionProvider.notifier).setRunning(true);
        action.coreRunningError = StateError('stop failed');

        await expectLater(
          container.read(setupActionProvider.notifier).setRunning(false),
          throwsStateError,
        );

        expect(container.read(runTimeProvider), isNotNull);
      },
    );
  });

  group('stop cleanup', () {
    test('resets traffic counters', () async {
      markInitialized();
      await container.read(setupActionProvider.notifier).setRunning(true);
      container.read(totalTrafficProvider.notifier).value = const Traffic(
        up: 10,
        down: 20,
      );

      await container.read(setupActionProvider.notifier).setRunning(false);

      expect(action.trafficResets, 1);
      expect(container.read(trafficsProvider).list, isEmpty);
      expect(container.read(totalTrafficProvider), const Traffic());
      expect(container.read(runTimeProvider), isNull);
    });
  });

  group('run time ticker', () {
    late ProviderContainer scoped;

    // Built inside each test, on its fake clock: futures made there never
    // settle in the shared tearDown.
    SetupAction buildScoped() {
      scoped = ProviderContainer(
        overrides: [
          profilesProvider.overrideWith(TestProfiles.new),
          setupActionProvider.overrideWith(TestSetupAction.new),
          commonActionProvider.overrideWith(TestCommonAction.new),
        ],
      );
      addTearDown(scoped.dispose);
      globalState.container = scoped;
      scoped
          .read(appSettingProvider.notifier)
          .update((state) => state.copyWith(showTrayTitle: false));
      scoped.read(initProvider.notifier).value = true;
      return scoped.read(setupActionProvider.notifier);
    }

    int trafficUpdates() =>
        (scoped.read(commonActionProvider.notifier) as TestCommonAction)
            .trafficUpdates;

    void setVisible(bool visible) =>
        scoped.read(appVisibleProvider.notifier).value = visible;

    testWidgets('reads traffic only while the app is visible', (tester) async {
      final setup = buildScoped();
      await setup.setRunning(true);
      expect(trafficUpdates(), 1);

      await tester.pump(const Duration(seconds: 2));
      expect(trafficUpdates(), 3);

      setVisible(false);
      await tester.pump(const Duration(seconds: 5));
      expect(trafficUpdates(), 3);
      expect(scoped.read(isStartProvider), isTrue);

      setVisible(true);
      await tester.pump();
      expect(trafficUpdates(), 4);
      await tester.pump(const Duration(seconds: 1));
      expect(trafficUpdates(), 5);

      await setup.setRunning(false);
    });

    testWidgets('a start while hidden waits for the app to be shown', (
      tester,
    ) async {
      final setup = buildScoped();
      setVisible(false);
      await setup.setRunning(true);
      await tester.pump(const Duration(seconds: 3));

      expect(scoped.read(runTimeProvider), isNotNull);
      expect(trafficUpdates(), 0);

      setVisible(true);
      await tester.pump();
      expect(trafficUpdates(), 1);

      await setup.setRunning(false);
    });

    testWidgets('the macOS menu bar title keeps traffic coming while hidden', (
      tester,
    ) async {
      final setup = buildScoped();
      setVisible(false);
      await setup.setRunning(true);
      await tester.pump(const Duration(seconds: 2));
      expect(trafficUpdates(), 0);

      scoped
          .read(appSettingProvider.notifier)
          .update((state) => state.copyWith(showTrayTitle: true));
      await tester.pump(const Duration(seconds: 2));

      expect(trafficUpdates(), system.isMacOS ? 3 : 0);

      await setup.setRunning(false);
    });
  });

  group('suspend', () {
    test('skips starting the core on an excluded SSID', () async {
      container.dispose();
      action = TestSetupAction();
      container = ProviderContainer(
        overrides: [
          profilesProvider.overrideWith(TestProfiles.new),
          setupActionProvider.overrideWith(() => action),
          commonActionProvider.overrideWith(TestCommonAction.new),
          excludeSSIDsProvider.overrideWithValue(const ['Office Wi-Fi']),
        ],
      );
      globalState.container = container;
      container.read(initProvider.notifier).value = true;
      container.read(currentSSIDProvider.notifier).value = 'Office Wi-Fi';

      await container.read(setupActionProvider.notifier).setRunning(true);

      expect(action.coreRunningCalls, isEmpty);
    });

    test('still stops the core on an excluded SSID', () async {
      container.dispose();
      action = TestSetupAction();
      container = ProviderContainer(
        overrides: [
          profilesProvider.overrideWith(TestProfiles.new),
          setupActionProvider.overrideWith(() => action),
          commonActionProvider.overrideWith(TestCommonAction.new),
          excludeSSIDsProvider.overrideWithValue(const ['Office Wi-Fi']),
        ],
      );
      globalState.container = container;
      container.read(currentSSIDProvider.notifier).value = 'Office Wi-Fi';

      await container.read(setupActionProvider.notifier).setRunning(false);

      expect(action.coreRunningCalls, [false]);
    });
  });

  group('latest-intent arbitration', () {
    test('a superseded stop does not run the post-stop cleanup', () async {
      markInitialized();
      final notifier = container.read(setupActionProvider.notifier);
      action.blockCoreCalls = true;

      final stopping = notifier.setRunning(false);
      await Future<void>.delayed(Duration.zero);
      final starting = notifier.setRunning(true);
      await Future<void>.delayed(Duration.zero);

      action.blockCoreCalls = false;
      for (final gate in action.pendingCoreCalls) {
        if (!gate.isCompleted) {
          gate.complete();
        }
      }
      await Future.wait([stopping, starting]);

      expect(action.coreRunningCalls, [false, true]);
      expect(action.trafficResets, 0);
      expect(container.read(runTimeProvider), isNotNull);
    });

    test('the newest request wins the local running state', () async {
      markInitialized();
      final notifier = container.read(setupActionProvider.notifier);

      await notifier.setRunning(true);
      expect(container.read(runTimeProvider), isNotNull);

      await notifier.setRunning(false);
      expect(container.read(runTimeProvider), isNull);

      await notifier.setRunning(true);
      expect(container.read(runTimeProvider), isNotNull);
      expect(action.coreRunningCalls, [true, false, true]);
    });
  });

  group('initStatus', () {
    test('is a no-op once the status has already been initialized', () async {
      globalState.needInitStatus = false;

      await container.read(setupActionProvider.notifier).initStatus();

      expect(action.coreRunningCalls, isEmpty);
      expect(action.applyProfileCalls, 0);
    });

    test('starts the core when autoRun is enabled', () async {
      container.read(appSettingProvider.notifier).value = const AppSettingProps(
        autoRun: true,
      );

      await container.read(setupActionProvider.notifier).initStatus();

      expect(action.coreRunningCalls, [true]);
      expect(globalState.needInitStatus, isFalse);
    });

    test('only applies the profile when autoRun is disabled', () async {
      container.read(appSettingProvider.notifier).value = const AppSettingProps(
        autoRun: false,
      );

      await container.read(setupActionProvider.notifier).initStatus();

      expect(action.coreRunningCalls, isEmpty);
      expect(action.applyProfileCalls, 1);
    });
  });

  group('requestAdmin', () {
    test('never asks for authorization while tun is disabled', () async {
      expect(await action.requestAdmin(false), isTrue);

      expect(action.authorizeCalls, 0);
      expect(
        container.read(authorizedTunEnableProvider),
        TunAuthorizationState.none,
      );
    });

    test('safe mode never asks, whatever the tun setting says', () async {
      final scopedAction = TestSetupAction();
      final scoped = ProviderContainer(
        overrides: [
          profilesProvider.overrideWith(TestProfiles.new),
          setupActionProvider.overrideWith(() => scopedAction),
          safeModeProvider.overrideWithValue(true),
        ],
      );
      addTearDown(scoped.dispose);
      scoped.read(setupActionProvider.notifier);

      expect(await scopedAction.requestAdmin(true), isTrue);
      expect(scopedAction.authorizeCalls, 0);
      expect(
        scoped.read(authorizedTunEnableProvider),
        TunAuthorizationState.none,
      );
    });

    test('does not ask again once the state left none', () async {
      container.read(authorizedTunEnableProvider.notifier).value =
          TunAuthorizationState.authorized;

      expect(await action.requestAdmin(true), isTrue);
      expect(action.authorizeCalls, 0);
    });

    test(
      'a successful authorization hands off instead of continuing',
      () async {
        action.authorizeResult = AuthorizeCode.success;

        expect(await action.requestAdmin(true), isFalse);
        expect(action.authorizeCalls, 1);
        expect(
          container.read(authorizedTunEnableProvider),
          TunAuthorizationState.authorized,
        );
      },
    );

    test('a platform without an authorization step continues inline', () async {
      action.authorizeResult = AuthorizeCode.none;

      expect(await action.requestAdmin(true), isTrue);
      expect(
        container.read(authorizedTunEnableProvider),
        TunAuthorizationState.authorized,
      );
    });

    test('a failed authorization continues but stays unauthorized', () async {
      action.authorizeResult = AuthorizeCode.error;

      expect(await action.requestAdmin(true), isTrue);
      expect(
        container.read(authorizedTunEnableProvider),
        TunAuthorizationState.unauthorized,
      );
    });
  });

  group('updateConfig', () {
    test('safe mode pushes tun disabled even once authorized', () async {
      final core = _MockCoreHandlerInterface();
      when(() => core.updateConfig(any())).thenAnswer((_) async => '');
      final scopedAction = TestSetupAction();
      final scoped = ProviderContainer(
        overrides: [
          profilesProvider.overrideWith(TestProfiles.new),
          setupActionProvider.overrideWith(() => scopedAction),
          coreHandlerProvider.overrideWithValue(CoreController.scoped(core)),
          safeModeProvider.overrideWithValue(true),
        ],
      );
      addTearDown(scoped.dispose);
      scoped.read(setupActionProvider.notifier);
      scoped
          .read(patchClashConfigProvider.notifier)
          .update(
            (state) => state.copyWith(tun: state.tun.copyWith(enable: true)),
          );
      scoped.read(authorizedTunEnableProvider.notifier).value =
          TunAuthorizationState.authorized;

      await scopedAction.updateConfig();

      final params =
          verify(() => core.updateConfig(captureAny())).captured.single
              as UpdateParams;
      expect(params.tun?.enable, isFalse);
      expect(scopedAction.authorizeCalls, 0);
    });

    test('safe mode closes the external controller', () async {
      final core = _MockCoreHandlerInterface();
      when(() => core.updateConfig(any())).thenAnswer((_) async => '');
      final scopedAction = TestSetupAction();
      final scoped = ProviderContainer(
        overrides: [
          profilesProvider.overrideWith(TestProfiles.new),
          setupActionProvider.overrideWith(() => scopedAction),
          coreHandlerProvider.overrideWithValue(CoreController.scoped(core)),
          safeModeProvider.overrideWithValue(true),
        ],
      );
      addTearDown(scoped.dispose);
      scoped.read(setupActionProvider.notifier);
      scoped
          .read(patchClashConfigProvider.notifier)
          .update(
            (state) => state.copyWith(
              externalController: ExternalControllerStatus.open,
            ),
          );

      await scopedAction.updateConfig();

      final params =
          verify(() => core.updateConfig(captureAny())).captured.single
              as UpdateParams;
      expect(params.externalController, ExternalControllerStatus.close);
      expect(
        scoped.read(patchClashConfigProvider).externalController,
        ExternalControllerStatus.open,
      );
    });
  });

  group('recoverMissingProfile', () {
    ProviderContainer buildScoped(List<Profile> profiles, int? profileId) {
      final scoped = ProviderContainer(
        overrides: [
          profilesProvider.overrideWith(() => TestProfiles(profiles)),
          currentProfileIdProvider.overrideWithBuild((_, _) => profileId),
          setupActionProvider.overrideWith(TestSetupAction.new),
        ],
      );
      addTearDown(scoped.dispose);
      return scoped;
    }

    test('a dangling profile id falls back to the first profile', () {
      final profile = Profile.normal(label: 'p').copyWith(id: 1);
      final scoped = buildScoped([profile], 404);

      final recovered = scoped
          .read(setupActionProvider.notifier)
          .recoverMissingProfile();

      expect(recovered?.id, profile.id);
      expect(scoped.read(currentProfileIdProvider), profile.id);
    });

    test('no profiles keeps the stored id untouched', () {
      final scoped = buildScoped(const [], 404);

      expect(
        scoped.read(setupActionProvider.notifier).recoverMissingProfile(),
        isNull,
      );
      expect(scoped.read(currentProfileIdProvider), 404);
    });

    test('an unset id is the first-run state, not a dangling one', () {
      final profile = Profile.normal(label: 'p').copyWith(id: 1);
      final scoped = buildScoped([profile], null);

      expect(
        scoped.read(setupActionProvider.notifier).recoverMissingProfile(),
        isNull,
      );
      expect(scoped.read(currentProfileIdProvider), isNull);
    });
  });

  group('changeMode', () {
    test('records the requested mode', () {
      container.read(setupActionProvider.notifier).changeMode(Mode.direct);

      expect(container.read(patchClashConfigProvider).mode, Mode.direct);
    });

    test('leaving global alone keeps the selected group', () {
      final profile = Profile.normal(
        label: 'p',
      ).copyWith(id: 1, currentGroupName: 'Manual');
      final scoped = ProviderContainer(
        overrides: [
          profilesProvider.overrideWith(() => TestProfiles([profile])),
          currentProfileIdProvider.overrideWithBuild((_, _) => profile.id),
          setupActionProvider.overrideWith(TestSetupAction.new),
        ],
      );
      addTearDown(scoped.dispose);

      scoped.read(setupActionProvider.notifier).changeMode(Mode.rule);

      expect(scoped.read(currentProfileProvider)?.currentGroupName, 'Manual');
    });

    test('global mode also selects the global group', () {
      final profile = Profile.normal(
        label: 'p',
      ).copyWith(id: 1, currentGroupName: 'Manual');
      final scoped = ProviderContainer(
        overrides: [
          profilesProvider.overrideWith(() => TestProfiles([profile])),
          currentProfileIdProvider.overrideWithBuild((_, _) => profile.id),
          setupActionProvider.overrideWith(TestSetupAction.new),
        ],
      );
      addTearDown(scoped.dispose);

      scoped.read(setupActionProvider.notifier).changeMode(Mode.global);

      expect(scoped.read(patchClashConfigProvider).mode, Mode.global);
      expect(
        scoped.read(currentProfileProvider)?.currentGroupName,
        GroupName.GLOBAL.name,
      );
    });
  });

  group('applyProfileDebounce', () {
    test('collapses a burst into a single apply', () async {
      final notifier = container.read(setupActionProvider.notifier);

      notifier.applyProfileDebounce(force: true);
      notifier.applyProfileDebounce(force: true);
      notifier.applyProfileDebounce(force: true);
      expect(action.applyProfileCalls, 0);

      await Future<void>.delayed(const Duration(milliseconds: 800));
      expect(action.applyProfileCalls, 1);
    });

    test('a stop cancels a pending apply', () async {
      markInitialized();
      final notifier = container.read(setupActionProvider.notifier);

      notifier.applyProfileDebounce(force: true);
      await notifier.setRunning(false);

      await Future<void>.delayed(const Duration(milliseconds: 800));
      expect(action.applyProfileCalls, 0);
    });
  });

  group('_setupConfig via the real SetupAction', () {
    late Directory tempDir;
    late String? originalLastConfigMd5;

    setUpAll(() async {
      tempDir = Directory.systemTemp.createTempSync('setup_action_test');
      PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
      await AppLocalizations.load(const Locale('en'));
      originalLastConfigMd5 = globalState.lastConfigMd5;
      globalState.packageInfo = PackageInfo(
        appName: 'FlClash',
        packageName: 'com.follow.clash',
        version: '0.0.0',
        buildNumber: '0',
      );
    });

    tearDownAll(() {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    tearDown(() {
      globalState.lastConfigMd5 = originalLastConfigMd5;
    });

    // profileId: null routes getProfile/setupState around the database and
    // Core.getConfig, isolating the behavior under test.
    test(
      'a refresh failure still runs core.setupConfig and preloadInvoke',
      () async {
        final profile = Profile.normal(label: 'p', url: 'http://127.0.0.1:9/');
        final core = _MockCoreHandlerInterface();
        when(() => core.setupConfig(any())).thenAnswer((_) async => '');
        var preloadRan = false;
        final scoped = ProviderContainer(
          overrides: [
            profilesProvider.overrideWith(() => TestProfiles([profile])),
            currentProfileIdProvider.overrideWithBuild((_, _) => profile.id),
            setupStateProvider.overrideWith((_, _) => nullProfileSetupState),
            coreHandlerProvider.overrideWithValue(CoreController.scoped(core)),
            setupActionProvider.overrideWith(SetupAction.new),
          ],
        );
        addTearDown(scoped.dispose);

        await scoped
            .read(setupActionProvider.notifier)
            .applyProfile(
              force: true,
              preloadInvoke: () async {
                preloadRan = true;
              },
            );

        expect(preloadRan, isTrue);
        verify(() => core.setupConfig(any())).called(1);
      },
    );

    test(
      'a profile that fails to build still pushes the empty config to core',
      () async {
        final profile = Profile.normal(label: 'p');
        final core = _MockCoreHandlerInterface();
        when(() => core.getConfig(any())).thenThrow(Exception('broken yaml'));
        String? pushedConfig;
        when(() => core.setupConfig(any())).thenAnswer((_) async {
          pushedConfig = await File(
            await appPath.configFilePath,
          ).readAsString();
          return '';
        });
        final scoped = ProviderContainer(
          overrides: [
            profilesProvider.overrideWith(() => TestProfiles([profile])),
            currentProfileIdProvider.overrideWithBuild((_, _) => profile.id),
            setupStateProvider.overrideWith(
              (_, profileId) =>
                  nullProfileSetupState.copyWith(profileId: profileId),
            ),
            coreHandlerProvider.overrideWithValue(CoreController.scoped(core)),
            setupActionProvider.overrideWith(SetupAction.new),
          ],
        );
        addTearDown(scoped.dispose);

        final succeeded = await scoped
            .read(setupActionProvider.notifier)
            .applyProfile(force: true);

        expect(succeeded, isFalse);
        expect(pushedConfig, isEmpty);
        expect(scoped.read(currentProfileIdProvider), profile.id);
      },
    );

    test(
      'a config write failure reports setup as failed without calling core',
      () async {
        final configPath = await appPath.configFilePath;
        final configFile = File(configPath);
        if (await configFile.exists()) {
          await configFile.delete();
        }
        final configAsDirectory = Directory(configPath);
        await configAsDirectory.create(recursive: true);

        final core = _MockCoreHandlerInterface();
        when(() => core.setupConfig(any())).thenAnswer((_) async => '');
        final scoped = ProviderContainer(
          overrides: [
            currentProfileProvider.overrideWithValue(null),
            setupStateProvider.overrideWith((_, _) => nullProfileSetupState),
            coreHandlerProvider.overrideWithValue(CoreController.scoped(core)),
            setupActionProvider.overrideWith(SetupAction.new),
          ],
        );
        addTearDown(scoped.dispose);

        try {
          final succeeded = await scoped
              .read(setupActionProvider.notifier)
              .applyProfile(force: true);

          expect(succeeded, isFalse);
          verifyNever(() => core.setupConfig(any()));
        } finally {
          await configAsDirectory.delete(recursive: true);
        }
      },
    );

    test(
      'safe mode writes a closed external controller into the profile',
      () async {
        final profile = Profile.normal(label: 'p');
        final core = _MockCoreHandlerInterface();
        when(() => core.getConfig(any())).thenAnswer((_) async => {});
        String? pushedConfig;
        when(() => core.setupConfig(any())).thenAnswer((_) async {
          pushedConfig = await File(
            await appPath.configFilePath,
          ).readAsString();
          return '';
        });
        final scoped = ProviderContainer(
          overrides: [
            profilesProvider.overrideWith(() => TestProfiles([profile])),
            currentProfileIdProvider.overrideWithBuild((_, _) => profile.id),
            setupStateProvider.overrideWith(
              (_, profileId) =>
                  nullProfileSetupState.copyWith(profileId: profileId),
            ),
            coreHandlerProvider.overrideWithValue(CoreController.scoped(core)),
            setupActionProvider.overrideWith(SetupAction.new),
            safeModeProvider.overrideWithValue(true),
          ],
        );
        addTearDown(scoped.dispose);
        scoped
            .read(patchClashConfigProvider.notifier)
            .update(
              (state) => state.copyWith(
                externalController: ExternalControllerStatus.open,
              ),
            );

        final succeeded = await scoped
            .read(setupActionProvider.notifier)
            .applyProfile(force: true);

        expect(succeeded, isTrue);
        expect(pushedConfig, contains('external-controller: ""'));
        expect(pushedConfig, isNot(contains('9090')));
      },
    );

    for (final useProfileSettings in [false, true]) {
      test('the runtime push after a profile apply with '
          'useProfileSettings $useProfileSettings', () async {
        final profile = Profile.normal(
          label: 'p',
        ).copyWith(useProfileSettings: useProfileSettings);
        final core = _MockCoreHandlerInterface();
        when(
          () => core.getConfig(any()),
        ).thenAnswer((_) async => {'ipv6': true, 'log-level': 'debug'});
        when(
          () => core.getProfileKeys(any()),
        ).thenAnswer((_) async => {'ipv6', 'log-level'});
        String? pushedConfig;
        when(() => core.setupConfig(any())).thenAnswer((_) async {
          pushedConfig = await File(
            await appPath.configFilePath,
          ).readAsString();
          return '';
        });
        when(() => core.updateConfig(any())).thenAnswer((_) async => '');
        final scoped = ProviderContainer(
          overrides: [
            profilesProvider.overrideWith(() => TestProfiles([profile])),
            currentProfileIdProvider.overrideWithBuild((_, _) => profile.id),
            setupStateProvider.overrideWith(
              (_, profileId) => nullProfileSetupState.copyWith(
                profileId: profileId,
                useProfileSettings: useProfileSettings,
              ),
            ),
            coreHandlerProvider.overrideWithValue(CoreController.scoped(core)),
            setupActionProvider.overrideWith(SetupAction.new),
          ],
        );
        addTearDown(scoped.dispose);
        scoped.listen(networkSettingProvider, (_, _) {});
        scoped
            .read(networkSettingProvider.notifier)
            .update(
              (state) => state.copyWith(
                authentication: const AuthenticationProps(
                  enable: true,
                  username: 'user',
                  password: 'pass',
                ),
              ),
            );
        final setup = scoped.read(setupActionProvider.notifier);

        expect(await setup.applyProfile(force: true), isTrue);
        await setup.updateConfig();

        final config = loadYaml(pushedConfig!) as YamlMap;
        final params =
            (verify(() => core.updateConfig(captureAny())).captured.single
                    as UpdateParams)
                .toJson();
        expect(config['ipv6'], useProfileSettings);
        expect(config['log-level'], useProfileSettings ? 'debug' : 'error');
        expect(params['ipv6'], useProfileSettings ? isNull : false);
        expect(params['log-level'], useProfileSettings ? isNull : 'error');
        expect(params['allow-lan'], false);
        expect(params['tcp-concurrent'], true);
        expect(params['authentication'], ['user:pass']);
        expect(params['mixed-port'], defaultMixedPort);
        expect(params['mode'], 'rule');
        if (useProfileSettings) {
          verify(() => core.getProfileKeys(any())).called(1);
        } else {
          verifyNever(() => core.getProfileKeys(any()));
        }
      });
    }

    test('switching a profile\'s flag off hands the runtime keys back to the '
        'app even when the config is unchanged', () async {
      _useMemoryDatabase();
      final profile = Profile.normal(
        label: 'p',
      ).copyWith(useProfileSettings: true);
      final core = _MockCoreHandlerInterface();
      when(
        () => core.getConfig(any()),
      ).thenAnswer((_) async => {'ipv6': false});
      when(() => core.getProfileKeys(any())).thenAnswer((_) async => {'ipv6'});
      when(() => core.setupConfig(any())).thenAnswer((_) async => '');
      when(() => core.updateConfig(any())).thenAnswer((_) async => '');
      final scoped = ProviderContainer(
        overrides: [
          profilesProvider.overrideWith(() => TestProfiles([profile])),
          currentProfileIdProvider.overrideWithBuild((_, _) => profile.id),
          coreHandlerProvider.overrideWithValue(CoreController.scoped(core)),
          setupActionProvider.overrideWith(SetupAction.new),
        ],
      );
      addTearDown(scoped.dispose);
      final setup = scoped.read(setupActionProvider.notifier);
      Object? pushedIpv6() =>
          (verify(() => core.updateConfig(captureAny())).captured.single
                  as UpdateParams)
              .toJson()['ipv6'];

      expect(await setup.applyProfile(force: true), isTrue);
      await setup.updateConfig();
      expect(pushedIpv6(), isNull);

      scoped
          .read(profilesProvider.notifier)
          .put(profile.copyWith(useProfileSettings: false));
      expect(await setup.applyProfile(), isTrue);
      await setup.updateConfig();

      verify(() => core.setupConfig(any())).called(1);
      expect(pushedIpv6(), false);
    });

    test(
      'each profile applies with its own use-profile-settings flag',
      () async {
        _useMemoryDatabase();
        final owning = Profile.normal(
          label: 'owning',
        ).copyWith(useProfileSettings: true);
        final plain = Profile.normal(label: 'plain');
        final core = _MockCoreHandlerInterface();
        when(
          () => core.getConfig(any()),
        ).thenAnswer((_) async => {'ipv6': true, 'log-level': 'debug'});
        when(
          () => core.getProfileKeys(any()),
        ).thenAnswer((_) async => {'ipv6', 'log-level'});
        when(() => core.setupConfig(any())).thenAnswer((_) async => '');
        when(() => core.updateConfig(any())).thenAnswer((_) async => '');
        final scoped = ProviderContainer(
          overrides: [
            profilesProvider.overrideWith(() => TestProfiles([owning, plain])),
            currentProfileIdProvider.overrideWithBuild((_, _) => owning.id),
            coreHandlerProvider.overrideWithValue(CoreController.scoped(core)),
            setupActionProvider.overrideWith(SetupAction.new),
          ],
        );
        addTearDown(scoped.dispose);
        scoped.listen(currentProfileIdProvider, (_, _) {});
        final setup = scoped.read(setupActionProvider.notifier);
        Future<YamlMap> applied() async {
          expect(await setup.applyProfile(force: true), isTrue);
          return loadYaml(
                await File(await appPath.configFilePath).readAsString(),
              )
              as YamlMap;
        }

        final owningConfig = await applied();
        verify(
          () => core.getProfileKeys(any(that: contains('${owning.id}'))),
        ).called(1);
        scoped.read(currentProfileIdProvider.notifier).value = plain.id;
        final plainConfig = await applied();

        expect(owningConfig['ipv6'], isTrue);
        expect(owningConfig['log-level'], 'debug');
        expect(plainConfig['ipv6'], isFalse);
        expect(plainConfig['log-level'], 'error');
        verifyNever(
          () => core.getProfileKeys(any(that: contains('${plain.id}'))),
        );
      },
    );

    test('a custom overwrite injects only the providers it names', () async {
      final profile = Profile.normal(label: 'p');
      final core = _MockCoreHandlerInterface();
      when(() => core.getConfig(any())).thenAnswer(
        (_) async => {
          'proxy-providers': {
            'bundled': {'type': 'http', 'url': 'https://example.com/b.yaml'},
          },
        },
      );
      const appProxy = ClashProvider(
        id: 11,
        kind: ProviderKind.proxy,
        label: 'appProxies',
        url: 'https://example.com/p.yaml',
      );
      const appRule = ClashProvider(
        id: 12,
        kind: ProviderKind.rule,
        label: 'appRules',
        url: 'https://example.com/r.yaml',
        behavior: RuleProviderBehavior.domain,
        format: RuleProviderFormat.mrs,
      );
      const unusedProxy = ClashProvider(
        id: 13,
        kind: ProviderKind.proxy,
        label: 'unused',
        url: 'https://example.com/u.yaml',
      );
      const localRule = ClashProvider(
        id: 14,
        kind: ProviderKind.rule,
        label: 'localRules',
        behavior: RuleProviderBehavior.classical,
        format: RuleProviderFormat.yaml,
      );
      final setupState = nullProfileSetupState.copyWith(
        profileId: profile.id,
        overwriteType: OverwriteType.custom,
        proxyGroups: [
          const ProxyGroup(
            id: 1,
            name: 'g',
            type: GroupType.Selector,
            use: ['appProxies', 'sub'],
          ),
        ],
        rules: [
          Rule.parse('RULE-SET,appRules,DIRECT', id: 2),
          Rule.parse('RULE-SET,localRules,DIRECT', id: 3),
        ],
        clashProviders: const [appProxy, appRule, unusedProxy, localRule],
        profileProviders: const {'sub': 42},
      );
      final scoped = ProviderContainer(
        overrides: [
          coreHandlerProvider.overrideWithValue(CoreController.scoped(core)),
          setupActionProvider.overrideWith(SetupAction.new),
        ],
      );
      addTearDown(scoped.dispose);

      final res = await scoped
          .read(setupActionProvider.notifier)
          .getProfile(
            setupState: setupState,
            patchConfig: const PatchClashConfig(),
          );
      final config = loadYaml(res.yaml) as YamlMap;
      final proxyProviders = config['proxy-providers'] as YamlMap;

      expect(
        proxyProviders['appProxies']['path'],
        await appPath.getProviderCachePath(
          ProviderKind.proxy,
          appProxy.fileName,
        ),
      );
      expect(proxyProviders['sub']['type'], 'file');
      expect(proxyProviders['sub']['path'], await appPath.getProfilePath('42'));
      expect(proxyProviders.containsKey('unused'), isFalse);
      expect(
        proxyProviders['bundled']['path'],
        startsWith(
          await appPath.getProviderDirPath(
            profile.id,
            proxiesProviderDirectoryName,
          ),
        ),
      );
      expect(config['rule-providers']['appRules']['behavior'], 'domain');
      expect(config['rule-providers']['appRules']['format'], 'mrs');
      expect(
        config['rule-providers']['appRules']['path'],
        await appPath.getProviderCachePath(ProviderKind.rule, appRule.fileName),
      );
      final local = config['rule-providers']['localRules'] as YamlMap;
      expect(local['type'], 'file');
      expect(local.containsKey('url'), isFalse);
      expect(
        local['path'],
        await appPath.getProviderCachePath(
          ProviderKind.rule,
          localRule.fileName,
        ),
      );
    });

    test(
      'a rejected setupConfig without a handoff reports failure, not success',
      () async {
        final core = _MockCoreHandlerInterface();
        when(() => core.setupConfig(any())).thenThrow(StateError('rejected'));
        final scoped = ProviderContainer(
          overrides: [
            currentProfileProvider.overrideWithValue(null),
            setupStateProvider.overrideWith((_, _) => nullProfileSetupState),
            coreHandlerProvider.overrideWithValue(CoreController.scoped(core)),
            setupActionProvider.overrideWith(SetupAction.new),
          ],
        );
        addTearDown(scoped.dispose);

        final succeeded = await scoped
            .read(setupActionProvider.notifier)
            .applyProfile(force: true);

        expect(succeeded, isFalse);
        verify(() => core.setupConfig(any())).called(1);
      },
    );

    test(
      'a listener handoff failure during initialize rolls back running',
      () async {
        final core = _MockCoreHandlerInterface();
        when(() => core.setupConfig(any())).thenAnswer((_) async => '');
        final scoped = ProviderContainer(
          overrides: [
            currentProfileProvider.overrideWithValue(null),
            setupStateProvider.overrideWith((_, _) => nullProfileSetupState),
            coreHandlerProvider.overrideWithValue(CoreController.scoped(core)),
            setupActionProvider.overrideWith(
              _ListenerHandoffFailureSetupAction.new,
            ),
          ],
        );
        addTearDown(scoped.dispose);
        final handoffAction =
            scoped.read(setupActionProvider.notifier)
                as _ListenerHandoffFailureSetupAction;

        await handoffAction.setRunning(true, initialize: true);

        expect(handoffAction.coreRunningCalls, [true, false]);
        expect(scoped.read(runTimeProvider), isNull);
        verify(() => core.setupConfig(any())).called(1);
      },
    );

    test(
      'a non-empty setupConfig message during initialize rolls back running',
      () async {
        final core = _MockCoreHandlerInterface();
        when(
          () => core.setupConfig(any()),
        ).thenAnswer((_) async => 'config rejected');
        final scoped = ProviderContainer(
          overrides: [
            currentProfileProvider.overrideWithValue(null),
            setupStateProvider.overrideWith((_, _) => nullProfileSetupState),
            coreHandlerProvider.overrideWithValue(CoreController.scoped(core)),
            setupActionProvider.overrideWith(_MessageFailureSetupAction.new),
          ],
        );
        addTearDown(scoped.dispose);
        final messageAction =
            scoped.read(setupActionProvider.notifier)
                as _MessageFailureSetupAction;

        await messageAction.setRunning(true, initialize: true);

        expect(messageAction.coreRunningCalls, [true, false]);
        expect(scoped.read(runTimeProvider), isNull);
        verify(() => core.setupConfig(any())).called(1);
      },
    );

    group('use my profile settings', () {
      const sourceFixtures = 'test/fixtures/profile_settings/source';
      const appPatchConfig = PatchClashConfig(
        ntp: Ntp(server: 'time.cloudflare.com'),
        ntpOverrideKeys: {NtpOverrideKey.server},
        hosts: {'app.local': '10.0.0.2'},
      );
      const appliedOverwriteKeys = {
        'proxies',
        'proxy-groups',
        'rules',
        'proxy-providers',
        'rule-providers',
        'sniffer',
        'profile',
      };

      Object? coreReply(String fixture, String extension) => jsonDecode(
        File('$sourceFixtures/$fixture.$extension').readAsStringSync(),
      );
      Object? plain(Object? value) => jsonDecode(jsonEncode(value));

      _MockCoreHandlerInterface fixtureCore(String fixture) {
        final core = _MockCoreHandlerInterface();
        when(() => core.getConfig(any())).thenAnswer(
          (_) async => coreReply(fixture, 'core.json') as Map<String, dynamic>,
        );
        when(() => core.getProfileKeys(any())).thenAnswer(
          (_) async =>
              (coreReply(fixture, 'keys.json') as List).cast<String>().toSet(),
        );
        when(() => core.setupConfig(any())).thenAnswer((_) async => '');
        when(() => core.updateConfig(any())).thenAnswer((_) async => '');
        return core;
      }

      ProviderContainer scopedSetup(
        CoreHandlerInterface core, {
        required bool useProfileSettings,
        SetupState Function(int? profileId)? setupState,
        PatchClashConfig patchConfig = appPatchConfig,
        SetupAction Function()? action,
      }) {
        final profile = Profile.normal(
          label: 'p',
        ).copyWith(useProfileSettings: useProfileSettings);
        final scoped = ProviderContainer(
          overrides: [
            profilesProvider.overrideWith(() => TestProfiles([profile])),
            currentProfileIdProvider.overrideWithBuild((_, _) => profile.id),
            setupStateProvider.overrideWith(
              (_, profileId) =>
                  (setupState?.call(profileId) ??
                          nullProfileSetupState.copyWith(profileId: profileId))
                      .copyWith(useProfileSettings: useProfileSettings),
            ),
            coreHandlerProvider.overrideWithValue(CoreController.scoped(core)),
            setupActionProvider.overrideWith(
              action ?? TestAuthorizingSetupAction.new,
            ),
            overrideNtpProvider.overrideWithBuild((_, _) => true),
            networkSettingProvider.overrideWithBuild(
              (_, _) => const NetworkProps(appendSystemDns: true),
            ),
            patchClashConfigProvider.overrideWithBuild((_, _) => patchConfig),
          ],
        );
        addTearDown(scoped.dispose);
        return scoped;
      }

      Future<String> pushedConfigOf(
        ProviderContainer scoped, {
        bool expectApplied = true,
      }) async {
        final applied = await scoped
            .read(setupActionProvider.notifier)
            .applyProfile(force: true);
        expect(applied, expectApplied);
        return File(await appPath.configFilePath).readAsString();
      }

      for (final fixture in ['all_keys', 'minimal']) {
        test('every top-level key of the $fixture profile is the profile\'s '
            'when it states it and the app\'s otherwise', () async {
          final configReply = coreReply(fixture, 'core.json') as Map;
          final profileKeys = (coreReply(fixture, 'keys.json') as List)
              .cast<String>()
              .toSet();
          final stated = profileKeys.difference(appliedOverwriteKeys);
          Future<YamlMap> build(bool useProfileSettings) async {
            final scoped = scopedSetup(
              fixtureCore(fixture),
              useProfileSettings: useProfileSettings,
            );
            final res = await scoped
                .read(setupActionProvider.notifier)
                .getProfile(
                  setupState: nullProfileSetupState.copyWith(
                    profileId: 1,
                    useProfileSettings: useProfileSettings,
                  ),
                  patchConfig: appPatchConfig,
                );
            return loadYaml(res.yaml) as YamlMap;
          }

          final off = await build(false);
          final on = await build(true);

          expect(on.keys.toSet(), off.keys.toSet());
          for (final key in on.keys.cast<String>()) {
            if (stated.contains(key)) {
              expect(plain(on[key]), plain(configReply[key]), reason: key);
              expect(
                plain(off[key]),
                isNot(plain(configReply[key])),
                reason: '$key: the fixture must differ from the app\'s value',
              );
            } else {
              expect(plain(on[key]), plain(off[key]), reason: key);
            }
          }
          expect(stated.difference(on.keys.toSet()), isEmpty);
          if (fixture == 'minimal') {
            expect(stated, isEmpty);
          }
        });
      }

      for (final overwriteType in [
        OverwriteType.custom,
        OverwriteType.standard,
      ]) {
        test('the ${overwriteType.name} overwrite still applies to a profile '
            'that states its proxies, groups and rules', () async {
          final core = fixtureCore('all_keys');
          const profileProxy = {
            'name': 'profile-proxy',
            'type': 'socks5',
            'server': '10.0.0.9',
            'port': 1080,
          };
          const customProxy = {
            'name': 'custom-proxy',
            'type': 'socks5',
            'server': '10.0.0.10',
            'port': 1081,
          };
          final scoped = scopedSetup(
            core,
            useProfileSettings: true,
            setupState: (profileId) => switch (overwriteType) {
              OverwriteType.custom => nullProfileSetupState.copyWith(
                profileId: profileId,
                overwriteType: OverwriteType.custom,
                customProxies: [
                  CustomProxy.fromDefinition(profileProxy, id: 1),
                  CustomProxy.fromDefinition(customProxy, id: 2),
                ],
                proxyGroups: const [
                  ProxyGroup(
                    id: 3,
                    name: 'ProfileGroup',
                    type: GroupType.Selector,
                    proxies: ['profile-proxy'],
                  ),
                  ProxyGroup(
                    id: 4,
                    name: 'CustomGroup',
                    type: GroupType.Selector,
                    proxies: ['custom-proxy'],
                  ),
                ],
                rules: [
                  Rule.parse('DOMAIN,custom.example,CustomGroup', id: 5),
                  Rule.parse('DOMAIN,profile.example,ProfileGroup', id: 6),
                  Rule.parse('MATCH,DIRECT', id: 7),
                ],
              ),
              _ => nullProfileSetupState.copyWith(
                profileId: profileId,
                addedRules: [Rule.parse('DOMAIN,added.example,DIRECT', id: 8)],
              ),
            },
          );

          final config = loadYaml(await pushedConfigOf(scoped)) as YamlMap;
          final rules = plain(config['rules']);
          final proxyNames = [
            for (final proxy in config['proxies'] as YamlList) proxy['name'],
          ];
          final groupNames = [
            for (final group in config['proxy-groups'] as YamlList)
              group['name'],
          ];

          expect(config['profile']['store-selected'], false);
          expect(config['mixed-port'], 17890);
          if (overwriteType == OverwriteType.custom) {
            expect(proxyNames, ['profile-proxy', 'custom-proxy']);
            expect(groupNames, ['ProfileGroup', 'CustomGroup']);
            expect(rules, [
              'DOMAIN,custom.example,CustomGroup',
              'DOMAIN,profile.example,ProfileGroup',
              'MATCH,DIRECT',
            ]);
          } else {
            expect(proxyNames, ['profile-proxy']);
            expect(groupNames, ['ProfileGroup']);
            expect(rules, [
              'DOMAIN,added.example,DIRECT',
              'DOMAIN,profile.example,ProfileGroup',
              'MATCH,DIRECT',
            ]);
          }
        });
      }

      test('a profile that states the controller and its authentication '
          'leaves the app in control of its core and its own proxy', () async {
        final core = fixtureCore('all_keys');
        final scoped = scopedSetup(
          core,
          useProfileSettings: true,
          patchConfig: appPatchConfig.copyWith(
            externalController: ExternalControllerStatus.open,
          ),
        );
        scoped.listen(proxyStateProvider, (_, _) {});
        scoped.listen(trayStateProvider, (_, _) {});
        final setup = scoped.read(setupActionProvider.notifier);

        final config = loadYaml(await pushedConfigOf(scoped)) as YamlMap;
        await setup.updateConfig();
        scoped.read(runTimeProvider.notifier).value = 1;

        expect(config['external-controller'], '127.0.0.1:19090');
        expect(config['authentication'], ['profile:secret']);
        expect(config['skip-auth-prefixes'], ['127.0.0.1/32']);
        verify(() => core.setupConfig(any())).called(1);
        final params =
            (verify(() => core.updateConfig(captureAny())).captured.single
                    as UpdateParams)
                .toJson();
        expect(params['external-controller'], isNull);
        expect(params['authentication'], isNull);
        expect(params['mixed-port'], isNull);
        expect(
          FlClashHttpOverrides.findProxyForReader(
            scoped.read,
            Uri.parse('https://example.com'),
          ),
          'PROXY profile:secret@localhost:17890',
        );
        expect(scoped.read(proxyStateProvider).port, 17890);
        expect(scoped.read(trayStateProvider).port, 17890);
      });

      group('a profile port the app cannot run with fails the setup', () {
        Future<List<String>> setupLog(
          ProviderContainer scoped, {
          required bool expectApplied,
        }) async {
          final printed = <String>[];
          final original = debugPrint;
          debugPrint = (message, {wrapWidth}) => printed.add('$message');
          try {
            await pushedConfigOf(scoped, expectApplied: expectApplied);
          } finally {
            debugPrint = original;
          }
          return printed;
        }

        _MockCoreHandlerInterface portCore(Map<String, int> ports) {
          final core = fixtureCore('minimal');
          when(() => core.getConfig(any())).thenAnswer(
            (_) async => {
              ...(coreReply('minimal', 'core.json') as Map<String, dynamic>),
              ...ports,
            },
          );
          when(
            () => core.getProfileKeys(any()),
          ).thenAnswer((_) async => {'proxies', 'rules', ...ports.keys});
          return core;
        }

        test('a mixed-port of 0 names the key and leaves the app '
            'dialling its own port', () async {
          final scoped = scopedSetup(
            portCore({'mixed-port': 0}),
            useProfileSettings: true,
          );
          scoped.listen(proxyStateProvider, (_, _) {});
          scoped.listen(trayStateProvider, (_, _) {});
          scoped.listen(sharedStateProvider, (_, _) {});
          scoped.read(runTimeProvider.notifier).value = 1;

          final printed = await setupLog(scoped, expectApplied: false);

          expect(
            printed.where((line) => line.contains('mixed-port')),
            isNotEmpty,
          );
          expect(scoped.read(proxyStateProvider).port, defaultMixedPort);
          expect(scoped.read(trayStateProvider).port, defaultMixedPort);
          expect(
            scoped.read(sharedStateProvider).vpnOptions?.port,
            defaultMixedPort,
          );
          expect(
            FlClashHttpOverrides.findProxyForReader(
              scoped.read,
              Uri.parse('https://example.com'),
            ),
            'PROXY localhost:$defaultMixedPort',
          );
        });

        test(
          'a port that takes the app\'s mixed port names both keys',
          () async {
            final scoped = scopedSetup(
              portCore({'port': defaultMixedPort}),
              useProfileSettings: true,
            );

            final printed = await setupLog(scoped, expectApplied: false);

            expect(
              printed.where(
                (line) =>
                    line.contains('port and mixed-port') &&
                    line.contains('$defaultMixedPort'),
              ),
              isNotEmpty,
            );
          },
        );

        test('ports apart from the app\'s set up as stated', () async {
          final scoped = scopedSetup(
            portCore({'port': 17891, 'socks-port': 0}),
            useProfileSettings: true,
          );

          final config = loadYaml(await pushedConfigOf(scoped)) as YamlMap;

          expect(config['port'], 17891);
          expect(config['mixed-port'], defaultMixedPort);
        });
      });

      group('TUN consent follows the effective tun.enable', () {
        Map<String, dynamic> tunReply(bool enable) => {
          ...(coreReply('minimal', 'core.json') as Map<String, dynamic>),
          'tun': {'enable': enable, 'stack': 'System', 'device': 'utun99'},
        };

        _MockCoreHandlerInterface tunCore(bool enable) {
          final core = fixtureCore('minimal');
          when(
            () => core.getConfig(any()),
          ).thenAnswer((_) async => tunReply(enable));
          when(
            () => core.getProfileKeys(any()),
          ).thenAnswer((_) async => {'proxies', 'rules', 'tun'});
          return core;
        }

        test('a profile that turns TUN on asks for consent', () async {
          final action = TestAuthorizingSetupAction();
          final scoped = scopedSetup(
            tunCore(true),
            useProfileSettings: true,
            action: () => action,
          );

          final config = loadYaml(await pushedConfigOf(scoped)) as YamlMap;

          expect(action.authorizeCalls, 1);
          expect(
            scoped.read(authorizedTunEnableProvider),
            TunAuthorizationState.authorized,
          );
          expect(config['tun']['enable'], true);
          expect(scoped.read(trayStateProvider).tunEnable, true);
        });

        test(
          'a profile that turns TUN on fails loudly without consent',
          () async {
            final action = TestAuthorizingSetupAction()
              ..authorizeResult = AuthorizeCode.error;
            final scoped = scopedSetup(
              tunCore(true),
              useProfileSettings: true,
              action: () => action,
            );

            final config = await pushedConfigOf(scoped, expectApplied: false);

            expect(action.authorizeCalls, 1);
            expect(config, isNot(contains('utun99')));
          },
        );

        test('on Android a profile that turns TUN on still sets up, '
            'its tun left to the core that ignores it', () async {
          final scoped = scopedSetup(
            tunCore(true),
            useProfileSettings: true,
            action: _AndroidSetupAction.new,
          );

          final config = loadYaml(await pushedConfigOf(scoped)) as YamlMap;

          expect(config['tun']['enable'], true);
          expect(config['tun']['device'], 'utun99');
        });

        test('a profile that turns TUN off never asks, '
            'whatever the app setting says', () async {
          final action = TestAuthorizingSetupAction();
          final core = tunCore(false);
          final scoped = scopedSetup(
            core,
            useProfileSettings: true,
            action: () => action,
            patchConfig: appPatchConfig.copyWith.tun(enable: true),
          );

          final config = loadYaml(await pushedConfigOf(scoped)) as YamlMap;
          await action.updateConfig();

          expect(action.authorizeCalls, 0);
          expect(config['tun']['enable'], false);
          expect(scoped.read(trayStateProvider).tunEnable, false);
          final params =
              (verify(() => core.updateConfig(captureAny())).captured.single
                      as UpdateParams)
                  .toJson();
          expect(params['tun'], isNull);
        });

        test('with the toggle off the app setting still decides', () async {
          final action = TestAuthorizingSetupAction();
          final scoped = scopedSetup(
            tunCore(false),
            useProfileSettings: false,
            action: () => action,
            patchConfig: appPatchConfig.copyWith.tun(enable: true),
          );

          final config = loadYaml(await pushedConfigOf(scoped)) as YamlMap;

          expect(action.authorizeCalls, 1);
          expect(config['tun']['enable'], true);
        });
      });
    });
  });
}
