import 'dart:io';

import 'package:api_model_scanner/src/scanning/dynamic_access.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// One model and every way of reading its fields, typed and not.
const _source = r'''
class Bank {
  final double minAmount;
  final double maxAmount;
  final void Function()? onTap;
  Bank(this.minAmount, this.maxAmount, this.onTap);
}

class Person {
  final List<Bank>? banks;
  Person(this.banks);
}

void forInWithEmptyFallback(Person person) {
  for (final bank in person.banks ?? []) {
    bank.minAmount;
  }
}

void nullAware(dynamic bank) => bank?.maxAmount;

void cascade(dynamic bank) => bank..minAmount;

void castToDynamic(Object bank) => (bank as dynamic).minAmount;

void throughAMap(Map<String, dynamic> json) => json['bank'].minAmount;

void callsAFunctionField(dynamic bank) => bank.onTap();

void typedIsFine(Person person) {
  for (final Bank bank in person.banks ?? []) {
    bank.maxAmount;
  }
}

void aStringKeyIsNotAMemberRead(Map<String, dynamic> json) =>
    json['minAmount'];
''';

void main() {
  late Directory project;

  setUp(() {
    project = Directory.systemTemp.createTempSync('amscan_dynamic');
    File(p.join(project.path, 'lib', 'app.dart'))
      ..createSync(recursive: true)
      ..writeAsStringSync(_source);
  });

  tearDown(() => project.deleteSync(recursive: true));

  Future<List<String>> reads(Set<String> names) async {
    final found = await findDynamicAccesses(
      projectRoot: project.path,
      names: names,
    );
    return [for (final access in found) '${access.name}:${access.line}'];
  }

  test('the case that started this: a for-in over `list ?? []`', () async {
    expect(await reads({'minAmount'}), contains('minAmount:15'));
  });

  test('every shape of dynamic read is seen', () async {
    final found = await reads({'minAmount', 'maxAmount', 'onTap'});

    expect(found, containsAll([
      'maxAmount:19', // bank?.maxAmount
      'minAmount:21', // bank..minAmount
      'minAmount:23', // (bank as dynamic).minAmount
      'minAmount:25', // json['bank'].minAmount
      'onTap:27', // bank.onTap()
    ]));
  });

  test('a typed receiver is not a dynamic read', () async {
    // Line 31 is `bank.maxAmount` on a `Bank`: the language server already
    // sees that one, so reporting it here would hold back a field for
    // nothing.
    expect(await reads({'maxAmount'}), isNot(contains('maxAmount:31')));
  });

  test('a string key is not a member read', () async {
    // `json['minAmount']` is how serialization reads a field, and every
    // model does it; counting it would hold back every field there is.
    expect(await reads({'minAmount'}), isNot(contains('minAmount:36')));
  });

  test('only the names asked about are reported', () async {
    expect(await reads({'maxAmount'}), everyElement(startsWith('maxAmount')));
  });

  test('with nothing to look for, nothing is resolved', () async {
    expect(await reads({}), isEmpty);
  });

  test('a name mentioned nowhere costs nothing', () async {
    expect(await reads({'neverMentioned'}), isEmpty);
  });

  test('the location points at the member, 1-based', () async {
    final found = await findDynamicAccesses(
      projectRoot: project.path,
      names: {'minAmount'},
    );
    final forIn = found.firstWhere((a) => a.line == 15);

    // `    bank.minAmount;` — the member starts at column 10.
    expect(forIn.column, 10);
    expect(forIn.filePath, endsWith(p.join('lib', 'app.dart')));
  });

  test('a file excluded from analysis is skipped, not fatal', () async {
    // The common case: json_serializable output, excluded in
    // analysis_options.yaml, mentioning every field as `instance.field`.
    // The analyzer will not resolve such a file, and asking it to used to
    // throw and end the scan.
    File(p.join(project.path, 'analysis_options.yaml')).writeAsStringSync(
      'analyzer:\n  exclude:\n    - "lib/generated/**"\n',
    );
    File(p.join(project.path, 'lib', 'generated', 'bank.g.dart'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        'void touch(dynamic instance) => instance.minAmount;',
      );

    final errors = <String>[];
    final found = await findDynamicAccesses(
      projectRoot: project.path,
      names: {'minAmount'},
      onError: (path, _) => errors.add(path),
    );

    expect(
      found.map((a) => a.filePath),
      everyElement(isNot(contains('generated'))),
    );
    expect(found, isNotEmpty, reason: 'the included file is still checked');
    expect(errors, isEmpty);
  });
}
