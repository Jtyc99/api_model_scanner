import 'dart:io';

import 'package:api_model_scanner/src/cache/disabled_store.dart';
import 'package:api_model_scanner/src/cli/uninstall.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('amscan_uninst'));
  tearDown(() => temp.deleteSync(recursive: true));

  void write(String relative, String content) {
    final file = File(p.join(temp.path, relative));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
  }

  String globalAt() => p.join(temp.path, 'cfg', 'config.json');

  group('planning an uninstall', () {
    test('finds nothing when nothing was ever set up', () {
      final plan = planUninstall(
        projectRoot: temp.path,
        globalConfigPath: globalAt(),
      );

      expect(plan.globalConfigDirectory, isNull);
      expect(plan.projectDirectory, isNull);
      expect(plan.isEmpty, isTrue);
    });

    test('names the config files it would remove', () {
      write('cfg/config.json', '{"models": "lib/a"}');
      write('.dart_tool/api_model_scanner/config.json', '{"models": "lib/b"}');

      final plan = planUninstall(
        projectRoot: temp.path,
        globalConfigPath: globalAt(),
      );

      expect(plan.globalConfigDirectory, p.join(temp.path, 'cfg'));
      expect(
        plan.projectDirectory,
        p.join(temp.path, '.dart_tool', 'api_model_scanner'),
      );
      expect(plan.isEmpty, isFalse);
    });

    test('counts fields left commented out', () {
      // Written through the real store rather than hand-rolled, so the test
      // cannot pass by agreeing with a schema nothing else uses.
      DisabledStore(temp.path).add([
        DisabledField(
          className: 'User',
          fieldName: 'nickname',
          filePath: p.join(temp.path, 'lib', 'a.dart'),
          snippets: const [DisabledSnippet('final String nickname;')],
          disabledAt: DateTime.now(),
          line: 3,
        ),
      ]);

      final plan = planUninstall(
        projectRoot: temp.path,
        globalConfigPath: globalAt(),
      );

      expect(plan.disabledFieldCount, 1);
      expect(plan.wouldStrandDisabledCode, isTrue,
          reason: 'deleting the record leaves commented-out code with no '
              'way to restore it');
    });

    test('is safe once nothing is commented out', () {
      write('.dart_tool/api_model_scanner/config.json', '{}');

      final plan = planUninstall(
        projectRoot: temp.path,
        globalConfigPath: globalAt(),
      );

      expect(plan.disabledFieldCount, 0);
      expect(plan.wouldStrandDisabledCode, isFalse);
    });
  });

  group('carrying it out', () {
    test('removes both config directories', () {
      write('cfg/config.json', '{"models": "lib/a"}');
      write('.dart_tool/api_model_scanner/config.json', '{"models": "lib/b"}');

      final plan = planUninstall(
        projectRoot: temp.path,
        globalConfigPath: globalAt(),
      );
      final removed = applyUninstall(plan);

      expect(Directory(p.join(temp.path, 'cfg')).existsSync(), isFalse);
      expect(
        Directory(p.join(temp.path, '.dart_tool', 'api_model_scanner'))
            .existsSync(),
        isFalse,
      );
      expect(removed, hasLength(2));
    });

    test('leaves the rest of .dart_tool alone', () {
      write('.dart_tool/api_model_scanner/config.json', '{}');
      write('.dart_tool/package_config.json', '{}');

      applyUninstall(planUninstall(
        projectRoot: temp.path,
        globalConfigPath: globalAt(),
      ));

      expect(
        File(p.join(temp.path, '.dart_tool', 'package_config.json'))
            .existsSync(),
        isTrue,
        reason: "only this tool's own directory is ours to delete",
      );
    });
  });
}
