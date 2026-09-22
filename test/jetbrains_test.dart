import 'dart:io';

import 'package:api_model_scanner/src/cli/jetbrains.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('amscan_jb'));
  tearDown(() => temp.deleteSync(recursive: true));

  Directory makeConfig(String name) =>
      Directory(p.join(temp.path, 'cfg', name))..createSync(recursive: true);

  group('finding where Android Studio keeps its settings', () {
    test('looks under the right place for each platform', () {
      expect(
        jetBrainsConfigRoots(home: '/Users/me', os: 'macos'),
        contains(p.join('/Users/me', 'Library', 'Application Support', 'Google')),
      );
      expect(
        jetBrainsConfigRoots(home: '/home/me', os: 'linux'),
        contains(p.join('/home/me', '.config', 'Google')),
      );
      expect(
        jetBrainsConfigRoots(home: r'C:\Users\me', os: 'windows'),
        isNotEmpty,
      );
    });

    test('finds each installed version', () {
      makeConfig('AndroidStudio2024.1');
      makeConfig('AndroidStudio2025.3.4');
      makeConfig('SomethingElse');

      final found = findJetBrainsIdes(roots: [p.join(temp.path, 'cfg')]);

      expect(
        found.map((ide) => p.basename(ide.configDirectory)),
        unorderedEquals(['AndroidStudio2024.1', 'AndroidStudio2025.3.4']),
      );
    });

    test('offers the newest one', () {
      makeConfig('AndroidStudio2024.1');
      makeConfig('AndroidStudio2025.3.4');
      makeConfig('AndroidStudio2025.1.1');

      final newest = newestJetBrainsIde(
        findJetBrainsIdes(roots: [p.join(temp.path, 'cfg')]),
      )!;

      expect(p.basename(newest.configDirectory), 'AndroidStudio2025.3.4');
    });

    test('a version is named in a way a person recognises', () {
      makeConfig('AndroidStudio2025.3.4');

      final ide = findJetBrainsIdes(roots: [p.join(temp.path, 'cfg')]).single;

      expect(ide.name, 'Android Studio 2025.3.4');
    });

    test('nothing installed yields nothing rather than throwing', () {
      expect(findJetBrainsIdes(roots: [p.join(temp.path, 'absent')]), isEmpty);
      expect(newestJetBrainsIde(const []), isNull);
    });
  });

  group('installing the plugin', () {
    late Directory source;

    setUp(() {
      source = Directory(p.join(temp.path, 'src', intellijPluginName))
        ..createSync(recursive: true);
      File(p.join(source.path, 'lib', 'plugin.jar'))
        ..createSync(recursive: true)
        ..writeAsStringSync('jar one');
      File(p.join(source.path, 'lib', 'report.jar'))
        ..createSync(recursive: true)
        ..writeAsStringSync('jar two');
    });

    test('copies it in, and is then seen as installed', () {
      final ide = JetBrainsIde('Android Studio 2025.3.4', makeConfig('AndroidStudio2025.3.4').path);
      expect(ide.hasPlugin, isFalse);

      installIntellijPlugin(ide: ide, source: source.path);

      expect(ide.hasPlugin, isTrue);
      expect(
        File(p.join(ide.pluginsDirectory, intellijPluginName, 'lib', 'report.jar'))
            .readAsStringSync(),
        'jar two',
      );
    });

    test('a second install replaces the first, leaving nothing stale', () {
      final ide = JetBrainsIde('AS', makeConfig('AndroidStudio2025.3.4').path);
      installIntellijPlugin(ide: ide, source: source.path);

      File(p.join(ide.pluginsDirectory, intellijPluginName, 'lib', 'old.jar'))
          .writeAsStringSync('stale');

      installIntellijPlugin(ide: ide, source: source.path);

      expect(
        File(p.join(ide.pluginsDirectory, intellijPluginName, 'lib', 'old.jar'))
            .existsSync(),
        isFalse,
        reason: 'a jar dropped from a later version must not linger',
      );
    });

    test('removing it leaves other plugins alone', () {
      final ide = JetBrainsIde('AS', makeConfig('AndroidStudio2025.3.4').path);
      installIntellijPlugin(ide: ide, source: source.path);
      Directory(p.join(ide.pluginsDirectory, 'SomeoneElse'))
          .createSync(recursive: true);

      expect(removeIntellijPlugin(ide), isTrue);

      expect(ide.hasPlugin, isFalse);
      expect(
        Directory(p.join(ide.pluginsDirectory, 'SomeoneElse')).existsSync(),
        isTrue,
      );
    });

    test('removing one that is not there says so rather than failing', () {
      final ide = JetBrainsIde('AS', makeConfig('AndroidStudio2025.3.4').path);
      expect(removeIntellijPlugin(ide), isFalse);
    });
  });

  group('comparing IDEs', () {
    test('two handles on the same installation are equal', () {
      // Without this, comparing a freshly-found IDE against the newest one —
      // which is a different instance of the same thing — silently never
      // matches, and code that looks obviously right does nothing.
      const a = JetBrainsIde('Android Studio 2025.3.4', '/cfg/AndroidStudio2025.3.4');
      const b = JetBrainsIde('Android Studio 2025.3.4', '/cfg/AndroidStudio2025.3.4');

      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });

    test('different installations are not equal', () {
      const a = JetBrainsIde('AS', '/cfg/AndroidStudio2025.3.4');
      const b = JetBrainsIde('AS', '/cfg/AndroidStudio2024.1');

      expect(a, isNot(equals(b)));
    });

    test('the newest one found compares equal to a fresh lookup', () {
      makeConfig('AndroidStudio2024.1');
      makeConfig('AndroidStudio2025.3.4');
      final roots = [p.join(temp.path, 'cfg')];

      expect(
        newestJetBrainsIde(findJetBrainsIdes(roots: roots)),
        equals(newestJetBrainsIde(findJetBrainsIdes(roots: roots))),
      );
    });
  });
}
