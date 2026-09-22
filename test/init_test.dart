import 'dart:io';

import 'package:api_model_scanner/src/cli/config.dart';
import 'package:api_model_scanner/src/cli/init.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('amscan_init'));
  tearDown(() => temp.deleteSync(recursive: true));

  void write(String relative, String content) {
    final file = File(p.join(temp.path, relative));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
  }

  const aModel = '''
class User {
  final String id;
  User({required this.id});
  factory User.fromJson(Map<String, dynamic> json) =>
      User(id: json['id'] as String);
  Map<String, dynamic> toJson() => {'id': id};
}
''';

  group('checking a models path', () {
    test('a directory of model classes is accepted', () async {
      write('lib/models/user.dart', aModel);

      final checked =
          await checkModelsPath(projectRoot: temp.path, relative: 'lib/models');

      expect(checked.verdict, ModelsPathVerdict.ok);
    });

    test('it says how many model classes are there', () async {
      write('lib/models/user.dart', aModel);
      write('lib/models/order.dart', aModel.replaceAll('User', 'Order'));

      final checked =
          await checkModelsPath(projectRoot: temp.path, relative: 'lib/models');

      expect(checked.classCount, 2,
          reason: 'the count confirms the path was the right one');
    });

    test('a single model file is accepted', () async {
      write('lib/models/user.dart', aModel);

      expect(
        (await checkModelsPath(
          projectRoot: temp.path,
          relative: 'lib/models/user.dart',
        ))
            .verdict,
        ModelsPathVerdict.ok,
      );
    });

    test('a path outside the project is refused', () async {
      expect(
        (await checkModelsPath(
          projectRoot: temp.path,
          relative: '../elsewhere',
        ))
            .verdict,
        ModelsPathVerdict.outsideProject,
      );
    });

    test('a path that is not there is refused', () async {
      expect(
        (await checkModelsPath(projectRoot: temp.path, relative: 'lib/nope'))
            .verdict,
        ModelsPathVerdict.missing,
      );
    });

    test('a file that is not Dart source is refused', () async {
      write('lib/models/notes.txt', 'nope');

      expect(
        (await checkModelsPath(
          projectRoot: temp.path,
          relative: 'lib/models/notes.txt',
        ))
            .verdict,
        ModelsPathVerdict.notADartFile,
      );
    });

    test('a real directory holding no models is reported, not refused',
        () async {
      write('lib/widgets/button.dart', 'class Button {}');

      expect(
        (await checkModelsPath(projectRoot: temp.path, relative: 'lib/widgets'))
            .verdict,
        ModelsPathVerdict.noModelClasses,
      );
    });
  });

  group('saving what init learned', () {
    String globalAt() => p.join(temp.path, 'global', 'config.json');

    test('a machine-wide answer writes every setting given', () {
      applyInit(
        const InitAnswers(models: 'lib/models', gui: true, editor: 'cursor'),
        projectRoot: temp.path,
        globalConfigPath: globalAt(),
      );

      expect(
        ModelsConfig.resolve(temp.path, globalConfigPath: globalAt())!.relative,
        'lib/models',
      );
      expect(
        ModelsConfig.readGuiPreference(globalConfigPath: globalAt()),
        isTrue,
      );
      expect(ModelsConfig.readEditor(globalConfigPath: globalAt()), 'cursor');
    });

    test('an unanswered question is left unwritten, not written false', () {
      applyInit(
        const InitAnswers(models: 'lib/models'),
        projectRoot: temp.path,
        globalConfigPath: globalAt(),
      );

      expect(
        ModelsConfig.readGuiPreference(globalConfigPath: globalAt()),
        isNull,
        reason: 'nobody was asked, so nothing was declined',
      );
      expect(ModelsConfig.readEditor(globalConfigPath: globalAt()), isNull);
    });

    test('a project answer writes only the models directory, in .dart_tool',
        () {
      applyInit(
        const InitAnswers(models: 'lib/api', forProject: true),
        projectRoot: temp.path,
        globalConfigPath: globalAt(),
      );

      expect(ModelsConfig.readProject(temp.path), 'lib/api');
      expect(File(globalAt()).existsSync(), isFalse,
          reason: 'a per-project answer says nothing about this machine');
    });

    test('it reports where it wrote', () {
      final written = applyInit(
        const InitAnswers(models: 'lib/api', forProject: true),
        projectRoot: temp.path,
        globalConfigPath: globalAt(),
      );

      expect(written, ModelsConfig.projectPath(temp.path));
    });
  });

  group('recognising a Dart project', () {
    test('a directory with a pubspec is one', () {
      write('pubspec.yaml', 'name: demo\n');
      expect(looksLikeDartProject(temp.path), isTrue);
    });

    test('a bare directory is not', () {
      expect(looksLikeDartProject(temp.path), isFalse);
    });
  });

  group('a machine-wide run records that init happened', () {
    String globalAt() => p.join(temp.path, 'global', 'config.json');

    test('even when every question was skipped', () {
      applyInit(
        const InitAnswers(),
        projectRoot: temp.path,
        globalConfigPath: globalAt(),
      );

      expect(File(globalAt()).existsSync(), isTrue,
          reason: 'otherwise the next command cannot tell "init was never '
              'run" from "init ran and I chose to set it per project"');
      expect(ModelsConfig.hasGlobalConfig(globalConfigPath: globalAt()),
          isTrue);
    });

    test('a project-only run does not claim the machine was set up', () {
      applyInit(
        const InitAnswers(models: 'lib/api', forProject: true),
        projectRoot: temp.path,
        globalConfigPath: globalAt(),
      );

      expect(ModelsConfig.hasGlobalConfig(globalConfigPath: globalAt()),
          isFalse);
    });
  });

  group('telling the user what to run', () {
    test('with nothing set up at all, it points at init', () {
      final guidance = const ModelsDirectoryNotSet().guidance.join('\n');

      expect(guidance, contains('amscan init'));
      expect(guidance, isNot(contains('--project')));
    });

    test('once init has run, it points at this project', () {
      final guidance =
          const ModelsDirectoryNotSet(initialised: true).guidance.join('\n');

      expect(guidance, contains('amscan init --project'));
    });

    test('it never mentions the command that no longer exists', () {
      for (final e in [
        const ModelsDirectoryNotSet(),
        const ModelsDirectoryNotSet(initialised: true),
      ]) {
        expect(e.guidance.join('\n'), isNot(contains('set-default')));
        expect(e.toString(), isNot(contains('set-default')));
      }
    });
  });
}
