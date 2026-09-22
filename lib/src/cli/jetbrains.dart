import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

/// Directory name of the plugin, inside an IDE's `plugins` folder.
const String intellijPluginName = 'amscan-report-intellij';

/// An installed JetBrains IDE, identified by the settings directory it keeps.
///
/// Found by its configuration rather than by the application bundle, because
/// the configuration is what a plugin is installed into — and a machine can
/// hold several versions at once, each with its own plugins.
class JetBrainsIde {
  /// As a person would say it: `Android Studio 2025.3.4`.
  final String name;

  /// `~/Library/Application Support/Google/AndroidStudio2025.3.4`.
  final String configDirectory;

  const JetBrainsIde(this.name, this.configDirectory);

  String get pluginsDirectory => p.join(configDirectory, 'plugins');

  bool get hasPlugin =>
      Directory(p.join(pluginsDirectory, intellijPluginName)).existsSync();

  // Compared by the directory, so two handles on the same installation are
  // the same installation. Without this, checking a found IDE against the
  // newest one — a different instance of the same thing — silently never
  // matches, and code that reads correctly does nothing at all.
  @override
  bool operator ==(Object other) =>
      other is JetBrainsIde && other.configDirectory == configDirectory;

  @override
  int get hashCode => configDirectory.hashCode;

  @override
  String toString() => '$name ($configDirectory)';
}

/// Where JetBrains IDEs keep per-version configuration on [os].
///
/// [home] and [os] are passed rather than read so this can be checked for
/// every platform from any one of them.
List<String> jetBrainsConfigRoots({required String home, required String os}) =>
    switch (os) {
      'macos' => [
          p.join(home, 'Library', 'Application Support', 'Google'),
          p.join(home, 'Library', 'Application Support', 'JetBrains'),
        ],
      'windows' => [
          p.join(home, 'AppData', 'Roaming', 'Google'),
          p.join(home, 'AppData', 'Roaming', 'JetBrains'),
        ],
      _ => [
          p.join(home, '.config', 'Google'),
          p.join(home, '.config', 'JetBrains'),
        ],
    };

/// The roots for the machine this is running on.
List<String> currentConfigRoots() {
  final home = Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'] ??
      '';
  if (home.isEmpty) {
    return const [];
  }
  return jetBrainsConfigRoots(
    home: home,
    os: Platform.isMacOS
        ? 'macos'
        : Platform.isWindows
            ? 'windows'
            : 'linux',
  );
}

final RegExp _androidStudio = RegExp(r'^AndroidStudio(.+)$');

/// Every Android Studio installation found under [roots].
///
/// Only Android Studio: the other JetBrains IDEs would load this plugin
/// perfectly well, but offering to install into an IDE the user has not
/// mentioned is not what they asked for.
List<JetBrainsIde> findJetBrainsIdes({required List<String> roots}) {
  final found = <JetBrainsIde>[];

  for (final root in roots) {
    final directory = Directory(root);
    if (!directory.existsSync()) {
      continue;
    }
    for (final entry in directory.listSync().whereType<Directory>()) {
      final match = _androidStudio.firstMatch(p.basename(entry.path));
      if (match == null) {
        continue;
      }
      found.add(JetBrainsIde('Android Studio ${match.group(1)}', entry.path));
    }
  }

  return found;
}

/// The newest of [ides].
JetBrainsIde? newestJetBrainsIde(List<JetBrainsIde> ides) =>
    ides.isEmpty ? null : orderedByVersion(ides).first;

/// [ides] newest first, compared version part by version part.
///
/// String order would put `2025.1.1` after `2025.3.4`, which is how you end
/// up installing into last year's IDE.
List<JetBrainsIde> orderedByVersion(List<JetBrainsIde> ides) {
  List<int> parts(JetBrainsIde ide) => [
        for (final piece in p.basename(ide.configDirectory).split('.'))
          int.tryParse(piece.replaceAll(RegExp(r'\D'), '')) ?? 0,
      ];

  final sorted = [...ides]..sort((a, b) {
      final left = parts(a);
      final right = parts(b);
      for (var i = 0; i < left.length && i < right.length; i++) {
        final byPart = right[i].compareTo(left[i]);
        if (byPart != 0) {
          return byPart;
        }
      }
      return right.length.compareTo(left.length);
    });

  return sorted;
}

/// Copies the plugin into [ide], replacing any copy already there.
///
/// A JetBrains IDE has no supported way to install a plugin from a local file
/// on the command line, so this does what the IDE itself would: put the
/// unpacked plugin in `plugins` and let it be found at startup. The old copy
/// is deleted first so a jar dropped from a later version cannot linger.
void installIntellijPlugin({
  required JetBrainsIde ide,
  required String source,
}) {
  final target = Directory(p.join(ide.pluginsDirectory, intellijPluginName));
  if (target.existsSync()) {
    target.deleteSync(recursive: true);
  }
  _copyInto(Directory(source), target);
}

/// Removes the plugin from [ide]. False when it was not installed.
bool removeIntellijPlugin(JetBrainsIde ide) {
  final target = Directory(p.join(ide.pluginsDirectory, intellijPluginName));
  if (!target.existsSync()) {
    return false;
  }
  target.deleteSync(recursive: true);
  return true;
}

void _copyInto(Directory source, Directory target) {
  target.createSync(recursive: true);
  for (final entry in source.listSync()) {
    final name = p.basename(entry.path);
    if (entry is Directory) {
      _copyInto(entry, Directory(p.join(target.path, name)));
    } else if (entry is File) {
      entry.copySync(p.join(target.path, name));
    }
  }
}

/// The plugin archive shipped inside this package, if it is still there.
///
/// Kept beside the unpacked copy because the two serve different installs:
/// copying the directory in is what `gui install` does, and the IDE only
/// notices that at startup. Handing this `.zip` to the IDE's own
/// "Install Plugin from Disk" goes through its plugin machinery instead,
/// which loads the plugin straight away — every extension point it uses is
/// declared `dynamic`, so nothing forces a restart.
String? bundledIntellijZip() {
  final root = _packageRoot();
  if (root == null) {
    return null;
  }
  final directory = Directory(p.join(root, 'editors', 'intellij'));
  if (!directory.existsSync()) {
    return null;
  }
  final archives = directory
      .listSync()
      .whereType<File>()
      .where((file) => file.path.endsWith('.zip'))
      .toList()
    ..sort((a, b) => b.path.compareTo(a.path));
  return archives.isEmpty ? null : archives.first.path;
}

/// The plugin shipped inside this package, if it is still there.
///
/// Resolved through a `package:` URI for the same reason as the `.vsix`:
/// `Platform.script` points at a snapshot in another tree once the package
/// has been globally activated.
String? bundledIntellijPlugin() {
  final root = _packageRoot();
  if (root == null) {
    return null;
  }
  final directory = Directory(
    p.join(root, 'editors', 'intellij', 'plugin', intellijPluginName),
  );
  return directory.existsSync() ? directory.path : null;
}

String? _packageRoot() {
  try {
    final config = Isolate.packageConfigSync;
    if (config == null) {
      return null;
    }
    final file = File.fromUri(config);
    if (!file.existsSync()) {
      return null;
    }
    final text = file.readAsStringSync();
    final pattern = RegExp(
      '"name"\\s*:\\s*"api_model_scanner"\\s*,\\s*"rootUri"\\s*:\\s*"([^"]+)"',
    );
    final match = pattern.firstMatch(text);
    if (match == null) {
      return null;
    }
    final uri = Uri.parse(match.group(1)!);
    return uri.scheme == 'file'
        ? File.fromUri(uri).path
        : p.normalize(p.join(p.dirname(config.toFilePath()), match.group(1)!));
  } catch (_) {
    return null;
  }
}

/// Where Android Studio's own launcher lives, or null when it cannot be found.
///
/// Its `--help` documents `[--line <line>] [--column <column>] file`, so it
/// can open the report and land on a line — but it is not on PATH by default,
/// which is why the application bundle is checked too.
String? androidStudioLauncher() {
  final onPath = _which('studio');
  if (onPath != null) {
    return onPath;
  }

  const candidates = [
    '/Applications/Android Studio.app/Contents/MacOS/studio',
    '/Applications/Android Studio Preview.app/Contents/MacOS/studio',
  ];
  for (final candidate in candidates) {
    if (File(candidate).existsSync()) {
      return candidate;
    }
  }

  final home = Platform.environment['HOME'];
  if (home != null) {
    final local = p.join(
      home, 'Applications', 'Android Studio.app', 'Contents', 'MacOS', 'studio',
    );
    if (File(local).existsSync()) {
      return local;
    }
  }

  return null;
}

String? _which(String executable) {
  try {
    final result = Process.runSync(
      Platform.isWindows ? 'where' : 'which',
      [executable],
    );
    if (result.exitCode != 0) {
      return null;
    }
    final first = '${result.stdout}'.split('\n').first.trim();
    return first.isEmpty ? null : first;
  } catch (_) {
    return null;
  }
}

/// Whether this IDE appears to be running right now.
///
/// Only a hint, and deliberately cheap: it decides whether to mention the
/// no-restart route, nothing more. A wrong answer costs one extra line of
/// advice.
extension JetBrainsIdeRunning on JetBrainsIde {
  bool get isRunning {
    if (!Platform.isMacOS) {
      return false;
    }
    try {
      final result = Process.runSync('pgrep', ['-f', 'Android Studio.app']);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }
}
