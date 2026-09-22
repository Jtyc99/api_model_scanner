import 'dart:io';

import 'gui.dart';
import 'jetbrains.dart';
import 'targets.dart';

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
  HostIde? host,
  String? Function()? locateStudio,
}) {
  final chosen = editor ?? resolvedEditor();
  final env = environment ?? Platform.environment;
  final inIde = host ?? currentHostIde();
  final studioAt = inIde == HostIde.jetBrains
      ? (locateStudio ?? androidStudioLauncher)()
      : null;

  return <List<String>>[
    // The terminal you ran from decides where the report opens: running in
    // Android Studio and having it appear in VS Code is nobody's intent.
    // It takes the file as a bare argument — `--reuse-window` is a VS Code
    // flag it does not understand.
    if (studioAt != null) [studioAt, path],
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
