import 'dart:io';

import 'package:api_model_scanner/api_model_scanner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('api_model_scanner_test');
  });

  tearDown(() async {
    if (temp.existsSync()) {
      await temp.delete(recursive: true);
    }
  });

  Future<void> writeModel(String name, String source) async {
    final file = File(p.join(temp.path, name));
    await file.create(recursive: true);
    await file.writeAsString(source);
  }

  test('discovers instance fields with their locations', () async {
    await writeModel('home_banner.dart', '''
class HomeBanner {
  final String? desktop;
  final String? mobile;

  const HomeBanner({this.desktop, this.mobile});

  Map<String, dynamic> toJson() => {'desktop': desktop, 'mobile': mobile};
}
''');

    final fields = await findModelFields(modelsPath: temp.path);

    expect(fields.map((f) => f.fieldName), ['desktop', 'mobile']);
    expect(fields.every((f) => f.className == 'HomeBanner'), isTrue);
    // Zero-based line of `desktop` (it is on source line 2).
    expect(fields.first.line, 1);
  });

  test('skips static fields', () async {
    await writeModel('with_static.dart', '''
class Config {
  static const String key = 'k';
  final String? value;

  const Config({this.value});

  Map<String, dynamic> toJson() => {'value': value};
}
''');

    final fields = await findModelFields(modelsPath: temp.path);

    expect(fields.map((f) => f.fieldName), ['value']);
  });

  test('finds fields across nested directories and multiple classes', () async {
    await writeModel('a.dart',
        'class A { final int? x; A({this.x}); Map toJson() => {}; }');
    await writeModel('nested/b.dart',
        'class B { final int? y; B({this.y}); Map toJson() => {}; }');

    final fields = await findModelFields(modelsPath: temp.path);

    expect(
      fields.map((f) => '${f.className}.${f.fieldName}').toSet(),
      {'A.x', 'B.y'},
    );
  });

  group('only serialized classes are treated as models', () {
    test('a class with neither fromJson nor toJson is skipped', () async {
      await writeModel('helper.dart', '''
class Helper {
  final String? label;
  const Helper({this.label});
}
''');

      final discovered = await findModels(modelsPath: temp.path);

      expect(discovered.fields, isEmpty);
      expect(discovered.classes, isEmpty);
      expect(discovered.skipped, ['Helper']);
    });

    test('a `fromJson` factory alone qualifies', () async {
      await writeModel('user.dart', '''
class User {
  final String? name;
  const User({this.name});

  factory User.fromJson(Map<String, dynamic> json) =>
      User(name: json['name'] as String?);
}
''');

      final discovered = await findModels(modelsPath: temp.path);

      expect(discovered.fields.map((f) => f.fieldName), ['name']);
      expect(discovered.skipped, isEmpty);
    });

    test('a subclass inherits the marker from a base in the same file',
        () async {
      // The alias-subclass shape: serialization lives on the base.
      await writeModel('country.dart', '''
class Country {
  final String? id;
  const Country({this.id});

  Map<String, dynamic> toJson() => {'id': id};
}

class Currency extends Country {
  final String? symbol;
  const Currency({super.id, this.symbol});
}
''');

      final discovered = await findModels(modelsPath: temp.path);

      expect(
        discovered.fields.map((f) => '${f.className}.${f.fieldName}').toSet(),
        {'Country.id', 'Currency.symbol'},
      );
      expect(discovered.skipped, isEmpty);
    });

    test('model and non-model classes in one file are separated', () async {
      await writeModel('mixed.dart', '''
class Payload {
  final String? body;
  const Payload({this.body});

  Map<String, dynamic> toJson() => {'body': body};
}

class Formatter {
  final String? pattern;
  const Formatter({this.pattern});
}
''');

      final discovered = await findModels(modelsPath: temp.path);

      expect(discovered.fields.map((f) => f.fieldName), ['body']);
      expect(discovered.skipped, ['Formatter']);
    });
  });

  test('missing models directory throws a typed error', () async {
    expect(
      () => findModelFields(modelsPath: p.join(temp.path, 'nope')),
      throwsA(isA<ModelsDirectoryNotFound>()),
    );
  });

  test('references inside the model file are treated as internal', () {
    final field = ModelField(
      className: 'HomeBanner',
      fieldName: 'desktop',
      filePath: '/project/lib/models/home_banner.dart',
      line: 1,
      column: 2,
    );

    final internal = Reference(
      filePath: '/project/lib/models/home_banner.dart',
      line: 9,
      column: 4,
    );
    final external = Reference(
      filePath: '/project/lib/ui/banner.dart',
      line: 3,
      column: 8,
    );

    expect(isInsideModelFile(internal, field), isTrue);
    expect(isInsideModelFile(external, field), isFalse);
  });
}
