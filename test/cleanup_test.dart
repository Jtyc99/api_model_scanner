import 'dart:io';

import 'package:api_model_scanner/src/cleanup.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

late Directory temp;

String write(String relative, String content) {
  final file = File(p.join(temp.path, relative));
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(content);
  return file.path;
}

Future<CleanupResult> cleanup(List<String> modified) => cleanupAfterRemoval(
      projectRoot: temp.path,
      modifiedFiles: modified,
      restoreOnFailure: <String, String>{},
    );

void main() {
  setUp(() {
    temp = Directory.systemTemp.createTempSync('amscan_cleanup');
    write('pubspec.yaml', 'name: demo\n');
  });
  tearDown(() => temp.deleteSync(recursive: true));

  test('an emptied file nobody imports is deleted', () async {
    final orphan = write('lib/models/gone.dart', '\n');

    final result = await cleanup([orphan]);

    expect(result.deletedFiles, [orphan]);
    expect(File(orphan).existsSync(), isFalse);
  });

  test('an emptied file is kept while a relative import still names it',
      () async {
    final empty = write('lib/models/banner.dart', '\n');
    // Not in modifiedFiles: the importer was never touched by this run, so
    // verifying only the edited files would never see the dangling import.
    write('lib/ui/page.dart', "import '../models/banner.dart';\n");

    final result = await cleanup([empty]);

    expect(result.deletedFiles, isEmpty);
    expect(File(empty).existsSync(), isTrue);
  });

  test('a package: import counts the same as a relative one', () async {
    final empty = write('lib/models/banner.dart', '\n');
    write('lib/ui/page.dart', "import 'package:demo/models/banner.dart';\n");

    final result = await cleanup([empty]);

    expect(result.deletedFiles, isEmpty);
    expect(File(empty).existsSync(), isTrue);
  });

  test('another package with the same path does not hold it back', () async {
    final empty = write('lib/models/banner.dart', '\n');
    write('lib/ui/page.dart', "import 'package:other/models/banner.dart';\n");

    final result = await cleanup([empty]);

    expect(result.deletedFiles, [empty]);
  });

  test('an importer that is itself being deleted holds nothing back',
      () async {
    final a = write('lib/models/a.dart', "import 'b.dart';\n");
    final b = write('lib/models/b.dart', '\n');

    final result = await cleanup([a, b]);

    // `a` declares nothing either, so both go and neither pins the other.
    expect(result.deletedFiles, unorderedEquals([a, b]));
  });

  test('a file that still declares something is never deleted', () async {
    final live = write('lib/models/live.dart', 'class Live {}\n');

    final result = await cleanup([live]);

    expect(result.deletedFiles, isEmpty);
    expect(File(live).existsSync(), isTrue);
  });
}
