import 'package:drift/native.dart';
import 'package:fl_clash/database/database.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Database database;

  setUp(() {
    database = Database(NativeDatabase.memory());
  });

  tearDown(() async {
    await database.close();
  });

  test('a smart group keeps its tuning options through the database', () async {
    final group = ProxyGroup.fromJson({
      'id': 1,
      'name': 'HK',
      'type': 'smart',
      'uselightgbm': true,
      'policy-priority': 'ef:1.5;nx:0.5',
      'sample-rate': 0.25,
      'collectdata': false,
      'prefer-asn': true,
      'tolerance': 50,
    });
    const profile = Profile(id: 7, autoUpdateDuration: Duration.zero);
    await database.profiles.put(profile.toCompanion());
    await database.proxyGroups.put(group.toCompanion(profile.id));

    final stored =
        (await database.proxyGroupsDao.query(profile.id).get()).single;
    final json = stored.toJson();

    expect(json['uselightgbm'], isTrue);
    expect(json['policy-priority'], 'ef:1.5;nx:0.5');
    expect(json['sample-rate'], 0.25);
    expect(json['collectdata'], isFalse);
    expect(json['prefer-asn'], isTrue);
    expect(json['tolerance'], 50);
  });
}
