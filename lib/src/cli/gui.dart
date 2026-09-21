import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

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

/// Whether the `code` command is available.
///
/// VS Code ships it but does not always put it on PATH — on macOS it is added
/// from the command palette, which is worth saying rather than just failing.
bool codeCliAvailable() => _run(['--version']) != null;

/// Whether the editor is currently installed.
bool guiInstalled() {
  final listed = _run(['--list-extensions']);
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
GuiResult installGui() {
  if (!codeCliAvailable()) {
    return const GuiResult.failed(GuiProblem.noCodeCli);
  }

  final fromMarketplace = _run(['--install-extension', extensionId, '--force']);
  if (fromMarketplace != null && !_looksLikeFailure(fromMarketplace)) {
    return GuiResult.installed(GuiSource.marketplace, fromMarketplace.trim());
  }

  final bundled = bundledVsix();
  if (bundled != null) {
    final fromFile = _run(['--install-extension', bundled, '--force']);
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
bool uninstallGui() {
  if (!codeCliAvailable()) {
    return false;
  }
  final output = _run(['--uninstall-extension', extensionId]);
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

String? _run(List<String> arguments) {
  try {
    final result = Process.runSync(
      'code',
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
