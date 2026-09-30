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
}
''';

/// `desktop` is plainly unused; `mobile` looks unused but is read somewhere
/// through `dynamic`. The report has to keep them apart, and every way of
/// saying "everything" has to stop short of `mobile`.
void main() {
  late Directory temp;
  late String modelPath;
  late CacheStore store;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('dynamic_section');
    modelPath = p.join(temp.path, 'lib', 'models', 'banner.dart');
    File(modelPath)
      ..createSync(recursive: true)
      ..writeAsStringSync(_model);
    store = CacheStore(temp.path);
  });

  tearDown(() => temp.deleteSync(recursive: true));

  UnusedCache cache({bool withSafe = true}) => UnusedCache(
        scannedAt: DateTime(2026, 9, 29),
        projectRoot: temp.path,
        modelsPath: p.join(temp.path, 'lib', 'models'),
        totalFieldsScanned: 2,
        fields: [
          if (withSafe)
            CachedField(
              className: 'HomeBanner',
              fieldName: 'desktop',
              filePath: modelPath,
              line: 2,
            ),
          CachedField(
            className: 'HomeBanner',
            fieldName: 'mobile',
            filePath: modelPath,
            line: 3,
            dynamicReads: [
              DynamicRead(
                filePath: p.join(temp.path, 'lib', 'app.dart'),
                line: 6,
                column: 20,
              ),
            ],
          ),
        ],
      );

  Selection read(String report) {
    final keys = {
      for (final f in cache().fields)
        if (f.readDynamically) f.key,
    };
    return parseSelection(report, projectRoot: temp.path).guarding(keys);
  }

  bool takes(Selection s, String field) =>
      s.selectsWholeField(modelPath, 'HomeBanner', field);

  group('the report', () {
    /// The guarded section alone: from its banner to Select Everything.
    String sectionOf(String report) => report.substring(
          report.indexOf('⚠️ Read dynamically'),
          report.indexOf('- [ ] **SELECT EVERYTHING**'),
        );

    test('lists the dynamic field first, apart, with where it is read', () {
      final report = store.renderReport(cache());
      final section = report.indexOf('⚠️ Read dynamically');
      final everything = report.indexOf('- [ ] **SELECT EVERYTHING**');

      // First, so the few rows that must not be missed are the ones nobody
      // has to scroll to.
      expect(section, greaterThan(0));
      expect(everything, greaterThan(section));
      expect(
        report.indexOf('**`mobile`**'),
        inInclusiveRange(section, everything),
      );
      expect(report.indexOf('**`desktop`**'), greaterThan(everything));
      expect(report, contains('read at [lib/app.dart:6]'));
    });

    test('writes that section in shapes no older editor can parse', () {
      final report = store.renderReport(cache());
      final section = sectionOf(report);

      // A `##` heading or a `-` task item here is exactly what an older table
      // editor's SELECT EVERYTHING would find and tick.
      expect(section, isNot(contains('\n## ')));
      expect(section, isNot(matches(RegExp(r'^\s*- \[', multiLine: true))));
      expect(section, contains('### HomeBanner'));
      // Nor a `# ` line, which those editors would show as the title.
      expect(section, isNot(matches(RegExp(r'^# ', multiLine: true))));
      expect(section, contains('* [ ] **`mobile`**'));
    });

    test('offers no SELECT EVERYTHING when nothing is safe to take', () {
      final report = store.renderReport(cache(withSafe: false));

      // The box, not the words: the section's own text names the box to say
      // it never reaches there.
      expect(report, isNot(contains('- [ ] **SELECT EVERYTHING**')));
      expect(report, contains('**`mobile`**'));
    });
  });

  group('every way of saying "everything" stops short', () {
    test('SELECT EVERYTHING', () {
      final s = read(store.renderReport(cache()).replaceFirst(
          '- [ ] **SELECT EVERYTHING**', '- [x] **SELECT EVERYTHING**'));

      expect(takes(s, 'desktop'), isTrue);
      expect(takes(s, 'mobile'), isFalse);
    });

    test('ticking the whole class', () {
      final s = read(store.renderReport(cache()).replaceFirst(
          '- [ ] **All of `HomeBanner`**', '- [x] **All of `HomeBanner`**'));

      expect(takes(s, 'desktop'), isTrue);
      expect(takes(s, 'mobile'), isFalse);
    });

    test('--all and -a, which never read the report', () {
      final keys = {
        for (final f in cache().fields)
          if (f.readDynamically) f.key,
      };
      final s = const Selection(all: true).guarding(keys);

      expect(takes(s, 'desktop'), isTrue);
      expect(takes(s, 'mobile'), isFalse);
    });

    test('every part of the guarded field, via SELECT EVERYTHING', () {
      final s = read(store.renderReport(cache()).replaceFirst(
          '- [ ] **SELECT EVERYTHING**', '- [x] **SELECT EVERYTHING**'));

      for (var i = 0; i < 3; i++) {
        expect(s.selectsPart(modelPath, 'HomeBanner', 'mobile', i), isFalse);
      }
    });
  });

  group('a tick of its own is honoured', () {
    test('ticking the field takes it', () {
      final s = read(store
          .renderReport(cache())
          .replaceFirst('* [ ] **`mobile`**', '* [x] **`mobile`**'));

      expect(takes(s, 'mobile'), isTrue);
      expect(takes(s, 'desktop'), isFalse, reason: 'nothing else was ticked');
      expect(s.touchesGuarded(cache().fields.last.key), isTrue);
    });

    test('ticking one part takes only that part', () {
      final report = store.renderReport(cache());
      final firstPart = RegExp(r'^  \* \[ \]', multiLine: true);
      final section = report.indexOf('⚠️ Read dynamically');
      final at = report.indexOf(firstPart, section);
      final ticked =
          '${report.substring(0, at)}  * [x]${report.substring(at + 7)}';

      final s = read(ticked);

      expect(s.selectsPart(modelPath, 'HomeBanner', 'mobile', 0), isTrue);
      expect(s.selectsPart(modelPath, 'HomeBanner', 'mobile', 1), isFalse);
      expect(takes(s, 'mobile'), isFalse, reason: 'one part is not the field');
    });
  });

  group('the cache', () {
    test('keeps dynamic reads across a write and a read', () {
      store.write(cache());
      final back = store.read()!;
      final mobile = back.fields.firstWhere((f) => f.fieldName == 'mobile');

      expect(mobile.readDynamically, isTrue);
      expect(mobile.dynamicReads.single.line, 6);
      expect(mobile.dynamicReads.single.column, 20);
    });

    test('an older cache, with no such key, loads as "no reads"', () {
      final old = CachedField.fromJson({
        'class': 'HomeBanner',
        'field': 'mobile',
        'file': modelPath,
        'line': 3,
      });

      expect(old.readDynamically, isFalse);
    });
  });
}
