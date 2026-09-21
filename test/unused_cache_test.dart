import 'dart:io';

import 'package:api_model_scanner/api_model_scanner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _model = '''
class HomeBanner {
  final String? desktop;
  final String? mobile;

  const HomeBanner({this.desktop, this.mobile});

  factory HomeBanner.fromJson(Map<String, dynamic> json) => HomeBanner(
        desktop: json['desktop']?.toString(),
        mobile: json['mobile']?.toString(),
      );

  Map<String, dynamic> toJson() => {
        if (desktop != null) 'desktop': desktop,
        if (mobile != null) 'mobile': mobile,
      };
}
''';

void main() {
  late Directory temp;
  late String modelPath;
  late CacheStore store;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('cache_test');
    modelPath = p.join(temp.path, 'lib', 'server', 'response', 'banner.dart');
    await File(modelPath).create(recursive: true);
    await File(modelPath).writeAsString(_model);
    store = CacheStore(temp.path);
  });

  tearDown(() async {
    if (temp.existsSync()) await temp.delete(recursive: true);
  });

  UnusedCache buildCache({List<CachedField>? fields}) => UnusedCache(
        scannedAt: DateTime.now(),
        projectRoot: temp.path,
        modelsPath: p.join(temp.path, 'lib', 'server', 'response'),
        totalFieldsScanned: 2,
        fields: fields ??
            [
              CachedField(
                className: 'HomeBanner',
                fieldName: 'desktop',
                filePath: modelPath,
                line: 2,
              ),
            ],
      );

  test('cache round-trips through JSON', () {
    expect(store.exists, isFalse);

    store.write(buildCache());

    expect(store.exists, isTrue);
    final read = store.read()!;
    expect(read.fields, hasLength(1));
    expect(read.fields.single.className, 'HomeBanner');
    expect(read.fields.single.fieldName, 'desktop');
    expect(read.fields.single.line, 2);
    expect(read.totalFieldsScanned, 2);
  });

  test('writes both the JSON cache and the Markdown report', () {
    store.write(buildCache());

    expect(File(store.jsonPath).existsSync(), isTrue);
    expect(File(store.reportPath).existsSync(), isTrue);
    // Lives under .dart_tool so it is git-ignored by default.
    expect(p.split(store.directory), contains('.dart_tool'));
  });

  test('delete removes both files', () {
    store.write(buildCache());
    store.delete();

    expect(store.exists, isFalse);
    expect(File(store.reportPath).existsSync(), isFalse);
  });

  test('a corrupt cache reads as absent rather than throwing', () {
    store.write(buildCache());
    File(store.jsonPath).writeAsStringSync('{not valid json');

    expect(store.read(), isNull);
  });

  test('report groups each field with the parts that would be removed', () {
    final report = store.renderReport(buildCache());

    expect(report, contains('## HomeBanner'));
    expect(report, contains('**`desktop`**'));
    // desktop appears in the declaration, constructor, fromJson and toJson.
    expect(report, contains('4 parts'));
    expect(report, contains('field declaration'));
    expect(report, contains('constructor parameter desktop'));
    expect(report, contains('named argument desktop'));
    expect(report, contains('map entry'));
    // The still-used field must not be listed at all.
    expect(report.contains('**`mobile`**'), isFalse);
    // Every selectable row carries an unticked checkbox.
    expect(report, contains('- [ ] **SELECT EVERYTHING**'));
    expect(report, contains('- [ ] **All of `HomeBanner`**'));
    // No hidden markers leak into the rendered output.
    expect(report.contains('<!--'), isFalse);
    expect(report.contains('!--'), isFalse);
    // Parts are labelled "line N", not "LN".
    expect(report, contains('[line 2]'));
    expect(report.contains('[L2]'), isFalse);
  });

  group('rows link twice, since no one link works in every editor', () {
    test('the class header is a relative link that resolves on disk', () {
      final report = store.renderReport(buildCache());

      final pattern = RegExp(r'\u2514 \[[^\]]+\]\((\.\.[^)#]*)\)');
      final match = pattern.firstMatch(report);
      expect(match, isNotNull, reason: 'class header should link the file');

      final target = p.normalize(p.join(store.directory, match!.group(1)!));
      expect(File(target).existsSync(), isTrue, reason: 'missing: $target');
    });

    test('each part carries a relative line link and a VS Code link', () {
      final report = store.renderReport(buildCache());

      // The relative one is what JetBrains' preview will follow.
      expect(report, matches(RegExp(r'\[line 2\]\(\.\.[^)]*#L2\)')));
      // The vscode one is the only form that lands on the line.
      expect(report, contains('[VS Code](vscode://file'));
    });

    test('relative line links resolve to a real file', () {
      final report = store.renderReport(buildCache());

      final pattern = RegExp(r'\[line \d+\]\((\.\.[^)#]+)#L\d+\)');
      final targets = pattern
          .allMatches(report)
          .map((m) => p.normalize(p.join(store.directory, m.group(1)!)))
          .toSet();

      expect(targets, isNotEmpty);
      for (final target in targets) {
        expect(File(target).existsSync(), isTrue, reason: 'missing: $target');
      }
    });
  });

  group('selection still round-trips through the rendered report', () {
    /// Ticks every box the parser recognises, the way a reader would.
    String tickAll(String report) => report
        .split('\n')
        .map((line) => line.replaceFirst('- [ ]', '- [x]'))
        .join('\n');

    test('an untouched report selects nothing', () {
      final selection = parseSelection(store.renderReport(buildCache()));
      expect(selection.isNotEmpty, isFalse);
    });

    test('a ticked field is read back as that field', () {
      final report = store
          .renderReport(buildCache())
          .replaceFirst('- [ ] **`desktop`**', '- [x] **`desktop`**');

      final selection = parseSelection(report);

      expect(selection.selectsWholeField('HomeBanner', 'desktop'), isTrue);
      expect(selection.selectsWholeField('HomeBanner', 'other'), isFalse);
    });

    test('a ticked class is read back as the whole class', () {
      final report = store
          .renderReport(buildCache())
          .replaceFirst("- [ ] **All of `HomeBanner`**",
              "- [x] **All of `HomeBanner`**");

      final selection = parseSelection(report);

      expect(selection.selectsWholeField('HomeBanner', 'desktop'), isTrue);
    });

    test('an indented part is read back as that part alone', () {
      final report = store.renderReport(buildCache());
      final lines = report.split('\n');
      final index =
          lines.indexWhere((l) => RegExp(r'^\s+-\s*\[ \]').hasMatch(l));
      expect(index, greaterThan(-1), reason: 'report should have part rows');
      lines[index] = lines[index].replaceFirst('[ ]', '[x]');

      final selection = parseSelection(lines.join('\n'));

      expect(selection.selectsPart('HomeBanner', 'desktop', 0), isTrue);
      expect(selection.selectsWholeField('HomeBanner', 'desktop'), isFalse);
    });

    test('ticking everything selects everything', () {
      final selection = parseSelection(tickAll(store.renderReport(buildCache())));
      expect(selection.all, isTrue);
    });
  });

  test('vscode links carry an absolute path, line and column', () {
    final report = store.renderReport(buildCache());

    // vscode://file/<abs path>:<line>:<col> is the form that moves the cursor.
    final pattern = RegExp(r'\]\(vscode://file([^:)]+):(\d+):(\d+)\)');
    final matches = pattern.allMatches(report).toList();
    expect(matches, isNotEmpty);

    for (final match in matches) {
      final target = Uri.decodeFull(match.group(1)!);
      expect(p.isAbsolute(target), isTrue, reason: target);
      expect(File(target).existsSync(), isTrue, reason: 'missing: $target');
      expect(int.parse(match.group(2)!), greaterThan(0));
      expect(match.group(3), '1');
    }
  });

  test('an empty result set still produces a readable report', () {
    final report = store.renderReport(buildCache(fields: []));

    expect(report, contains('No unused model fields found'));
    expect(report.contains('Would remove'), isFalse);
  });

  test('a field whose declaration vanished is flagged, not silently dropped',
      () {
    final cache = buildCache(fields: [
      CachedField(
        className: 'HomeBanner',
        fieldName: 'goneAway',
        filePath: modelPath,
        line: 99,
      ),
    ]);

    final report = store.renderReport(cache);

    expect(report, contains('**`goneAway`**'));
    expect(report, contains('No removable declaration found'));
  });
}
