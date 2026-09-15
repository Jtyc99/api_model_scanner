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
}
''');

    final fields = await findModelFields(modelsPath: temp.path);

    expect(fields.map((f) => f.fieldName), ['value']);
  });

  test('finds fields across nested directories and multiple classes', () async {
    await writeModel('a.dart', 'class A { final int? x; A({this.x}); }');
    await writeModel('nested/b.dart', 'class B { final int? y; B({this.y}); }');

    final fields = await findModelFields(modelsPath: temp.path);

    expect(
      fields.map((f) => '${f.className}.${f.fieldName}').toSet(),
      {'A.x', 'B.y'},
    );
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
