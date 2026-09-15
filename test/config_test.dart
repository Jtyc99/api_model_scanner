import 'dart:io';

import 'package:api_model_scanner/src/cli/config.dart';
import 'package:api_model_scanner/src/scanning/model_discovery.dart';
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

  group('a models path may be a directory or one file', () {
    File write(String relative, String content) {
      final file = File(p.join(temp.path, relative));
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(content);
      return file;
    }

    test('a directory yields every .dart file under it', () {
      write('models/a.dart', 'class A {}');
      write('models/nested/b.dart', 'class B {}');
      write('models/notes.txt', 'ignored');

      final found = dartFilesAt(p.join(temp.path, 'models'));

      expect(found.map((f) => p.basename(f.path)), unorderedEquals(['a.dart', 'b.dart']));
    });

    test('a single .dart file yields just that file', () {
      final only = write('models/user_cover.dart', 'class UserCover {}');

      final found = dartFilesAt(only.path);

      expect(found.map((f) => f.path), [only.path]);
    });

    test('a file that is not Dart source is rejected clearly', () {
      final notes = write('models/notes.txt', 'nope');

      expect(
        () => dartFilesAt(notes.path),
        throwsA(isA<NotADartFile>()),
      );
    });

    test('a path that does not exist is reported as missing', () {
      expect(
        () => dartFilesAt(p.join(temp.path, 'nowhere')),
        throwsA(isA<ModelsDirectoryNotFound>()),
      );
    });
  });
}
