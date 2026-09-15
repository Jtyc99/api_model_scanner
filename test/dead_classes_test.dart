import 'package:api_model_scanner/api_model_scanner.dart';
import 'package:test/test.dart';

/// `Person` holds a `Job`; `Job` holds a `Salary`.
///
/// Offsets are synthetic but consistent: each class owns a 100-wide block, and
/// the field that names the next class sits inside its owner's block.
const _personFile = '/models/person.dart';
const _jobFile = '/models/job.dart';
const _salaryFile = '/models/salary.dart';

ModelClass person = const ModelClass(
  className: 'Person',
  filePath: _personFile,
  line: 0,
  column: 6,
  offset: 0,
  end: 100,
  fieldNames: ['name', 'job'],
  fieldTypes: {'Job'},
);

ModelClass job = const ModelClass(
  className: 'Job',
  filePath: _jobFile,
  line: 0,
  column: 6,
  offset: 0,
  end: 100,
  fieldNames: ['title', 'salary'],
  fieldTypes: {'Salary'},
);

ModelClass salary = const ModelClass(
  className: 'Salary',
  filePath: _salaryFile,
  line: 0,
  column: 6,
  offset: 0,
  end: 100,
  fieldNames: ['amount'],
  fieldTypes: {},
);

/// The declaration `Job? job;` inside Person, at offset 40..60.
const _jobFieldInPerson =
    RemovalRange(filePath: _personFile, start: 40, end: 60);

/// The declaration `Salary? salary;` inside Job, at offset 40..60.
const _salaryFieldInJob = RemovalRange(filePath: _jobFile, start: 40, end: 60);

void main() {
  test('a class whose fields are all unused and unreferenced is dead', () {
    final dead = resolveDeadClasses(
      classes: [job],
      unusedFieldKeys: {'Job.title', 'Job.salary'},
      classReferences: {'Job': const []},
      fieldRemovals: const [],
    );
    expect(dead, {'Job'});
  });

  test('a class still named from live code survives', () {
    // e.g. `Future<RootResponse<Job>>` in api_service.dart
    final dead = resolveDeadClasses(
      classes: [job],
      unusedFieldKeys: {'Job.title', 'Job.salary'},
      classReferences: {
        'Job': const [
          ClassReference(filePath: '/lib/api_service.dart', offset: 500),
        ],
      },
      fieldRemovals: const [],
    );
    expect(dead, isEmpty);
  });

  test('a reference from a field being removed does not keep it alive', () {
    // `Job? job;` inside Person is the only mention, and it is going.
    final dead = resolveDeadClasses(
      classes: [person, job],
      unusedFieldKeys: {'Job.title', 'Job.salary'},
      classReferences: {
        'Job': const [ClassReference(filePath: _personFile, offset: 45)],
      },
      fieldRemovals: const [_jobFieldInPerson],
    );
    expect(dead, {'Job'});
  });

  test('deadness cascades through a chain of classes', () {
    // Person.job goes -> Job dies -> Job.salary goes with it -> Salary dies.
    final dead = resolveDeadClasses(
      classes: [person, job, salary],
      unusedFieldKeys: {
        'Job.title',
        'Job.salary',
        'Salary.amount',
      },
      classReferences: {
        'Job': const [ClassReference(filePath: _personFile, offset: 45)],
        // Salary is only named from inside Job, which itself dies.
        'Salary': const [ClassReference(filePath: _jobFile, offset: 45)],
      },
      fieldRemovals: const [_jobFieldInPerson, _salaryFieldInJob],
    );
    expect(dead, {'Job', 'Salary'});
  });

  test('a live leaf stops the cascade', () {
    // Salary.amount is still used, so Salary lives; Job holds a live Salary,
    // but Job's own fields are all unused and its only mention is going.
    final dead = resolveDeadClasses(
      classes: [person, job, salary],
      unusedFieldKeys: {'Job.title', 'Job.salary'},
      classReferences: {
        'Job': const [ClassReference(filePath: _personFile, offset: 45)],
        'Salary': const [
          ClassReference(filePath: '/lib/pay_page.dart', offset: 10),
        ],
      },
      fieldRemovals: const [_jobFieldInPerson],
    );
    expect(dead, {'Job'});
    expect(dead.contains('Salary'), isFalse);
  });

  test('a class with a surviving field is never dead', () {
    final dead = resolveDeadClasses(
      classes: [job],
      unusedFieldKeys: {'Job.title'}, // salary still used
      classReferences: {'Job': const []},
      fieldRemovals: const [],
    );
    expect(dead, isEmpty);
  });

  test('self-references inside the class body are ignored', () {
    // `Job.fromJson` naming `Job` must not keep `Job` alive.
    final dead = resolveDeadClasses(
      classes: [job],
      unusedFieldKeys: {'Job.title', 'Job.salary'},
      classReferences: {
        'Job': const [ClassReference(filePath: _jobFile, offset: 30)],
      },
      fieldRemovals: const [],
    );
    expect(dead, {'Job'});
  });

  test('a class with no fields is never considered dead', () {
    const marker = ModelClass(
      className: 'Marker',
      filePath: '/models/marker.dart',
      line: 0,
      column: 6,
      offset: 0,
      end: 50,
      fieldNames: [],
      fieldTypes: {},
    );
    final dead = resolveDeadClasses(
      classes: [marker],
      unusedFieldKeys: const {},
      classReferences: {'Marker': const []},
      fieldRemovals: const [],
    );
    expect(dead, isEmpty);
  });

  test('removeClasses deletes the whole declaration', () {
    const source = '''
class Keep {
  final int? a;
}

class Drop {
  final int? b;
}
''';
    final result = ModelFieldFixer.removeClasses(
      content: source,
      path: 'x.dart',
      classNames: {'Drop'},
    );

    expect(result.changed, isTrue);
    expect(result.removedFields, {'Drop'});
    expect(result.newContent, contains('class Keep'));
    expect(result.newContent.contains('class Drop'), isFalse);
    expect(result.newContent.contains('int? b'), isFalse);
  });
}
