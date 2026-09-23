import 'dart:io';

import 'package:api_model_scanner/src/cli/gui.dart';
import 'package:api_model_scanner/src/cli/update_check.dart';
import 'package:test/test.dart';

void main() {
  group('deciding a version is newer', () {
    test('compares numbers, not text', () {
      // The case a plain string sort gets backwards.
      expect(isNewerVersion('1.0.10', '1.0.9'), isTrue);
      expect(isNewerVersion('1.0.9', '1.0.10'), isFalse);
    });

    test('an equal or older version is not news', () {
      expect(isNewerVersion('1.0.3', '1.0.3'), isFalse);
      expect(isNewerVersion('1.0.2', '1.0.3'), isFalse);
    });

    test('a later major or minor wins over a later patch', () {
      expect(isNewerVersion('2.0.0', '1.9.9'), isTrue);
      expect(isNewerVersion('1.1.0', '1.0.99'), isTrue);
    });

    test('suffixes are dropped rather than ranked', () {
      expect(isNewerVersion('1.0.4-beta', '1.0.3'), isTrue);
      expect(isNewerVersion('1.0.3-beta', '1.0.3'), isFalse);
    });

    test('nonsense is never newer', () {
      expect(isNewerVersion('', '1.0.0'), isFalse);
      expect(isNewerVersion('latest', '1.0.0'), isFalse);
      expect(isNewerVersion('1.0', '1.0.0'), isFalse);
    });
  });

  group('deciding whether to ask pub.dev', () {
    late Directory temp;
    late String cache;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('amscan_update');
      cache = '${temp.path}/update_check.json';
    });

    tearDown(() => temp.deleteSync(recursive: true));

    test('having never asked, it asks', () {
      expect(isDue(cache), isTrue);
    });

    test('having just asked, it waits', () {
      final now = DateTime(2026, 1, 1, 12);
      UpdateCheck.remember('1.0.3', cacheFilePath: cache, now: now);

      expect(isDue(cache, now: now.add(const Duration(hours: 23))), isFalse);
      expect(isDue(cache, now: now.add(const Duration(hours: 25))), isTrue);
    });

    test('the opt-out is honoured even with no cache at all', () {
      expect(
        UpdateCheck.isDue(
          cacheFilePath: cache,
          env: {UpdateCheck.optOutVariable: '1'},
        ),
        isFalse,
      );
    });

    test('what was last heard survives the wait', () {
      UpdateCheck.remember('9.9.9', cacheFilePath: cache);

      expect(UpdateCheck.lastKnown(cacheFilePath: cache), '9.9.9');
    });

    test('an unreadable cache is a reason to ask, not to crash', () {
      File(cache).writeAsStringSync('{ not json');

      expect(isDue(cache), isTrue);
      expect(UpdateCheck.lastKnown(cacheFilePath: cache), isNull);
    });
  });

  group('labelling an editor option', () {
    test('the common one says so, so nobody has to guess', () {
      expect(
        editorOptionLabel('code', detected: false),
        'VS Code (code) (most common)',
      );
    });

    test('both notes share one bracket', () {
      expect(
        editorOptionLabel('code', detected: true),
        'VS Code (code) (Auto detected, most common)',
      );
    });

    test('an editor that is neither carries no bracket', () {
      expect(
        editorOptionLabel('windsurf', detected: false),
        'Windsurf (windsurf)',
      );
    });

    test('a detected editor that is not the common one says only that', () {
      expect(
        editorOptionLabel('cursor', detected: true),
        'Cursor (cursor) (Auto detected)',
      );
    });
  });
}

bool isDue(String cache, {DateTime? now}) =>
    UpdateCheck.isDue(cacheFilePath: cache, now: now, env: const {});
