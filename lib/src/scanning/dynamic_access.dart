import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:path/path.dart' as p;

/// A member read through a receiver whose static type is `dynamic`.
///
/// `for (final bank in person.banks ?? [])` infers `bank` as `dynamic`, so
/// `bank.minAmount` resolves to nothing: the language server reports no
/// reference to `DepositBank.minAmount`, the field looks unused, and removing
/// it still compiles — the call is only checked when it runs, and then it
/// throws `NoSuchMethodError`. Compilation cannot catch this, so the scan has
/// to.
class DynamicAccess {
  final String name;
  final String filePath;

  /// 1-based, as editors count.
  final int line;
  final int column;

  const DynamicAccess({
    required this.name,
    required this.filePath,
    required this.line,
    required this.column,
  });
}

/// Every `.name` read on a `dynamic` receiver under [projectRoot], for the
/// [names] given.
///
/// Matching is by name alone, because a dynamic receiver is exactly the case
/// where the class cannot be known: `.minAmount` on `dynamic` could be any
/// class's `minAmount`, so every candidate of that name is held back. That
/// keeps some fields that are truly unused, which costs a line of dead code;
/// the alternative costs a crash in production.
///
/// Resolving a whole app is slow, so only files that mention one of [names]
/// after a `.` are resolved at all. With nothing to look for, nothing runs.
///
/// Files the project's `analysis_options.yaml` excludes — generated
/// `*.g.dart`, most often — are skipped, exactly as the analyzer and the
/// reference search skip them. A file that fails to resolve is reported
/// through [onError] and skipped rather than ending the scan.
Future<List<DynamicAccess>> findDynamicAccesses({
  required String projectRoot,
  required Set<String> names,
  void Function(String path, Object error)? onError,
}) async {
  if (names.isEmpty) {
    return const [];
  }

  final root = p.normalize(p.absolute(projectRoot));
  final mention = RegExp(
    r'\.\s*(?:' + names.map(RegExp.escape).join('|') + r')\b',
  );
  final files = [
    for (final file in _dartFiles(root))
      if (mention.hasMatch(file.readAsStringSync())) file.path,
  ];
  if (files.isEmpty) {
    return const [];
  }

  final collection = AnalysisContextCollection(includedPaths: [root]);
  final found = <DynamicAccess>[];
  try {
    for (final path in files) {
      // `contextFor` throws for an excluded file rather than answering, and
      // one such file used to take the whole scan down with it.
      final context = collection.contexts
          .where((c) => c.contextRoot.isAnalyzed(path))
          .firstOrNull;
      if (context == null) {
        continue;
      }
      try {
        final result = await context.currentSession.getResolvedUnit(path);
        if (result is ResolvedUnitResult) {
          result.unit
              .accept(_DynamicReads(names, path, result.lineInfo, found));
        }
      } catch (error) {
        onError?.call(path, error);
      }
    }
  } finally {
    await collection.dispose();
  }
  return found;
}

/// Source files under [root], leaving out tool output and hidden
/// directories, which hold nothing this app runs.
Iterable<File> _dartFiles(String root) sync* {
  final pending = [Directory(root)];
  while (pending.isNotEmpty) {
    final directory = pending.removeLast();
    List<FileSystemEntity> entries;
    try {
      entries = directory.listSync(followLinks: false);
    } on FileSystemException {
      continue;
    }
    for (final entry in entries) {
      final name = p.basename(entry.path);
      if (entry is Directory) {
        if (!name.startsWith('.') && name != 'build') {
          pending.add(entry);
        }
      } else if (entry is File && name.endsWith('.dart')) {
        yield entry;
      }
    }
  }
}

class _DynamicReads extends RecursiveAstVisitor<void> {
  final Set<String> names;
  final String path;
  final LineInfo lines;
  final List<DynamicAccess> found;

  _DynamicReads(this.names, this.path, this.lines, this.found);

  /// `bank.minAmount`
  @override
  void visitPrefixedIdentifier(PrefixedIdentifier node) {
    _check(node.prefix.staticType, node.identifier);
    super.visitPrefixedIdentifier(node);
  }

  /// `banks.first.minAmount`, `(bank).minAmount`, `bank?.minAmount`, and the
  /// `..minAmount` of a cascade, whose real target is the cascade's own.
  @override
  void visitPropertyAccess(PropertyAccess node) {
    _check(node.realTarget.staticType, node.propertyName);
    super.visitPropertyAccess(node);
  }

  /// `bank.onChanged()`, for a field that holds a function.
  @override
  void visitMethodInvocation(MethodInvocation node) {
    final target = node.realTarget;
    if (target != null) {
      _check(target.staticType, node.methodName);
    }
    super.visitMethodInvocation(node);
  }

  void _check(DartType? receiver, SimpleIdentifier member) {
    if (receiver is! DynamicType || !names.contains(member.name)) {
      return;
    }
    final at = lines.getLocation(member.offset);
    found.add(DynamicAccess(
      name: member.name,
      filePath: path,
      line: at.lineNumber,
      column: at.columnNumber,
    ));
  }
}
