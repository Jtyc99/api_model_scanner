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
    RemovalRange(filePath: _personFile, start: 40, end: 60, fieldKey: 'Person.job');

/// The declaration `Salary? salary;` inside Job, at offset 40..60.
const _salaryFieldInJob =
    RemovalRange(filePath: _jobFile, start: 40, end: 60, fieldKey: 'Job.salary');

void main() {
  test('a class whose fields are all unused and unreferenced is dead', () {
    final dead = resolveDeadClasses(
      classes: [job],
      unusedFieldKeys: {'Job.title', 'Job.salary'},
      classReferences: {'Job': const []},
      fieldRemovals: const [],
    );
    expect(dead.keys.toSet(), {classKey(_jobFile, 'Job')});
  });

  test('a class still named from live code survives', () {
    // e.g. `Future<RootResponse<Job>>` in api_service.dart
    final dead = resolveDeadClasses(
      classes: [job],
      unusedFieldKeys: {'Job.title', 'Job.salary'},
      classReferences: {
        classKey(_jobFile, 'Job'): const [
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
        classKey(_jobFile, 'Job'): const [ClassReference(filePath: _personFile, offset: 45)],
      },
      fieldRemovals: const [_jobFieldInPerson],
    );
    expect(dead.keys.toSet(), {classKey(_jobFile, 'Job')});
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
        classKey(_jobFile, 'Job'): const [ClassReference(filePath: _personFile, offset: 45)],
        // Salary is only named from inside Job, which itself dies.
        classKey(_salaryFile, 'Salary'): const [ClassReference(filePath: _jobFile, offset: 45)],
      },
      fieldRemovals: const [_jobFieldInPerson, _salaryFieldInJob],
    );
    expect(dead.keys.toSet(),
        {classKey(_jobFile, 'Job'), classKey(_salaryFile, 'Salary')});
  });

  test('a live leaf stops the cascade', () {
    // Salary.amount is still used, so Salary lives; Job holds a live Salary,
    // but Job's own fields are all unused and its only mention is going.
    final dead = resolveDeadClasses(
      classes: [person, job, salary],
      unusedFieldKeys: {'Job.title', 'Job.salary'},
      classReferences: {
        classKey(_jobFile, 'Job'): const [ClassReference(filePath: _personFile, offset: 45)],
        classKey(_salaryFile, 'Salary'): const [
          ClassReference(filePath: '/lib/pay_page.dart', offset: 10),
        ],
      },
      fieldRemovals: const [_jobFieldInPerson],
    );
    expect(dead.keys.toSet(), {classKey(_jobFile, 'Job')});
    expect(dead.containsKey(classKey(_salaryFile, 'Salary')), isFalse);
  });

  test('a verdict records the field it depends on', () {
    // `Job` is only dead because `Person.job` is going. If the user ticks
    // `Job` but leaves `Person.job` alone, taking the class would leave that
    // field naming a type that no longer exists — so the condition has to
    // travel with the verdict.
    final dead = resolveDeadClasses(
      classes: [job],
      unusedFieldKeys: {'Job.title', 'Job.salary'},
      classReferences: {
        classKey(_jobFile, 'Job'): const [ClassReference(filePath: _personFile, offset: 45)],
      },
      fieldRemovals: const [_jobFieldInPerson],
    );

    expect(dead.keys.toSet(), {classKey(_jobFile, 'Job')});
    expect(dead[classKey(_jobFile, 'Job')], {'Person.job'});
  });

  test('a cascade inherits the conditions of the class above it', () {
    // Salary dies because Job dies, which dies because Person.job goes. So
    // taking Salary depends on Person.job *and* on Job going with it.
    final dead = resolveDeadClasses(
      classes: [job, salary],
      unusedFieldKeys: {'Job.title', 'Job.salary', 'Salary.amount'},
      classReferences: {
        classKey(_jobFile, 'Job'): const [ClassReference(filePath: _personFile, offset: 45)],
        classKey(_salaryFile, 'Salary'): const [ClassReference(filePath: _jobFile, offset: 45)],
      },
      fieldRemovals: const [_jobFieldInPerson, _salaryFieldInJob],
    );

    expect(dead.keys.toSet(),
        {classKey(_jobFile, 'Job'), classKey(_salaryFile, 'Salary')});
    expect(dead[classKey(_salaryFile, 'Salary')], contains('Job.salary'));
  });

  test('two classes sharing a name are judged separately', () {
    // A models tree routinely has more than one `Gift` — one per endpoint.
    // Keyed by name alone, their references merge and the live one is taken
    // along with the dead one.
    const otherFile = '/models/other/job.dart';
    final otherJob = ModelClass(
      className: 'Job',
      filePath: otherFile,
      line: 0,
      column: 6,
      offset: 0,
      end: 100,
      fieldNames: const ['title', 'salary'],
      fieldTypes: const {},
    );

    final dead = resolveDeadClasses(
      classes: [job, otherJob],
      unusedFieldKeys: {'Job.title', 'Job.salary'},
      classReferences: {
        // The first is only named from a field that is going.
        classKey(_jobFile, 'Job'): const [
          ClassReference(filePath: _personFile, offset: 45),
        ],
        // The second is named from live application code.
        classKey(otherFile, 'Job'): const [
          ClassReference(filePath: '/lib/ui/page.dart', offset: 10),
        ],
      },
      fieldRemovals: const [_jobFieldInPerson],
    );

    expect(dead.keys.toSet(), {classKey(_jobFile, 'Job')});
    expect(
      dead.containsKey(classKey(otherFile, 'Job')),
      isFalse,
      reason: 'the one still named from live code must survive',
    );
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
        classKey(_jobFile, 'Job'): const [ClassReference(filePath: _jobFile, offset: 30)],
      },
      fieldRemovals: const [],
    );
    expect(dead.keys.toSet(), {classKey(_jobFile, 'Job')});
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
