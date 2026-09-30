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

/// `desktop` is plainly unused; `mobile` looks unused but is read through
/// `dynamic` somewhere. Disabling both must keep them apart — in the record,
/// in its report, and when `--undo` hands them back.
void main() {
  late Directory temp;
  late String modelPath;
  late DisabledStore store;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('disabled_dynamic');
    modelPath = p.join(temp.path, 'lib', 'models', 'banner.dart');
    File(modelPath)
      ..createSync(recursive: true)
      ..writeAsStringSync(_model);
    store = DisabledStore(temp.path);
  });

  tearDown(() => temp.deleteSync(recursive: true));

  final read = DynamicRead(filePath: '/app/lib/app.dart', line: 6, column: 20);

  CachedField cached(String name, {bool dynamic = false}) => CachedField(
        className: 'HomeBanner',
        fieldName: name,
        filePath: modelPath,
        line: name == 'desktop' ? 2 : 3,
        dynamicReads: dynamic ? [read] : const [],
      );

  DisabledField disabled(String name, {bool dynamic = false}) =>
      DisabledField(
        className: 'HomeBanner',
        fieldName: name,
        filePath: modelPath,
        snippets: [DisabledSnippet('final String? $name;')],
        disabledAt: DateTime(2026, 9, 30),
        line: name == 'desktop' ? 2 : 3,
        dynamicReads: dynamic ? [read] : const [],
      );

  group('disabling', () {
    test('records the reads of a field read dynamically', () async {
      final fields = [cached('desktop'), cached('mobile', dynamic: true)];
      final summary = await applySelection(
        projectRoot: temp.path,
        fields: fields,
        selection: Selection(fields: {for (final f in fields) f.key}),
        mode: EditMode.comment,
        runFormat: false,
        verify: false,
        log: (_) {},
      );

      final byName = {for (final f in summary.disabled) f.fieldName: f};
      expect(byName['mobile']!.readDynamically, isTrue);
      expect(byName['mobile']!.dynamicReads.single.line, 6);
      expect(byName['desktop']!.readDynamically, isFalse);
    });

    test('the record keeps them across a write and a read', () {
      store.write([disabled('desktop'), disabled('mobile', dynamic: true)]);
      final back = {for (final f in store.read()) f.fieldName: f};

      expect(back['mobile']!.dynamicReads.single.column, 20);
      expect(back['desktop']!.readDynamically, isFalse);
    });

    test('an older record, with no such key, loads as "no reads"', () {
      final old = DisabledField.fromJson({
        'class': 'HomeBanner',
        'field': 'mobile',
        'file': modelPath,
        'snippets': ['final String? mobile;'],
        'disabledAt': '2026-09-30T00:00:00.000',
      });

      expect(old.readDynamically, isFalse);
    });
  });

  group('undoing', () {
    test('hands a dynamic field back to the section it left', () {
      // The bug this guards: undo rebuilt each field without its reads, so a
      // field held apart came back into the table that SELECT EVERYTHING and
      // `--all` act on — the very removal it had been held apart from.
      final back = disabled('mobile', dynamic: true).toCachedField();

      expect(back.readDynamically, isTrue);
      expect(back.dynamicReads.single.line, 6);
      expect(back.key, cached('mobile').key);
    });

    test('and an ordinary field to the ordinary table', () {
      expect(disabled('desktop').toCachedField().readDynamically, isFalse);
    });
  });

  group('the disabled report', () {
    String render() {
      store.write([disabled('desktop'), disabled('mobile', dynamic: true)]);
      return File(store.reportPath).readAsStringSync();
    }

    String sectionOf(String report) => report.substring(
          report.indexOf('⚠️ Read dynamically'),
          report.indexOf('- [ ] **SELECT EVERYTHING**'),
        );

    test('lists the dynamic field first, apart, with where it is read', () {
      final report = render();
      final section = report.indexOf('⚠️ Read dynamically');
      final everything = report.indexOf('- [ ] **SELECT EVERYTHING**');

      expect(section, greaterThan(0));
      expect(everything, greaterThan(section));
      expect(
        report.indexOf('**`mobile`**'),
        inInclusiveRange(section, everything),
      );
      expect(report.indexOf('**`desktop`**'), greaterThan(everything));
      expect(report, contains('**Disabled — safe to select together**'));
      expect(report, matches(RegExp(r'read at \[[^\]]*app\.dart:6\]')));
    });

    test('writes that section in shapes no older editor can parse', () {
      final section = sectionOf(render());

      expect(section, isNot(contains('\n## ')));
      expect(section, isNot(matches(RegExp(r'^\s*- \[', multiLine: true))));
      expect(section, isNot(matches(RegExp(r'^# ', multiLine: true))));
      expect(section, contains('### HomeBanner'));
      expect(section, contains('* [ ] **`mobile`**'));
    });
  });

  group('choosing what to act on', () {
    Selection pick(String report, {required bool restore}) {
      final guarded = restore
          ? const <String>{}
          : {
              for (final f in store.read())
                if (f.readDynamically) f.selectionKey,
            };
      return parseSelection(report, projectRoot: temp.path).guarding(guarded);
    }

    bool takes(Selection s, String field) =>
        s.selectsWholeField(modelPath, 'HomeBanner', field);

    String reportWith(String from, String to) {
      store.write([disabled('desktop'), disabled('mobile', dynamic: true)]);
      return File(store.reportPath).readAsStringSync().replaceFirst(from, to);
    }

    test('--remove: SELECT EVERYTHING stops short of it', () {
      final s = pick(
        reportWith(
          '- [ ] **SELECT EVERYTHING**',
          '- [x] **SELECT EVERYTHING**',
        ),
        restore: false,
      );

      expect(takes(s, 'desktop'), isTrue);
      expect(takes(s, 'mobile'), isFalse);
    });

    test('--remove: a class tick stops short of it', () {
      final s = pick(
        reportWith('- [ ] **All of `HomeBanner`**',
            '- [x] **All of `HomeBanner`**'),
        restore: false,
      );

      expect(takes(s, 'mobile'), isFalse);
    });

    test('--remove: a tick of its own reaches it', () {
      final s = pick(
        reportWith('* [ ] **`mobile`**', '* [x] **`mobile`**'),
        restore: false,
      );

      expect(takes(s, 'mobile'), isTrue);
      expect(takes(s, 'desktop'), isFalse);
    });

    test('--undo: everything means everything — restoring is safe', () {
      final s = pick(
        reportWith(
          '- [ ] **SELECT EVERYTHING**',
          '- [x] **SELECT EVERYTHING**',
        ),
        restore: true,
      );

      expect(takes(s, 'desktop'), isTrue);
      expect(takes(s, 'mobile'), isTrue);
    });
  });

  group('telling "none" from "never looked"', () {
    // A record from before the check has an empty list of reads, which would
    // otherwise pass for "checked, none found" — and let an upgrade delete
    // exactly the field the check exists to keep.
    test('a field from an older cache loads as unchecked', () {
      final old = CachedField.fromJson({
        'class': 'HomeBanner',
        'field': 'mobile',
        'file': modelPath,
        'line': 3,
      });

      expect(old.dynamicChecked, isFalse);
    });

    test('a checked field says so, even when nothing was found', () {
      final checked = cached('desktop').withDynamicReads(const []);
      final back = CachedField.fromJson(checked.toJson());

      expect(back.dynamicChecked, isTrue);
      expect(back.readDynamically, isFalse);
    });

    test('a disabled record keeps the mark, and hands it back on undo', () {
      final record = disabled('mobile').withDynamicReads([read]);
      store.write([record]);
      final back = store.read().single;

      expect(back.dynamicChecked, isTrue);
      expect(back.toCachedField().dynamicChecked, isTrue);
      expect(back.toCachedField().readDynamically, isTrue);
    });

    test('a disabled record from an older version loads as unchecked', () {
      final old = DisabledField.fromJson({
        'class': 'HomeBanner',
        'field': 'mobile',
        'file': modelPath,
        'snippets': ['final String? mobile;'],
        'disabledAt': '2026-09-30T00:00:00.000',
      });

      expect(old.dynamicChecked, isFalse);
      expect(old.toCachedField().dynamicChecked, isFalse);
    });
  });
}
