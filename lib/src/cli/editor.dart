import 'dart:io';

/// Opens [path] in the user's editor.
///
/// Prefers the VS Code CLI (which reuses the already-open window), then
/// `$EDITOR`, then the platform's default handler. Returns the command that
/// succeeded, or null if the file could not be opened — failing to open is
/// never fatal, since the path is always printed too.
String? openInEditor(String path) {
  final candidates = <List<String>>[
    ['code', '--reuse-window', path],
    if (Platform.environment['EDITOR'] case final editor?
        when editor.trim().isNotEmpty)
      [editor.trim(), path],
    if (Platform.isMacOS) ['open', path],
    if (Platform.isLinux) ['xdg-open', path],
    if (Platform.isWindows) ['cmd', '/c', 'start', '', path],
  ];

  for (final command in candidates) {
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
