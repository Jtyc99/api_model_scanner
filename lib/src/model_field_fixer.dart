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

    // Models that store state privately expose it under the public name:
    // `_message` is constructed from a `message` parameter and published by a
    // `message` getter. Parameters and named arguments must match either.
    final publicNames = {
      ...fieldNames,
      for (final name in fieldNames) _publicName(name),
    };

    _collectFieldDeclarations(target, fieldNames, content, cuts, removed);
    _collectConstructors(target, publicNames, cuts);
    _collectCopyWith(target, publicNames, cuts);
    _collectInstanceCreations(target, className, publicNames, cuts);
    _collectAssignments(target, fieldNames, content, cuts);
    _collectAccessorMembers(target, fieldNames, content, cuts);
    _collectMapEntries(target, fieldNames, cuts);
    _collectEquality(target, fieldNames, cuts);
    _collectHashCode(target, fieldNames, content, cuts);
    _collectSubclasses(unit, className, publicNames, cuts);

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
      edits: (cuts.toList()..sort((a, b) => a.start.compareTo(b.start)))
          .map((c) => Edit(
                c.start,
                c.end,
                c.label,
                parsed.lineInfo.getLocation(c.start).lineNumber,
              ))
          .toList(),
    );
  }

  /// Plans the removal of entire classes.
  ///
  /// Used when every field of a class is going and nothing outside the code
  /// being deleted still names the type, so the class has no reason to exist.
  static FieldFixResult removeClasses({
    required String content,
    required String path,
    required Set<String> classNames,
  }) {
    if (classNames.isEmpty) {
      return FieldFixResult(
        changed: false,
        newContent: content,
        className: '',
        removedFields: const {},
        edits: const [],
      );
    }

    final parsed =
        parseString(content: content, path: path, throwIfDiagnostics: false);

    final cuts = <_Cut>[];
    final removed = <String>{};

    for (final declaration in parsed.unit.declarations) {
      if (declaration is! ClassDeclaration) {
        continue;
      }
      final name = declaration.namePart.typeName.lexeme;
      if (!classNames.contains(name)) {
        continue;
      }
      removed.add(name);
      cuts.add(_cutWholeLine(declaration, content, 'class $name'));
    }

    if (cuts.isEmpty) {
      return FieldFixResult(
        changed: false,
        newContent: content,
        className: '',
        removedFields: const {},
        edits: const [],
      );
    }

    final newContent = _applyCuts(content, cuts);

    return FieldFixResult(
      changed: newContent != content,
      newContent: newContent,
      className: removed.join(', '),
      removedFields: removed,
      edits: (cuts.toList()..sort((a, b) => a.start.compareTo(b.start)))
          .map((c) => Edit(
                c.start,
                c.end,
                c.label,
                parsed.lineInfo.getLocation(c.start).lineNumber,
              ))
          .toList(),
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
      _collectParameters(
        member.parameters,
        fieldNames,
        'constructor parameter',
        cuts,
      );

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

  /// Follows the removed field into subclasses that forward it.
  ///
  /// `super.field` is only valid while the superclass constructor still
  /// declares `field`, so emptying the base class without touching its
  /// subclasses leaves `super_formal_parameter_without_associated_named`
  /// behind. Crucially this is a *resolution* error, not a syntax one, so it
  /// parses cleanly — only `dart analyze` sees it. The same applies to an
  /// explicit `super(field: …)` and to calls to the subclass's own
  /// constructor, which lose the named parameter along with the field.
  ///
  /// This handles subclasses declared in the same file as their superclass.
  /// A subclass in another file is reached by [removeSuperForwarding], which
  /// the apply runner drives from a cross-file subclass index.
  static void _collectSubclasses(
    CompilationUnit unit,
    String className,
    Set<String> fieldNames,
    List<_Cut> cuts,
  ) {
    _collectForwarding(unit, {className: fieldNames}, cuts);
  }

  /// Plans the subclass side of a removal for one file.
  ///
  /// [forwarded] maps a superclass name to the fields being removed from it.
  /// Every class in [content] that extends one of those names — directly or
  /// through another subclass — gives up its forwarding constructs. The
  /// superclasses themselves are expected to live elsewhere and are left
  /// alone here; [removeFields] handles a same-file superclass.
  static FieldFixResult removeSuperForwarding({
    required String content,
    required String path,
    required Map<String, Set<String>> forwarded,
  }) {
    if (forwarded.isEmpty) {
      return FieldFixResult(
        changed: false,
        newContent: content,
        className: '',
        removedFields: const {},
        edits: const [],
      );
    }

    final parsed =
        parseString(content: content, path: path, throwIfDiagnostics: false);

    final cuts = <_Cut>[];
    _collectForwarding(parsed.unit, forwarded, cuts);

    if (cuts.isEmpty) {
      return FieldFixResult(
        changed: false,
        newContent: content,
        className: '',
        removedFields: const {},
        edits: const [],
      );
    }

    final newContent = _applyCuts(content, cuts);

    return FieldFixResult(
      changed: newContent != content,
      newContent: newContent,
      className: forwarded.keys.join(', '),
      removedFields: {for (final fields in forwarded.values) ...fields},
      edits: (cuts.toList()..sort((a, b) => a.start.compareTo(b.start)))
          .map((c) => Edit(
                c.start,
                c.end,
                c.label,
                parsed.lineInfo.getLocation(c.start).lineNumber,
              ))
          .toList(),
    );
  }

  /// Cuts forwarding constructs for every subclass of [forwarded] in [unit].
  static void _collectForwarding(
    CompilationUnit unit,
    Map<String, Set<String>> forwarded,
    List<_Cut> cuts,
  ) {
    final classes = unit.declarations.whereType<ClassDeclaration>().toList();

    // A subclass of a subclass forwards the field on again, so widen the map
    // of affected classes until it stops growing.
    final affected = <String, Set<String>>{
      for (final entry in forwarded.entries) entry.key: {...entry.value},
    };
    var growing = true;
    while (growing) {
      growing = false;
      for (final declaration in classes) {
        final superName = declaration.extendsClause?.superclass.name.lexeme;
        if (superName == null) {
          continue;
        }
        final inherited = affected[superName];
        if (inherited == null) {
          continue;
        }
        final name = declaration.namePart.typeName.lexeme;
        final carried = affected.putIfAbsent(name, () => <String>{});
        final before = carried.length;
        carried.addAll(inherited);
        if (carried.length != before) {
          growing = true;
        }
      }
    }

    for (final declaration in classes) {
      final name = declaration.namePart.typeName.lexeme;

      // The classes losing the fields are handled by the caller, not here.
      if (forwarded.containsKey(name)) {
        continue;
      }

      final fieldNames = affected[name];
      if (fieldNames == null || fieldNames.isEmpty) {
        continue;
      }

      _cutForwarding(declaration, name, fieldNames, cuts);
    }
  }

  /// Removes one subclass's forwarding of [fieldNames].
  static void _cutForwarding(
    ClassDeclaration declaration,
    String className,
    Set<String> fieldNames,
    List<_Cut> cuts,
  ) {
    for (final member in declaration.body.members) {
      if (member is! ConstructorDeclaration) {
        continue;
      }

      // Matched on the parameter *kind*: a subclass field that merely shares
      // the name is its own field and must survive.
      _collectParameters(
        member.parameters,
        fieldNames,
        'super parameter',
        cuts,
        where: (p) => p is SuperFormalParameter,
      );

      // `: super(field: …)`
      for (final initializer in member.initializers) {
        if (initializer is! SuperConstructorInvocation) {
          continue;
        }
        for (final argument in initializer.argumentList.arguments) {
          if (argument is NamedArgument &&
              fieldNames.contains(argument.name.lexeme)) {
            cuts.add(_cutWithComma(
              argument,
              'super argument ${argument.name.lexeme}',
            ));
          }
        }
      }
    }

    // `Currency(field: …)` inside the subclass's own factories.
    _collectInstanceCreations(declaration, className, fieldNames, cuts);
  }

  /// Removes matching entries from a parameter list.
  ///
  /// Dart has no empty optional group: `Tabs({})` and `copyWith({})` are
  /// syntax errors. So when every parameter inside `{…}` (or `[…]`) is going,
  /// the delimiters have to go with them.
  static void _collectParameters(
    FormalParameterList parameters,
    Set<String> names,
    String label,
    List<_Cut> cuts, {
    bool Function(FormalParameter)? where,
  }) {
    final all = parameters.parameters;

    bool matches(FormalParameter p) {
      final name = p.name?.lexeme;
      if (name == null || !names.contains(name)) {
        return false;
      }
      return where == null || where(p);
    }

    bool optional(FormalParameter p) => p.isNamed || p.isOptionalPositional;

    final matching = all.where(matches).toList();
    if (matching.isEmpty) {
      return;
    }

    final grouped = all.where(optional).toList();
    final groupedMatching = matching.where(optional).toList();

    if (parameters.leftDelimiter != null &&
        parameters.rightDelimiter != null &&
        grouped.isNotEmpty &&
        groupedMatching.length == grouped.length) {
      // The whole optional group empties out — take the braces as well.
      cuts.add(_Cut(
        parameters.leftDelimiter!.offset,
        parameters.rightDelimiter!.end,
        '$label group',
      ));
      for (final param in matching.where((p) => !optional(p))) {
        cuts.add(_cutWithComma(param, '$label ${param.name!.lexeme}'));
      }
      return;
    }

    for (final param in matching) {
      cuts.add(_cutWithComma(param, '$label ${param.name!.lexeme}'));
    }
  }

  /// The public name a private field is conventionally exposed under.
  static String _publicName(String fieldName) =>
      fieldName.startsWith('_') ? fieldName.substring(1) : fieldName;

  // --- Statements that only move the field around -------------------------

  /// Removes statements whose sole purpose is reading or writing the field.
  ///
  /// Covers the hand-rolled model style where serialization happens in method
  /// bodies rather than literals:
  ///
  /// ```dart
  /// _message = message;              // constructor body
  /// _message = json['message'];      // fromJson body
  /// map['message'] = _message;       // toJson body
  /// if (_cover != null) { … }        // guarded toJson entry
  /// ```
  static void _collectAssignments(
    ClassDeclaration target,
    Set<String> fieldNames,
    String content,
    List<_Cut> cuts,
  ) {
    target.accept(_StatementVisitor(fieldNames, content, cuts));
  }

  // --- Getters and setters over the field ---------------------------------

  /// Removes accessors that exist purely to publish the field.
  ///
  /// Only getters and setters qualify: a regular method that happens to read
  /// the field (`toJson`) is handled elsewhere and must survive.
  static void _collectAccessorMembers(
    ClassDeclaration target,
    Set<String> fieldNames,
    String content,
    List<_Cut> cuts,
  ) {
    for (final member in target.body.members) {
      if (member is! MethodDeclaration) {
        continue;
      }
      if (!member.isGetter && !member.isSetter) {
        continue;
      }
      // `hashCode` is a getter too, but it is a chain we edit rather than drop.
      if (member.name.lexeme == 'hashCode') {
        continue;
      }
      if (_references(member, fieldNames)) {
        cuts.add(_cutWholeLine(member, content, 'accessor ${member.name.lexeme}'));
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
      final params = member.parameters;
      if (params == null) {
        continue;
      }
      _collectParameters(params, fieldNames, 'copyWith parameter', cuts);
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
        _collectChain(
          scope: member.body,
          operator: '&&',
          // `other is Foo` is an operand too, and always survives.
          isRemoved: (operand) =>
              operand is BinaryExpression &&
              operand.operator.lexeme == '==' &&
              _references(operand, fieldNames),
          label: 'equality comparison',
          cuts: cuts,
        );
      }
    }
  }

  /// Removes operands from a left-associative `a op b op c` chain.
  ///
  /// Cutting each operand independently is not safe: the operator between two
  /// operands belongs to both of them, so removing a contiguous *prefix* of
  /// the chain would leave the next operand's operator with nothing on its
  /// left (`=> ^ c.hashCode`). Instead the chain is flattened, removals are
  /// grouped into runs, and each run takes the operators that join it to a
  /// surviving neighbour.
  static void _collectChain({
    required AstNode scope,
    required String operator,
    required bool Function(Expression operand) isRemoved,
    required String label,
    required List<_Cut> cuts,
  }) {
    final finder = _ChainRootFinder(operator);
    scope.accept(finder);

    final root = finder.root;
    if (root == null) {
      return;
    }

    final operands = _flattenChain(root, operator);
    final removed = <int>[
      for (var i = 0; i < operands.length; i++)
        if (isRemoved(operands[i])) i,
    ];

    if (removed.isEmpty) {
      return;
    }

    if (removed.length == operands.length) {
      // Nothing would be left to evaluate. Drop the whole expression and let
      // the caller's verification decide whether the member is still valid.
      cuts.add(_Cut(root.offset, root.end, label));
      return;
    }

    // Group the removed indices into maximal runs of consecutive operands.
    var i = 0;
    while (i < removed.length) {
      var j = i;
      while (j + 1 < removed.length && removed[j + 1] == removed[j] + 1) {
        j++;
      }

      final first = removed[i];
      final last = removed[j];

      if (first == 0) {
        // Head of the chain: take the operators that follow, up to the first
        // survivor, so it becomes the new head cleanly.
        cuts.add(_Cut(operands[first].offset, operands[last + 1].offset, label));
      } else {
        // Otherwise take the operators that precede, back to the previous
        // survivor (runs are maximal, so `first - 1` always survives).
        cuts.add(_Cut(operands[first - 1].end, operands[last].end, label));
      }

      i = j + 1;
    }
  }

  /// Flattens `((a op b) op c)` into `[a, b, c]`.
  static List<Expression> _flattenChain(Expression node, String operator) {
    if (node is BinaryExpression && node.operator.lexeme == operator) {
      return [
        ..._flattenChain(node.leftOperand, operator),
        node.rightOperand,
      ];
    }
    return [node];
  }

  static bool _references(AstNode node, Set<String> fieldNames) {
    final finder = _IdentifierFinder(fieldNames);
    node.accept(finder);
    return finder.found;
  }

  /// Whether [operand] is `someField.hashCode` for one of [fieldNames].
  static bool _isHashCodeOf(Expression operand, Set<String> fieldNames) {
    if (operand is PrefixedIdentifier) {
      return operand.identifier.name == 'hashCode' &&
          fieldNames.contains(operand.prefix.name);
    }
    if (operand is PropertyAccess) {
      final target = operand.target;
      return operand.propertyName.name == 'hashCode' &&
          target is SimpleIdentifier &&
          fieldNames.contains(target.name);
    }
    return false;
  }

  // --- hashCode -----------------------------------------------------------

  static void _collectHashCode(
    ClassDeclaration target,
    Set<String> fieldNames,
    String content,
    List<_Cut> cuts,
  ) {
    for (final member in target.body.members) {
      if (member is! MethodDeclaration ||
          member.isOperator ||
          member.name.lexeme != 'hashCode') {
        continue;
      }

      // If every term is going, there is nothing left to hash. Emptying the
      // expression would leave `=> ;`, and neutralising the only term would
      // leave `=> /*tabs.hashCode*/;` — both are syntax errors. The getter
      // itself has to go.
      final expression = _bodyExpression(member.body);
      if (expression != null) {
        final operands = _flattenChain(expression, '^');
        if (operands.every((o) => _isHashCodeOf(o, fieldNames))) {
          cuts.add(_cutWholeLine(member, content, 'hashCode getter'));
          continue;
        }
      }

      _collectChain(
        scope: member.body,
        operator: '^',
        isRemoved: (operand) => _isHashCodeOf(operand, fieldNames),
        label: 'hashCode term',
        cuts: cuts,
      );
      // `Object.hash(a, b)` is a comma list, not a chain.
      member.body.accept(_HashArgumentVisitor(fieldNames, cuts));
    }
  }

  /// The single expression a body evaluates to, for `=> e;` and
  /// `{ return e; }` alike. Null for anything more involved.
  static Expression? _bodyExpression(FunctionBody body) {
    if (body is ExpressionFunctionBody) {
      return body.expression;
    }
    if (body is BlockFunctionBody) {
      final statements = body.block.statements;
      if (statements.length == 1) {
        final only = statements.single;
        if (only is ReturnStatement) {
          return only.expression;
        }
      }
    }
    return null;
  }

  /// Applies an arbitrary subset of [edits] to [content].
  ///
  /// This is what lets the CLI act on only the parts a user ticked, rather
  /// than always removing a whole field. In [EditMode.comment] each range is
  /// trimmed of surrounding whitespace and wrapped in `/* */`; Dart block
  /// comments nest, so ranges that already contain a comment stay valid.
  static String applyEdits(
    String content,
    List<Edit> edits,
    EditMode mode,
  ) =>
      applyEditsDetailed(content, edits, mode).content;

  /// As [applyEdits], but also reports each range that was commented out, so
  /// callers can record enough to undo it later.
  static AppliedEdits applyEditsDetailed(
    String content,
    List<Edit> edits,
    EditMode mode,
  ) {
    if (edits.isEmpty) {
      return AppliedEdits(content: content, commented: const []);
    }

    final cuts = edits
        .map((e) => _Cut(e.start, e.end, e.label))
        .toList();

    if (mode == EditMode.delete) {
      return AppliedEdits(
        content: _applyCuts(content, cuts),
        commented: const [],
      );
    }

    final merged = _merge(cuts);
    final commented = <CommentedRange>[];

    var result = content;
    for (var i = merged.length - 1; i >= 0; i--) {
      final trimmed = _trimRange(content, merged[i]);
      if (trimmed == null) {
        continue;
      }
      final text = content.substring(trimmed.start, trimmed.end);
      commented.add(
        CommentedRange(start: trimmed.start, end: trimmed.end, text: text),
      );
      result = result.replaceRange(trimmed.start, trimmed.end, '/*$text*/');
    }

    return AppliedEdits(
      content: result,
      commented: commented.reversed.toList(),
    );
  }

  /// Narrows a cut to the non-whitespace text inside it, so a commented range
  /// does not swallow indentation or the trailing newline.
  static _Cut? _trimRange(String content, _Cut cut) {
    var start = cut.start;
    var end = cut.end;

    bool isSpace(int i) =>
        content[i] == ' ' ||
        content[i] == '\t' ||
        content[i] == '\n' ||
        content[i] == '\r';

    while (start < end && isSpace(start)) {
      start++;
    }
    while (end > start && isSpace(end - 1)) {
      end--;
    }

    return end > start ? _Cut(start, end, cut.label) : null;
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

  /// Sorts cuts and coalesces any that overlap or touch.
  static List<_Cut> _merge(List<_Cut> cuts) {
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
    return merged;
  }

  /// Grows a cut to cover its whole line when nothing else remains on it.
  ///
  /// Without this, deleting one item from a multi-line list (a single `toJson`
  /// entry, say) leaves the indentation and newline behind as a blank line.
  static _Cut _expandToWholeLine(String content, _Cut cut) {
    var start = cut.start;
    var end = cut.end;

    bool blank(int i) => content[i] == ' ' || content[i] == '\t';

    // Everything before the cut on this line must be whitespace.
    var s = start;
    while (s > 0 && blank(s - 1)) {
      s--;
    }
    if (s != 0 && content[s - 1] != '\n') {
      return cut;
    }

    // Everything after the cut on this line must be whitespace too.
    var e = end;
    while (e < content.length && blank(e)) {
      e++;
    }
    if (e < content.length && content[e] == '\r') {
      e++;
    }
    if (e < content.length && content[e] != '\n') {
      return cut;
    }
    if (e < content.length) {
      e++; // consume the newline
    }

    return _Cut(s, e, cut.label);
  }

  static String _applyCuts(String content, List<_Cut> cuts) {
    // Apply from the end so earlier offsets stay valid. Expanding to whole
    // lines can create fresh overlaps, so merge once more afterwards.
    final merged = _merge([
      for (final cut in _merge(cuts)) _expandToWholeLine(content, cut),
    ]);

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

/// A source range that was wrapped in a block comment, together with the exact
/// text inside it — which is what makes the change reversible.
class CommentedRange {
  final int start;
  final int end;
  final String text;

  const CommentedRange({
    required this.start,
    required this.end,
    required this.text,
  });
}

/// The result of applying edits to a source file.
class AppliedEdits {
  final String content;
  final List<CommentedRange> commented;

  const AppliedEdits({required this.content, required this.commented});
}

/// How a selected source range should be neutralised.
enum EditMode {
  /// Delete the range outright.
  delete,

  /// Wrap the range in a block comment, leaving the code readable in place.
  comment,
}

/// A described edit applied to the source (offsets refer to the original file).
class Edit {
  final int start;
  final int end;
  final String label;

  /// One-based line in the original file where this edit begins.
  final int line;

  Edit(this.start, this.end, this.label, this.line);

  @override
  String toString() => '$label (line $line)';
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
/// Removes whole statements that exist only to read or write the field.
class _StatementVisitor extends RecursiveAstVisitor<void> {
  final Set<String> fieldNames;
  final String content;
  final List<_Cut> cuts;

  _StatementVisitor(this.fieldNames, this.content, this.cuts);

  bool _touches(AstNode node) =>
      ModelFieldFixer._references(node, fieldNames);

  @override
  void visitExpressionStatement(ExpressionStatement node) {
    // `_x = …;` and `map['x'] = _x;` both disappear with the field.
    if (node.expression is AssignmentExpression && _touches(node)) {
      cuts.add(ModelFieldFixer._cutWholeLine(node, content, 'assignment'));
      return;
    }
    super.visitExpressionStatement(node);
  }

  @override
  void visitIfStatement(IfStatement node) {
    // A guard like `if (_cover != null) { map[…] = _cover; }` goes whole:
    // removing only the inner statement would leave the condition behind,
    // still naming a field that no longer exists.
    if (_touches(node.expression)) {
      cuts.add(ModelFieldFixer._cutWholeLine(node, content, 'guarded entry'));
      return;
    }
    super.visitIfStatement(node);
  }
}

/// Finds the outermost binary expression using [operator] within a subtree,
/// without descending into it.
class _ChainRootFinder extends RecursiveAstVisitor<void> {
  final String operator;
  BinaryExpression? root;

  _ChainRootFinder(this.operator);

  @override
  void visitBinaryExpression(BinaryExpression node) {
    if (root != null) {
      return;
    }
    if (node.operator.lexeme == operator) {
      root = node;
      return; // the whole chain hangs off this node
    }
    super.visitBinaryExpression(node);
  }
}

/// Removes `Object.hash(...)` / `Object.hashAll([...])` arguments, which are a
/// plain comma list rather than an operator chain.
class _HashArgumentVisitor extends RecursiveAstVisitor<void> {
  final Set<String> fieldNames;
  final List<_Cut> cuts;

  _HashArgumentVisitor(this.fieldNames, this.cuts);

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final method = node.methodName.name;
    if (method == 'hash' || method == 'hashAll') {
      for (final arg in node.argumentList.arguments) {
        if (arg is ListLiteral) {
          for (final element in arg.elements) {
            if (element is SimpleIdentifier &&
                fieldNames.contains(element.name)) {
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
