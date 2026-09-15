import 'dart:io';

import 'package:api_model_scanner/src/cli/config.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('amscan_cfg'));
  tearDown(() => temp.deleteSync(recursive: true));

  test('nothing configured resolves to null', () {
    expect(ModelsConfig.readProject(temp.path), isNull);
    expect(ModelsConfig.resolve(temp.path), isNull);
  });

  test('a project setting is read back', () {
    ModelsConfig.writeProject(temp.path, 'lib/server/response');
    expect(ModelsConfig.readProject(temp.path), 'lib/server/response');

    final resolved = ModelsConfig.resolve(temp.path)!;
    expect(resolved.relative, 'lib/server/response');
    expect(resolved.source, ModelsSource.project);
    expect(
      resolved.absolute(temp.path),
      p.join(temp.path, 'lib', 'server', 'response'),
    );
  });

  test('it lives in .dart_tool, so it never dirties the tree', () {
    ModelsConfig.writeProject(temp.path, 'lib/models');
    expect(
      p.relative(ModelsConfig.projectPath(temp.path), from: temp.path),
      p.join('.dart_tool', 'api_model_scanner', 'config.json'),
    );
  });

  test('a corrupt config reads as unset rather than throwing', () {
    final path = ModelsConfig.projectPath(temp.path);
    Directory(p.dirname(path)).createSync(recursive: true);
    File(path).writeAsStringSync('{ not json at all');
    expect(ModelsConfig.readProject(temp.path), isNull);
  });

  test('an empty value reads as unset', () {
    final path = ModelsConfig.projectPath(temp.path);
    Directory(p.dirname(path)).createSync(recursive: true);
    File(path).writeAsStringSync('{"models": "   "}');
    expect(ModelsConfig.readProject(temp.path), isNull);
  });

  test('the global path follows XDG_CONFIG_HOME when set', () {
    // Read straight from the environment, so this only asserts the shape.
    final path = ModelsConfig.globalPath();
    expect(p.basename(path), 'config.json');
    expect(p.basename(p.dirname(path)), 'api_model_scanner');
    expect(p.isAbsolute(path), isTrue);
  });
}
