import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';

/// AST-aware removal of model fields from a single Dart source file.
///
/// This library is intentionally decoupled from scanning and LSP. It only
/// knows how to take a source string plus a target class and set of field
/// names, and produce a new source string with every trace of those fields
/// removed:
///
///   * the field declaration,
///   * matching constructor parameters (`this.field`) and initializers,
///   * named arguments in `ClassName(...)` invocations (`fromJson`, `copyWith`),
///   * `toJson()` map entries (including `if (field != null) 'key': field`),
///   * `operator ==` comparisons,
///   * `hashCode` participation (`^` chains and `Object.hash(...)`).
///
/// The removal is done by locating precise AST nodes and deleting their exact
/// source ranges, never by regex/string matching, so unrelated formatting and
/// code are left intact.
class ModelFieldFixer {
  /// Removes [fieldNames] belonging to [className] from [content].
  ///
  /// Returns a [FieldFixResult]. When [FieldFixResult.changed] is `false`, the
  /// [FieldFixResult.newContent] equals [content].
  static FieldFixResult removeFields({
    required String content,
    required String path,
    required String className,
    required Set<String> fieldNames,
  }) {
    if (fieldNames.isEmpty) {
      return FieldFixResult(
        changed: false,
        newContent: content,
        className: className,
        removedFields: const {},
        edits: const [],
      );
    }

    final parsed = parseString(content: content, path: path, throwIfDiagnostics: false);
    final unit = parsed.unit;

    ClassDeclaration? target;
    for (final declaration in unit.declarations) {
      if (declaration is ClassDeclaration &&
          declaration.namePart.typeName.lexeme == className) {
        target = declaration;
        break;
      }
    }

    if (target == null) {
      return FieldFixResult(
        changed: false,
        newContent: content,
        className: className,
        removedFields: const {},
        edits: const [],
        error: 'Class $className not found in $path',
      );
    }

    final cuts = <_Cut>[];
    final removed = <String>{};

    _collectFieldDeclarations(target, fieldNames, content, cuts, removed);
    _collectConstructors(target, fieldNames, cuts);
    _collectCopyWith(target, fieldNames, cuts);
    _collectInstanceCreations(target, className, fieldNames, cuts);
    _collectMapEntries(target, fieldNames, cuts);
    _collectEquality(target, fieldNames, cuts);
    _collectHashCode(target, fieldNames, cuts);

    if (cuts.isEmpty) {
      return FieldFixResult(
        changed: false,
        newContent: content,
        className: className,
        removedFields: const {},
        edits: const [],
      );
    }

    final newContent = _applyCuts(content, cuts);

    return FieldFixResult(
      changed: newContent != content,
      newContent: newContent,
      className: className,
      removedFields: removed,
      edits: cuts.map((c) => Edit(c.start, c.end, c.label)).toList(),
    );
  }

  // --- Field declarations -------------------------------------------------

  static void _collectFieldDeclarations(
    ClassDeclaration target,
    Set<String> fieldNames,
    String content,
    List<_Cut> cuts,
    Set<String> removed,
  ) {
    for (final member in target.body.members) {
      if (member is! FieldDeclaration || member.isStatic) {
        continue;
      }

      final variables = member.fields.variables;
      final matching = variables
          .where((v) => fieldNames.contains(v.name.lexeme))
          .toList();

      if (matching.isEmpty) {
        continue;
      }

      for (final v in matching) {
        removed.add(v.name.lexeme);
      }

      if (matching.length == variables.length) {
        // Every declared variable is being removed: drop the whole line.
        cuts.add(_cutWholeLine(member, content, 'field declaration'));
      } else {
        // Only some variables removed: drop each variable individually.
        for (final v in matching) {
          cuts.add(_cutWithComma(v, 'field variable ${v.name.lexeme}'));
        }
      }
    }
  }

  // --- Constructors -------------------------------------------------------

  static void _collectConstructors(
    ClassDeclaration target,
    Set<String> fieldNames,
    List<_Cut> cuts,
  ) {
    for (final member in target.body.members) {
      if (member is! ConstructorDeclaration) {
        continue;
      }

      // Parameters such as `this.field` or a plain named parameter `field`.
      for (final param in member.parameters.parameters) {
        final name = param.name?.lexeme;
        if (name != null && fieldNames.contains(name)) {
          cuts.add(_cutWithComma(param, 'constructor parameter $name'));
        }
      }

      // Initializers such as `field = ...`.
      final initializers = member.initializers;
      final matchingInit = <ConstructorFieldInitializer>[];
      for (final init in initializers) {
        if (init is ConstructorFieldInitializer &&
            fieldNames.contains(init.fieldName.name)) {
          matchingInit.add(init);
        }
      }

      if (matchingInit.isEmpty) {
        continue;
      }

      if (matchingInit.length == initializers.length &&
          member.separator != null) {
        // Removing all initializers: also drop the leading `:`.
        final last = initializers.last;
        cuts.add(_Cut(member.separator!.offset, last.end,
            'constructor initializer list'));
      } else {
        for (final init in matchingInit) {
          cuts.add(_cutWithComma(init, 'constructor initializer ${init.fieldName.name}'));
        }
      }
    }
  }

  // --- copyWith parameters ------------------------------------------------

  /// Removes matching named parameters from a `copyWith` method. The body's
  /// usage (`ClassName(field: field ?? this.field)`) is handled separately by
  /// [_collectInstanceCreations].
  static void _collectCopyWith(
    ClassDeclaration target,
    Set<String> fieldNames,
    List<_Cut> cuts,
  ) {
    for (final member in target.body.members) {
      if (member is! MethodDeclaration || member.name.lexeme != 'copyWith') {
        continue;
      }
      final params = member.parameters?.parameters;
      if (params == null) {
        continue;
      }
      for (final param in params) {
        final name = param.name?.lexeme;
        if (name != null && fieldNames.contains(name)) {
          cuts.add(_cutWithComma(param, 'copyWith parameter $name'));
        }
      }
    }
  }

  // --- `ClassName(...)` invocations (fromJson / copyWith) -----------------

  static void _collectInstanceCreations(
    ClassDeclaration target,
    String className,
    Set<String> fieldNames,
    List<_Cut> cuts,
  ) {
    final visitor = _InstanceCreationVisitor(className, fieldNames, cuts);
    target.accept(visitor);
  }

  // --- toJson map entries -------------------------------------------------

  static void _collectMapEntries(
    ClassDeclaration target,
    Set<String> fieldNames,
    List<_Cut> cuts,
  ) {
    final visitor = _MapEntryVisitor(fieldNames, cuts);
    target.accept(visitor);
  }

  // --- operator == --------------------------------------------------------

  static void _collectEquality(
    ClassDeclaration target,
    Set<String> fieldNames,
    List<_Cut> cuts,
  ) {
    for (final member in target.body.members) {
      if (member is MethodDeclaration &&
          member.isOperator &&
          member.name.lexeme == '==') {
        final visitor = _EqualityVisitor(fieldNames, cuts);
        member.body.accept(visitor);
      }
    }
  }

  // --- hashCode -----------------------------------------------------------

  static void _collectHashCode(
    ClassDeclaration target,
    Set<String> fieldNames,
    List<_Cut> cuts,
  ) {
    for (final member in target.body.members) {
      if (member is MethodDeclaration &&
          !member.isOperator &&
          member.name.lexeme == 'hashCode') {
        final visitor = _HashCodeVisitor(fieldNames, cuts);
        member.body.accept(visitor);
      }
    }
  }

  // --- Range helpers ------------------------------------------------------

  /// Deletes a node that lives in a comma-separated list, swallowing one
  /// adjacent comma (trailing preferred, otherwise leading).
  static _Cut _cutWithComma(AstNode node, String label) {
    var start = node.offset;
    var end = node.end;

    final next = node.endToken.next;
    if (next != null && next.lexeme == ',') {
      end = next.end;
    } else {
      final prev = node.beginToken.previous;
      if (prev != null && prev.lexeme == ',') {
        start = prev.offset;
      }
    }

    return _Cut(start, end, label);
  }

  /// Deletes a node together with its whole source line (leading indentation
  /// and trailing newline), used for standalone field declarations.
  static _Cut _cutWholeLine(AstNode node, String content, String label) {
    var start = node.offset;
    var end = node.end;

    // Swallow leading indentation back to the start of the line.
    var s = start;
    while (s > 0 && (content[s - 1] == ' ' || content[s - 1] == '\t')) {
      s--;
    }
    if (s == 0 || content[s - 1] == '\n') {
      start = s;
    }

    // Swallow trailing spaces and a single newline.
    var e = end;
    while (e < content.length && (content[e] == ' ' || content[e] == '\t')) {
      e++;
    }
    if (e < content.length && content[e] == '\n') {
      e++;
    } else if (e + 1 < content.length && content[e] == '\r' && content[e + 1] == '\n') {
      e += 2;
    }
    end = e;

    return _Cut(start, end, label);
  }

  static String _applyCuts(String content, List<_Cut> cuts) {
    // Merge overlapping/duplicate ranges, then apply from the end so earlier
    // offsets stay valid.
    final sorted = [...cuts]..sort((a, b) => a.start.compareTo(b.start));

    final merged = <_Cut>[];
    for (final cut in sorted) {
      if (cut.end <= cut.start) {
        continue;
      }
      if (merged.isNotEmpty && cut.start <= merged.last.end) {
        final last = merged.removeLast();
        merged.add(_Cut(
          last.start,
          cut.end > last.end ? cut.end : last.end,
          last.label,
        ));
      } else {
        merged.add(cut);
      }
    }

    var result = content;
    for (var i = merged.length - 1; i >= 0; i--) {
      final cut = merged[i];
      result = result.replaceRange(cut.start, cut.end, '');
    }
    return result;
  }
}

/// A single source range to delete, with a human-readable label.
class _Cut {
  final int start;
  final int end;
  final String label;

  _Cut(this.start, this.end, this.label);
}

/// A described edit applied to the source (offsets refer to the original file).
class Edit {
  final int start;
  final int end;
  final String label;

  Edit(this.start, this.end, this.label);

  @override
  String toString() => '$label [$start..$end]';
}

/// Outcome of a field-removal pass on one file.
class FieldFixResult {
  final bool changed;
  final String newContent;
  final String className;
  final Set<String> removedFields;
  final List<Edit> edits;
  final String? error;

  FieldFixResult({
    required this.changed,
    required this.newContent,
    required this.className,
    required this.removedFields,
    required this.edits,
    this.error,
  });
}

// --- Visitors ------------------------------------------------------------

/// Removes named arguments matching a field from `ClassName(...)` calls.
///
/// With an unresolved AST, `ClassName(...)` is parsed as a [MethodInvocation]
/// (the parser can't yet know `ClassName` is a type), while `const ClassName(...)`
/// becomes an [InstanceCreationExpression]. Both shapes are handled.
class _InstanceCreationVisitor extends RecursiveAstVisitor<void> {
  final String className;
  final Set<String> fieldNames;
  final List<_Cut> cuts;

  _InstanceCreationVisitor(this.className, this.fieldNames, this.cuts);

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    if (node.constructorName.type.name.lexeme == className) {
      _strip(node.argumentList);
    }
    super.visitInstanceCreationExpression(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    // `ClassName(...)` with no target is a constructor call in disguise.
    if (node.target == null && node.methodName.name == className) {
      _strip(node.argumentList);
    }
    super.visitMethodInvocation(node);
  }

  void _strip(ArgumentList args) {
    for (final arg in args.arguments) {
      if (arg is NamedArgument && fieldNames.contains(arg.name.lexeme)) {
        cuts.add(ModelFieldFixer._cutWithComma(
          arg,
          'named argument ${arg.name.lexeme}',
        ));
      }
    }
  }
}

/// Removes map entries / collection-if elements that reference a field
/// (covers the common `toJson` shapes).
class _MapEntryVisitor extends RecursiveAstVisitor<void> {
  final Set<String> fieldNames;
  final List<_Cut> cuts;

  _MapEntryVisitor(this.fieldNames, this.cuts);

  @override
  void visitSetOrMapLiteral(SetOrMapLiteral node) {
    for (final element in node.elements) {
      if (_elementReferencesField(element)) {
        cuts.add(ModelFieldFixer._cutWithComma(element, 'map entry'));
      }
    }
    super.visitSetOrMapLiteral(node);
  }

  bool _elementReferencesField(CollectionElement element) {
    final finder = _IdentifierFinder(fieldNames);
    element.accept(finder);
    return finder.found;
  }
}

/// Removes `other.field == field` comparisons from an `&&` chain.
class _EqualityVisitor extends RecursiveAstVisitor<void> {
  final Set<String> fieldNames;
  final List<_Cut> cuts;

  _EqualityVisitor(this.fieldNames, this.cuts);

  @override
  void visitBinaryExpression(BinaryExpression node) {
    if (node.operator.lexeme == '==' && _referencesField(node)) {
      _removeFromChain(node, '&&', 'equality comparison');
      // Do not descend into a comparison we've already scheduled for removal.
      return;
    }
    super.visitBinaryExpression(node);
  }

  bool _referencesField(AstNode node) {
    final finder = _IdentifierFinder(fieldNames);
    node.accept(finder);
    return finder.found;
  }

  void _removeFromChain(Expression node, String joiner, String label) {
    final parent = node.parent;
    if (parent is BinaryExpression && parent.operator.lexeme == joiner) {
      if (identical(parent.rightOperand, node)) {
        cuts.add(_Cut(parent.leftOperand.end, node.end, label));
      } else {
        cuts.add(_Cut(node.offset, parent.rightOperand.offset, label));
      }
    }
    // If not part of a chain, the field is the sole term; leave it so we do
    // not silently produce an empty/invalid expression.
  }
}

/// Removes a field's participation in `hashCode` (`^` chains and
/// `Object.hash(...)` / `Object.hashAll([...])` arguments).
class _HashCodeVisitor extends RecursiveAstVisitor<void> {
  final Set<String> fieldNames;
  final List<_Cut> cuts;

  _HashCodeVisitor(this.fieldNames, this.cuts);

  @override
  void visitPrefixedIdentifier(PrefixedIdentifier node) {
    if (node.identifier.name == 'hashCode' &&
        fieldNames.contains(node.prefix.name)) {
      _removeFromChain(node, '^', 'hashCode term');
      return;
    }
    super.visitPrefixedIdentifier(node);
  }

  @override
  void visitPropertyAccess(PropertyAccess node) {
    final targetIdentifier = node.target;
    if (node.propertyName.name == 'hashCode' &&
        targetIdentifier is SimpleIdentifier &&
        fieldNames.contains(targetIdentifier.name)) {
      _removeFromChain(node, '^', 'hashCode term');
      return;
    }
    super.visitPropertyAccess(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final method = node.methodName.name;
    if (method == 'hash' || method == 'hashAll') {
      for (final arg in node.argumentList.arguments) {
        if (arg is ListLiteral) {
          for (final element in arg.elements) {
            if (element is SimpleIdentifier && fieldNames.contains(element.name)) {
              cuts.add(ModelFieldFixer._cutWithComma(element, 'hashAll element'));
            }
          }
        } else if (arg is SimpleIdentifier && fieldNames.contains(arg.name)) {
          cuts.add(ModelFieldFixer._cutWithComma(arg, 'hash argument'));
        }
      }
    }
    super.visitMethodInvocation(node);
  }

  void _removeFromChain(Expression node, String joiner, String label) {
    final parent = node.parent;
    if (parent is BinaryExpression && parent.operator.lexeme == joiner) {
      if (identical(parent.rightOperand, node)) {
        cuts.add(_Cut(parent.leftOperand.end, node.end, label));
      } else {
        cuts.add(_Cut(node.offset, parent.rightOperand.offset, label));
      }
    }
  }
}

/// Detects whether a subtree references any of the target field names as a
/// value identifier (ignoring the `hashCode` selector name itself).
class _IdentifierFinder extends RecursiveAstVisitor<void> {
  final Set<String> fieldNames;
  bool found = false;

  _IdentifierFinder(this.fieldNames);

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    if (fieldNames.contains(node.name)) {
      found = true;
    }
  }
}
