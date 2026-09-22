import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:path/path.dart' as p;

import '../model.dart';

/// Parses every `.dart` file under [modelsPath] and returns the instance
/// fields of each class declared there.
///
/// Static fields are skipped. Each returned [ModelField] carries the
/// zero-based line/column of its name token, which is what the language
/// server needs to resolve references.
Future<List<ModelField>> findModelFields({required String modelsPath}) async =>
    (await findModels(modelsPath: modelsPath)).fields;

/// The `.dart` files named by [modelsPath], which may be a directory to walk
/// or a single file.
///
/// Pointing at one file is useful while narrowing something down — it keeps a
/// scan to seconds on a large project. Note that only that file is indexed, so
/// a subclass elsewhere that forwards a removed field is not seen; the
/// `dart analyze` safety net still catches the result.
List<File> dartFilesAt(String modelsPath) {
  final file = File(modelsPath);
  if (file.existsSync()) {
    if (!modelsPath.endsWith('.dart')) {
      throw NotADartFile(modelsPath);
    }
    return [file];
  }

  final directory = Directory(modelsPath);
  if (!directory.existsSync()) {
    throw ModelsDirectoryNotFound(modelsPath);
  }

  return directory
      .listSync(recursive: true)
      .whereType<File>()
      .where((entry) => entry.path.endsWith('.dart'))
      .toList();
}

/// Everything discovered in the models directory.
class DiscoveredModels {
  final List<ModelField> fields;
  final List<ModelClass> classes;

  /// Classes that were parsed but not treated as API models, by name.
  final List<String> skipped;

  const DiscoveredModels({
    required this.fields,
    required this.classes,
    this.skipped = const [],
  });
}

/// Whether [declaration] looks like a serialized API model.
///
/// The whole premise of this tool is that `fromJson`/`toJson` keep a field
/// alive no matter who reads it, so "nothing references this" means the field
/// is dead weight. That reasoning does not hold for an ordinary class, where
/// the same absence of references can mean the field is written and read
/// through a path the analyzer resolves differently — a mixin, a callback, a
/// subclass in another package. Scanning those produced confident,
/// wrong answers, so a class has to earn its way in.
///
/// A class qualifies by declaring `fromJson` or `toJson`, or by extending one
/// that does within the same file — the alias-subclass shape, where the
/// serialization lives on the base.
Set<String> _modelClassesIn(CompilationUnit unit) {
  final classes = unit.declarations.whereType<ClassDeclaration>().toList();

  bool declaresSerialization(ClassDeclaration declaration) {
    for (final member in declaration.body.members) {
      if (member is MethodDeclaration &&
          (member.name.lexeme == 'toJson' || member.name.lexeme == 'fromJson')) {
        return true;
      }
      // `factory Foo.fromJson(...)` is a constructor, not a method.
      if (member is ConstructorDeclaration &&
          member.name?.lexeme == 'fromJson') {
        return true;
      }
    }
    return false;
  }

  final qualifying = <String>{
    for (final declaration in classes)
      if (declaresSerialization(declaration))
        declaration.namePart.typeName.lexeme,
  };

  // A subclass inherits the marker from a base declared alongside it.
  var growing = true;
  while (growing) {
    growing = false;
    for (final declaration in classes) {
      final superName = declaration.extendsClause?.superclass.name.lexeme;
      if (superName == null || !qualifying.contains(superName)) {
        continue;
      }
      if (qualifying.add(declaration.namePart.typeName.lexeme)) {
        growing = true;
      }
    }
  }

  return qualifying;
}

/// Parses every `.dart` file under [modelsPath], returning both the instance
/// fields and the classes that declare them.
Future<DiscoveredModels> findModels({required String modelsPath}) async {
  final result = <ModelField>[];
  final classes = <ModelClass>[];
  final skipped = <String>[];

  final files = dartFilesAt(modelsPath);

  for (final file in files) {
    final path = file.path;

    final content = await file.readAsString();

    final parseResult = parseString(content: content, path: path);

    final unit = parseResult.unit;
    final models = _modelClassesIn(unit);

    for (final declaration in unit.declarations) {
      if (declaration is! ClassDeclaration) {
        continue;
      }

      final className = declaration.namePart.typeName.lexeme;

      if (!models.contains(className)) {
        skipped.add(className);
        continue;
      }

      final accessors = _publicAccessors(declaration, parseResult.lineInfo);

      final classFieldNames = <String>[];
      final classFieldTypes = <String>{};

      for (final member in declaration.body.members) {
        if (member is! FieldDeclaration) {
          continue;
        }

        // Ignore static fields.
        if (member.isStatic) {
          continue;
        }

        for (final variable in member.fields.variables) {
          final nameNode = variable.name;

          final lineInfo = parseResult.lineInfo;

          final location = lineInfo.getLocation(nameNode.offset);

          classFieldNames.add(nameNode.lexeme);
          final type = member.fields.type;
          if (type != null) {
            classFieldTypes.addAll(_namedTypesIn(type));
          }

          result.add(
            ModelField(
              className: className,
              fieldName: nameNode.lexeme,
              filePath: path,
              line: location.lineNumber - 1,
              column: location.columnNumber - 1,
              accessors: accessors[nameNode.lexeme] ?? const [],
            ),
          );
        }
      }

      final nameToken = declaration.namePart.typeName;
      final nameLocation = parseResult.lineInfo.getLocation(nameToken.offset);

      classes.add(ModelClass(
        className: className,
        filePath: path,
        line: nameLocation.lineNumber - 1,
        column: nameLocation.columnNumber - 1,
        offset: declaration.offset,
        end: declaration.end,
        fieldNames: classFieldNames,
        fieldTypes: classFieldTypes,
      ));
    }
  }

  return DiscoveredModels(
    fields: result,
    classes: classes,
    skipped: skipped,
  );
}

/// Every named type mentioned by a type annotation, including type arguments
/// so `List<Job>` and `Map<String, Job>` both yield `Job`.
Set<String> _namedTypesIn(TypeAnnotation type) {
  final names = <String>{};

  void walk(TypeAnnotation node) {
    if (node is NamedType) {
      names.add(node.name.lexeme);
      for (final argument in node.typeArguments?.arguments ?? const []) {
        walk(argument);
      }
    }
  }

  walk(type);
  return names;
}

/// Members that are serialization plumbing rather than public API. A
/// reference from one of these says nothing about whether the app uses a
/// field.
const _serializationMembers = {
  'toJson',
  'fromJson',
  'copyWith',
  'hashCode',
  '==',
  'toString',
};

/// Maps each field name to the public members that expose it.
///
/// Models that keep state in a private field and publish it through a getter
/// would otherwise look entirely unused: the field itself is only ever touched
/// inside its own file. Any public getter, setter or method that reads the
/// field makes it reachable from outside, so references to *those* count.
Map<String, List<FieldAccessor>> _publicAccessors(
  ClassDeclaration declaration,
  LineInfo lineInfo,
) {
  final result = <String, List<FieldAccessor>>{};

  for (final member in declaration.body.members) {
    if (member is! MethodDeclaration || member.isStatic) {
      continue;
    }

    final name = member.name.lexeme;

    // Private members can't be called from outside, and serialization members
    // reference every field by construction.
    if (name.startsWith('_') || _serializationMembers.contains(name)) {
      continue;
    }

    final referenced = _IdentifierCollector();
    member.body.accept(referenced);

    if (referenced.names.isEmpty) {
      continue;
    }

    final location = lineInfo.getLocation(member.name.offset);
    final accessor = FieldAccessor(
      name: name,
      line: location.lineNumber - 1,
      column: location.columnNumber - 1,
    );

    for (final fieldName in referenced.names) {
      result.putIfAbsent(fieldName, () => []).add(accessor);
    }
  }

  return result;
}

/// Collects every simple identifier appearing in a subtree.
class _IdentifierCollector extends RecursiveAstVisitor<void> {
  final Set<String> names = {};

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    names.add(node.name);
  }
}

/// Whether [reference] points back into the file that declares [field].
///
/// References inside the model's own file are serialization/model internals
/// (`fromJson`, `toJson`, the constructor, `==`, `hashCode`) and must not
/// count as real application usage.
bool isInsideModelFile(Reference reference, ModelField field) {
  return p.normalize(p.absolute(reference.filePath)) ==
      p.normalize(p.absolute(field.filePath));
}

/// One `class Sub extends Super` edge found in the models tree.
class SubclassLink {
  final String className;
  final String superName;

  /// File declaring [className] — not necessarily the one declaring
  /// [superName], which is the whole point of collecting these.
  final String filePath;

  const SubclassLink({
    required this.className,
    required this.superName,
    required this.filePath,
  });

  @override
  String toString() => '$className extends $superName';
}

/// Every `extends` edge between classes under [modelsPath].
///
/// Removing a field from a base class also has to remove the `super.field`
/// parameters that subclasses forward it through, and those subclasses are
/// routinely declared in another file — so the fixer, which sees one
/// compilation unit at a time, cannot find them on its own. This index is
/// what lets the apply runner reach them.
///
/// Edges out of the models tree (`extends Equatable`) are collected too and
/// simply never match a class that is losing fields.
Future<List<SubclassLink>> findSubclassLinks({
  required String modelsPath,
}) async {
  final links = <SubclassLink>[];

  final files = dartFilesAt(modelsPath);

  for (final file in files) {
    final content = await file.readAsString();
    final unit =
        parseString(content: content, path: file.path, throwIfDiagnostics: false)
            .unit;

    for (final declaration in unit.declarations) {
      if (declaration is! ClassDeclaration) {
        continue;
      }
      final superName = declaration.extendsClause?.superclass.name.lexeme;
      if (superName == null) {
        continue;
      }
      links.add(SubclassLink(
        className: declaration.namePart.typeName.lexeme,
        superName: superName,
        filePath: file.path,
      ));
    }
  }

  return links;
}

/// Thrown when the configured models path does not exist.
class ModelsDirectoryNotFound implements Exception {
  final String path;

  ModelsDirectoryNotFound(this.path);

  @override
  String toString() => 'No such directory or file: $path';
}

/// Thrown when the models path names a file that is not Dart source.
class NotADartFile implements Exception {
  final String path;

  NotADartFile(this.path);

  @override
  String toString() => 'Not a Dart file: $path';
}
