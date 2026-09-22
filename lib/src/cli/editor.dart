import 'dart:io';

import 'gui.dart';

/// Opens [path] in the user's editor.
///
/// Prefers the VS Code CLI (which reuses the already-open window), then
/// `$EDITOR`, then the platform's default handler. Returns the command that
/// succeeded, or null if the file could not be opened — failing to open is
/// never fatal, since the path is always printed too.
String? openInEditor(String path) {
  for (final command in editorCandidates(path)) {
    if (!_exists(command.first)) {
      continue;
    }
    try {
      final result = Process.runSync(
        command.first,
        command.sublist(1),
        runInShell: Platform.isWindows,
      );
      if (result.exitCode == 0) {
        return command.first;
      }
    } catch (_) {
      // Try the next candidate.
    }
  }

  return null;
}

/// The commands to try, in order, to open [path].
///
/// Pure so the ordering can be tested without launching anything. [editor] is
/// the configured editor command — the chosen one comes first because it
/// reuses an already-open window instead of starting a second copy, which is
/// exactly what a fork user loses when this is hardcoded to `code`.
List<List<String>> editorCandidates(
  String path, {
  String? editor,
  Map<String, String>? environment,
}) {
  final chosen = editor ?? resolvedEditor();
  final env = environment ?? Platform.environment;

  return <List<String>>[
    [chosen, '--reuse-window', path],
    if (env['EDITOR'] case final fallback? when fallback.trim().isNotEmpty)
      [fallback.trim(), path],
    if (Platform.isMacOS) ['open', path],
    if (Platform.isLinux) ['xdg-open', path],
    if (Platform.isWindows) ['cmd', '/c', 'start', '', path],
  ];
}

/// Whether [executable] is resolvable on PATH.
bool _exists(String executable) {
  // Shell builtins used via `cmd /c` are always available.
  if (executable == 'cmd') {
    return Platform.isWindows;
  }
  try {
    final which = Platform.isWindows ? 'where' : 'which';
    final result = Process.runSync(which, [executable]);
    return result.exitCode == 0;
  } catch (_) {
    return false;
  }
}
