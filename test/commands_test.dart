@Timeout(Duration(minutes: 2))
library;

import 'dart:convert';
import 'dart:io';

import 'package:api_model_scanner/api_model_scanner.dart';
import 'package:api_model_scanner/src/cli/update_check.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// The commands themselves, run the way a user runs them.
///
/// The unit tests pin each piece — the guard on a [Selection], the reads on a
/// record — but not that every command path applies them. A refactor that
/// drops the guard from one path, or skips the check on an older report,
/// would pass all of those and still delete a field read through `dynamic`.
/// These run the real CLI, in its own process, against a throwaway project:
/// the project root is the process's working directory, which a test cannot
/// change without affecting every other test running beside it.
const _model = '''
class Person {
  final List<DepositBank>? depositBank;

  Person({this.depositBank});

  factory Person.fromJson(Map<String, dynamic> json) => Person(
        depositBank: (json['depositBank'] as List?)
            ?.map((e) => DepositBank.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

class DepositBank {
  final double minAmount;
  final double maxAmount;
  final String branch;

  DepositBank({
    required this.minAmount,
    required this.maxAmount,
    required this.branch,
  });

  factory DepositBank.fromJson(Map<String, dynamic> json) => DepositBank(
        minAmount: (json['minAmount'] as num).toDouble(),
        maxAmount: (json['maxAmount'] as num).toDouble(),
        branch: json['branch'] as String,
      );
}
''';

/// `minAmount` is read only through a dynamic receiver; `maxAmount` through
/// a typed one; `branch` not at all.
const _app = '''
import 'models/person.dart';

double lowest(Person person) {
  var result = 0.0;
  for (final bank in person.depositBank ?? []) {
    result += bank.minAmount;
  }
  return result;
}

double highest(Person person) {
  var result = 0.0;
  for (final DepositBank bank in person.depositBank ?? []) {
    result += bank.maxAmount;
  }
  return result;
}
''';

void main() {
  late String snapshot;
  late Directory tools;

  // Compiled once: starting from source costs seconds a run, and these tests
  // run the CLI many times over.
  setUpAll(() async {
    tools = Directory.systemTemp.createTempSync('amscan_cli');
    snapshot = p.join(tools.path, 'amscan.dill');
    final compiled = await Process.run(
      Platform.resolvedExecutable,
      ['compile', 'kernel', 'bin/api_model_scanner.dart', '-o', snapshot],
    );
    expect(compiled.exitCode, 0, reason: '${compiled.stderr}');
  });

  tearDownAll(() => tools.deleteSync(recursive: true));

  late String root;
  late String model;
  late String app;
  late Directory config;

  setUp(() {
    // Resolved: on macOS the temp directory is reached through a symlink,
    // while the CLI sees the real path, and a tick is matched on the path.
    root = Directory.systemTemp
        .createTempSync('amscan_project')
        .resolveSymbolicLinksSync();
    model = p.join(root, 'lib', 'models', 'person.dart');
    app = p.join(root, 'lib', 'app.dart');
    File(model)
      ..createSync(recursive: true)
      ..writeAsStringSync(_model);
    File(app).writeAsStringSync(_app);
    config = Directory.systemTemp.createTempSync('amscan_config');
  });

  tearDown(() {
    Directory(root).deleteSync(recursive: true);
    config.deleteSync(recursive: true);
  });

  Future<String> amscan(List<String> args) async {
    final result = await Process.run(
      Platform.resolvedExecutable,
      [snapshot, ...args],
      workingDirectory: root,
      // Never the machine's own settings, and never the network.
      environment: {
        'XDG_CONFIG_HOME': config.path,
        UpdateCheck.optOutVariable: '1',
      },
    );
    return '${result.stdout}${result.stderr}';
  }

  int lineOf(String needle) =>
      _model.split('\n').indexWhere((l) => l.contains(needle)) + 1;

  /// What the scan records for this project, checked as a scan checks.
  List<CachedField> scanned({bool checked = true}) {
    CachedField field(String name) => CachedField(
          className: 'DepositBank',
          fieldName: name,
          filePath: model,
          line: lineOf('final ${name == 'branch' ? 'String' : 'double'} $name'),
        );
    final read = DynamicRead(filePath: app, line: 6, column: 20);
    return checked
        ? [
            field('minAmount').withDynamicReads([read]),
            field('branch').withDynamicReads(const []),
          ]
        : [field('minAmount'), field('branch')];
  }

  CacheStore cache() => CacheStore(root);

  void record(List<CachedField> fields) => cache().write(UnusedCache(
        scannedAt: DateTime(2026, 9, 30),
        projectRoot: root,
        modelsPath: p.join(root, 'lib', 'models'),
        totalFieldsScanned: 4,
        fields: fields,
      ));

  void tick(String path, List<(String, String)> boxes) {
    var text = File(path).readAsStringSync();
    for (final (from, to) in boxes) {
      expect(text, contains(from), reason: 'no "$from" to tick');
      text = text.replaceFirst(from, to);
    }
    File(path).writeAsStringSync(text);
  }

  const everything = (
    '- [ ] **SELECT EVERYTHING**',
    '- [x] **SELECT EVERYTHING**',
  );
  const wholeClass = (
    '- [ ] **All of `DepositBank`**',
    '- [x] **All of `DepositBank`**',
  );
  const minAmount = ('* [ ] **`minAmount`**', '* [x] **`minAmount`**');
  const branch = ('- [ ] **`branch`**', '- [x] **`branch`**');

  /// `live`, `commented` or `deleted`.
  String state(String declaration) {
    final source = File(model).readAsStringSync();
    if (RegExp('^\\s*final $declaration;', multiLine: true).hasMatch(source)) {
      return 'live';
    }
    return source.contains('/*final $declaration;*/') ? 'commented' : 'deleted';
  }

  String minAmountNow() => state('double minAmount');
  String branchNow() => state('String branch');

  group('scan', () {
    test('lists a field read dynamically apart, and says so', () async {
      final out =
          await amscan(['scan', '--models=lib/models', '-a', '--no-open']);
      final report = File(cache().reportPath).readAsStringSync();
      final section = report.indexOf('Read dynamically');
      final everything = report.indexOf('**SELECT EVERYTHING**');

      expect(out, contains('read dynamically'));
      expect(section, greaterThan(0));
      expect(report.indexOf('**`minAmount`**'),
          inInclusiveRange(section, everything));
      expect(report.indexOf('**`branch`**'), greaterThan(everything));
      expect(
        cache().read()!.fields.every((f) => f.dynamicChecked),
        isTrue,
        reason: 'every field it records is marked as checked',
      );
    });
  });

  group('remove', () {
    for (final (name, args, ticks) in [
      ('--all', ['--all'], <(String, String)>[]),
      ('-a', ['-a'], <(String, String)>[]),
      ('SELECT EVERYTHING', <String>[], [everything]),
      ('a class tick', <String>[], [wholeClass]),
    ]) {
      test('$name stops short of a field read dynamically', () async {
        record(scanned());
        tick(cache().reportPath, ticks);

        await amscan(['remove', '--models=lib/models', '--no-format', ...args]);

        expect(minAmountNow(), 'live');
        expect(branchNow(), 'deleted');
        expect(
          File(cache().reportPath).readAsStringSync(),
          contains('* [ ] **`minAmount`**'),
          reason: 'it stays listed, in its own section',
        );
      });
    }

    test('a tick of its own takes it, and names the read first', () async {
      record(scanned());
      tick(cache().reportPath, [minAmount]);

      final out =
          await amscan(['remove', '--models=lib/models', '--no-format']);

      expect(minAmountNow(), 'deleted');
      expect(branchNow(), 'live', reason: 'it was not ticked');
      expect(out, contains('read dynamically'));
      expect(out, contains('lib/app.dart:6'));
    });

    test('a report from before the check is checked before acting', () async {
      // The upgrade case: a cache whose empty reads mean "never looked".
      record(scanned(checked: false));

      final out = await amscan(
        ['remove', '--models=lib/models', '--all', '--no-format'],
      );

      expect(out, contains('predate the check'));
      expect(minAmountNow(), 'live');
      expect(branchNow(), 'deleted');
    });
  });

  group('disable', () {
    Future<void> disableBoth() async {
      record(scanned());
      tick(cache().reportPath, [minAmount, branch]);
      await amscan(['disable', '--models=lib/models', '--no-format']);
      expect(minAmountNow(), 'commented');
      expect(branchNow(), 'commented');
    }

    String disabledReport() => DisabledStore(root).reportPath;

    test('the record lists a field read dynamically apart', () async {
      await disableBoth();
      final report = File(disabledReport()).readAsStringSync();

      expect(report.indexOf('* [ ] **`minAmount`**'),
          lessThan(report.indexOf('**SELECT EVERYTHING**')));
      expect(DisabledStore(root).read()
          .firstWhere((f) => f.fieldName == 'minAmount')
          .readDynamically, isTrue);
    });

    test('--undo hands it back to its own section, not the main table',
        () async {
      await disableBoth();

      await amscan(['disable', '--undo', '--all', '--no-format']);

      expect(minAmountNow(), 'live');
      expect(branchNow(), 'live');
      final back = {for (final f in cache().read()!.fields) f.fieldName: f};
      expect(back['minAmount']!.readDynamically, isTrue);
      expect(back['branch']!.readDynamically, isFalse);
      expect(
        File(cache().reportPath).readAsStringSync(),
        contains('* [ ] **`minAmount`**'),
      );
    });

    for (final (name, args, ticks) in [
      ('--all', ['--all'], <(String, String)>[]),
      ('SELECT EVERYTHING', <String>[], [everything]),
    ]) {
      test('--remove with $name stops short of it', () async {
        await disableBoth();
        tick(disabledReport(), ticks);

        await amscan(
          ['disable', '--remove', '--force', '--no-format', ...args],
        );

        expect(minAmountNow(), 'commented', reason: 'kept, still disabled');
        expect(branchNow(), 'deleted');
      });
    }

    test('--remove with a tick of its own deletes it', () async {
      await disableBoth();
      tick(disabledReport(), [minAmount]);

      final out =
          await amscan(['disable', '--remove', '--force', '--no-format']);

      expect(minAmountNow(), 'deleted');
      expect(branchNow(), 'commented', reason: 'it was not ticked');
      expect(out, contains('Deleting 1 field read dynamically'));
    });

    test('a record from before the check is checked before --remove',
        () async {
      await disableBoth();
      final json = File(DisabledStore(root).jsonPath);
      final data = jsonDecode(json.readAsStringSync()) as Map<String, dynamic>;
      for (final field in data['fields'] as List<dynamic>) {
        (field as Map<String, dynamic>)
          ..remove('dynamicReads')
          ..remove('checked');
      }
      json.writeAsStringSync(jsonEncode(data));

      final out = await amscan(
          ['disable', '--remove', '--all', '--force', '--no-format']);

      expect(out, contains('predate the check'));
      expect(minAmountNow(), 'commented');
      expect(branchNow(), 'deleted');
    });
  });
}
