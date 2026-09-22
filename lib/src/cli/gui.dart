import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import 'config.dart';

/// Identifier of the VS Code editor that renders reports as a table.
const String extensionId = 'jtycedgetech.amscan-report';

/// How an install was satisfied, so the caller can say what happened.
enum GuiSource {
  /// Installed from the VS Code Marketplace by identifier.
  marketplace,

  /// Installed from the `.vsix` shipped inside this package.
  bundled,
}

/// Why an install could not proceed.
enum GuiProblem {
  /// The `code` command is not on PATH.
  noCodeCli,

  /// Neither the Marketplace nor a bundled `.vsix` worked.
  unavailable,
}

class GuiResult {
  final GuiSource? source;
  final GuiProblem? problem;

  /// Whatever `code` printed, for a message that says something useful.
  final String detail;

  const GuiResult.installed(this.source, [this.detail = ''])
      : problem = null;
  const GuiResult.failed(this.problem, [this.detail = ''])
      : source = null;

  bool get ok => problem == null;
}

/// Editor commands that can install a `.vsix`, in preference order.
///
/// The VS Code forks keep the same extension CLI, so the same install works
/// on all of them. They use OpenVSX rather than the VS Code Marketplace, so
/// the by-id install fails there and the bundled `.vsix` is what actually
/// lands — the same fallback that makes an unpublished extension installable
/// at all.
const List<String> knownEditors = [
  'code',
  'cursor',
  'windsurf',
  'code-insiders',
];

/// The editors from [knownEditors] present on this machine.
///
/// [isAvailable] exists so the ordering can be tested without depending on
/// what happens to be installed.
List<String> detectEditors({bool Function(String command)? isAvailable}) {
  final probe = isAvailable ?? _onPath;
  return [
    for (final command in knownEditors)
      if (probe(command)) command,
  ];
}

/// The editor command to drive.
///
/// The configured choice wins; otherwise the first one actually installed,
/// so a machine with only a fork still works without being configured. Falls
/// back to `code` so the messages name something concrete when nothing at
/// all is present.
String resolvedEditor() {
  final configured = ModelsConfig.readEditor();
  if (configured != null) {
    return configured;
  }
  final detected = detectEditors();
  return detected.isEmpty ? 'code' : detected.first;
}

/// The editor commands to offer as a choice, given what [detected] found.
///
/// Falling back to every known editor keeps the question answerable on a
/// machine where none is on PATH yet: the choice is recorded now, and
/// `gui install` says plainly if it cannot act on it.
List<String> editorChoices(List<String> detected) =>
    detected.isEmpty ? knownEditors : detected;

/// Whether [command] answers `--version`.
bool _onPath(String command) => _run(command, ['--version']) != null;

/// Whether the `code` command is available.
///
/// VS Code ships it but does not always put it on PATH — on macOS it is added
/// from the command palette, which is worth saying rather than just failing.
bool codeCliAvailable({String? editor}) =>
    _run(editor ?? resolvedEditor(), ['--version']) != null;

/// Whether the editor is currently installed.
bool guiInstalled({String? editor}) {
  final listed = _run(editor ?? resolvedEditor(), ['--list-extensions']);
  if (listed == null) {
    return false;
  }
  return listed.toLowerCase().contains(extensionId.toLowerCase());
}

/// Installs the editor, preferring the Marketplace and falling back to the
/// copy shipped with this package.
///
/// The Marketplace comes first because it keeps itself updated and works even
/// when this package was installed some way that left no `.vsix` behind. The
/// bundled copy is what makes the install work offline, and before the
/// extension is published at all.
GuiResult installGui({String? editor}) {
  final command = editor ?? resolvedEditor();

  if (!codeCliAvailable(editor: command)) {
    return const GuiResult.failed(GuiProblem.noCodeCli);
  }

  final fromMarketplace =
      _run(command, ['--install-extension', extensionId, '--force']);
  if (fromMarketplace != null && !_looksLikeFailure(fromMarketplace)) {
    return GuiResult.installed(GuiSource.marketplace, fromMarketplace.trim());
  }

  final bundled = bundledVsix();
  if (bundled != null) {
    final fromFile =
        _run(command, ['--install-extension', bundled, '--force']);
    if (fromFile != null && !_looksLikeFailure(fromFile)) {
      return GuiResult.installed(GuiSource.bundled, fromFile.trim());
    }
    return GuiResult.failed(GuiProblem.unavailable, fromFile?.trim() ?? '');
  }

  return GuiResult.failed(
    GuiProblem.unavailable,
    fromMarketplace?.trim() ?? '',
  );
}

/// Removes the editor. Returns false when `code` is unavailable or refused.
bool uninstallGui({String? editor}) {
  final command = editor ?? resolvedEditor();

  if (!codeCliAvailable(editor: command)) {
    return false;
  }
  final output = _run(command, ['--uninstall-extension', extensionId]);
  return output != null && !_looksLikeFailure(output);
}

/// The `.vsix` shipped inside this package, if it is still there.
///
/// Found by resolving a `package:` URI rather than from [Platform.script],
/// which points at a snapshot in a different tree once the package has been
/// activated globally.
String? bundledVsix() {
  final root = _packageRoot();
  if (root == null) {
    return null;
  }

  final directory = Directory(p.join(root, 'editors', 'vscode'));
  if (!directory.existsSync()) {
    return null;
  }

  final candidates = directory
      .listSync()
      .whereType<File>()
      .where((file) => file.path.endsWith('.vsix'))
      .toList()
    ..sort((a, b) => b.path.compareTo(a.path));

  return candidates.isEmpty ? null : candidates.first.path;
}

String? _packageRoot() {
  try {
    // `Isolate.resolvePackageUriSync` is not available, and the async form
    // cannot be awaited here; resolve through the package config instead.
    final uri = _resolveSync('package:api_model_scanner/api_model_scanner.dart');
    if (uri == null) {
      return null;
    }
    // .../<package>/lib/api_model_scanner.dart -> .../<package>
    return File.fromUri(uri).parent.parent.path;
  } catch (_) {
    return null;
  }
}

/// Resolves a `package:` URI without awaiting, by reading the package config
/// the running isolate was started with.
Uri? _resolveSync(String packageUri) {
  final config = Isolate.packageConfigSync;
  if (config == null) {
    return null;
  }

  final file = File.fromUri(config);
  if (!file.existsSync()) {
    return null;
  }

  // Minimal read of package_config.json: enough to find one package's root.
  final text = file.readAsStringSync();
  final name = Uri.parse(packageUri).pathSegments.first;
  final pattern = RegExp(
    '"name"\\s*:\\s*"$name"\\s*,\\s*"rootUri"\\s*:\\s*"([^"]+)"'
    '\\s*,\\s*"packageUri"\\s*:\\s*"([^"]+)"',
  );
  final match = pattern.firstMatch(text);
  if (match == null) {
    return null;
  }

  final root = config.resolve(match.group(1)!);
  final lib = root.resolve(match.group(2)!);
  return lib.resolve(Uri.parse(packageUri).pathSegments.skip(1).join('/'));
}

/// `code` treats some failures as a zero exit with a message, so the output
/// has to be read rather than trusting the exit code alone.
bool _looksLikeFailure(String output) {
  final lower = output.toLowerCase();
  return lower.contains("can't be found") ||
      lower.contains('not found') ||
      lower.contains('failed') ||
      lower.contains('unable to install');
}

String? _run(String command, List<String> arguments) {
  try {
    final result = Process.runSync(
      command,
      arguments,
      runInShell: Platform.isWindows,
    );
    if (result.exitCode != 0) {
      return null;
    }
    return '${result.stdout}${result.stderr}';
  } catch (_) {
    return null;
  }
}
