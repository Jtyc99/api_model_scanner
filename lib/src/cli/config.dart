import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Where a configured models directory came from.
enum ModelsSource {
  /// Passed explicitly as `--models`.
  flag,

  /// `.dart_tool/api_model_scanner/config.json` in this project.
  project,

  /// The machine-wide default written by `init`.
  global,
}

/// A models directory together with where the setting came from, so commands
/// can say which one they are obeying.
class ResolvedModels {
  /// As configured — relative to the project root.
  final String relative;

  final ModelsSource source;

  const ResolvedModels(this.relative, this.source);

  String absolute(String projectRoot) =>
      p.normalize(p.join(projectRoot, relative));
}

/// Reads and writes the remembered models directory.
///
/// Two places, in precedence order: a project file wins over the machine-wide
/// one, so a repo that does not follow your usual layout can say so without
/// disturbing every other project.
///
/// The project file lives inside `.dart_tool/`, which Dart projects already
/// ignore, so remembering a directory never dirties the working tree — the
/// same reason the cache lives there. `clear` leaves it alone; it is a
/// setting, not a cached result.
class ModelsConfig {
  static const _fileName = 'config.json';

  static String projectPath(String projectRoot) =>
      p.join(projectRoot, '.dart_tool', 'api_model_scanner', _fileName);

  /// `$XDG_CONFIG_HOME/api_model_scanner/config.json`, falling back to
  /// `~/.config` on unix and `%APPDATA%` on Windows.
  static String globalPath() {
    final env = Platform.environment;

    final xdg = env['XDG_CONFIG_HOME'];
    if (xdg != null && xdg.isNotEmpty) {
      return p.join(xdg, 'api_model_scanner', _fileName);
    }

    if (Platform.isWindows) {
      final appData = env['APPDATA'];
      if (appData != null && appData.isNotEmpty) {
        return p.join(appData, 'api_model_scanner', _fileName);
      }
    }

    final home = env['HOME'] ?? env['USERPROFILE'] ?? '.';
    return p.join(home, '.config', 'api_model_scanner', _fileName);
  }

  /// Whether the user has answered the "install the editor?" question, and
  /// how. Null means they have not been asked.
  ///
  /// Kept in the machine-wide file even when a project overrides the models
  /// directory: an editor extension is installed per machine, not per repo.
  static bool? readGuiPreference({String? globalConfigPath}) {
    final value = _readKey(globalConfigPath ?? globalPath(), 'gui');
    return value is bool ? value : null;
  }

  static void writeGuiPreference(bool wanted, {String? globalConfigPath}) =>
      _writeKey(globalConfigPath ?? globalPath(), 'gui', wanted);

  /// Which editor command manages the extension and opens the report.
  ///
  /// Null means nothing was chosen, and the caller falls back to probing.
  /// Machine-wide for the same reason as the gui answer: an editor is
  /// installed per machine, not per repository.
  static String? readEditor({String? globalConfigPath}) {
    final value = _readKey(globalConfigPath ?? globalPath(), 'editor');
    return value is String && value.trim().isNotEmpty ? value.trim() : null;
  }

  static void writeEditor(String command, {String? globalConfigPath}) =>
      _writeKey(globalConfigPath ?? globalPath(), 'editor', command.trim());

  /// Sets one key, leaving every other key in the file untouched.
  ///
  /// Reading the whole map rather than the keys this tool knows about means a
  /// config written by a newer version keeps its settings when an older one
  /// writes to it.
  static void _writeKey(String path, String key, Object? value) {
    final existing = <String, dynamic>{};

    final file = File(path);
    if (file.existsSync()) {
      try {
        final decoded = jsonDecode(file.readAsStringSync());
        if (decoded is Map<String, dynamic>) {
          existing.addAll(decoded);
        }
      } catch (_) {
        // A corrupt file is replaced rather than allowed to block the write.
      }
    }

    if (value == null) {
      existing.remove(key);
    } else {
      existing[key] = value;
    }

    Directory(p.dirname(path)).createSync(recursive: true);
    file.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(existing)}\n',
    );
  }

  /// Creates an empty config file if there is none, leaving any existing one
  /// untouched.
  static void ensureExists(String path) {
    final file = File(path);
    if (file.existsSync()) {
      return;
    }
    Directory(p.dirname(path)).createSync(recursive: true);
    file.writeAsStringSync('{}\n');
  }

  static Object? _readKey(String path, String key) {
    final file = File(path);
    if (!file.existsSync()) {
      return null;
    }
    try {
      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      return json[key];
    } catch (_) {
      return null;
    }
  }

  static String? _read(String path) {
    final file = File(path);
    if (!file.existsSync()) {
      return null;
    }
    try {
      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      final models = json['models'];
      if (models is String && models.trim().isNotEmpty) {
        return models.trim();
      }
    } catch (_) {
      // A corrupt config should not stop the tool: fall through and let the
      // caller treat it as "nothing configured".
    }
    return null;
  }

  static void _write(String path, String models) =>
      _writeKey(path, 'models', models);

  static String? readProject(String projectRoot) =>
      _read(projectPath(projectRoot));

  static String? readGlobal() => _read(globalPath());

  static void writeProject(String projectRoot, String models) =>
      _write(projectPath(projectRoot), models);

  static void writeGlobal(String models) => _write(globalPath(), models);

  /// Writes a global-shaped config to an explicit path. For tests.
  static void writeGlobalTo(String path, String models) => _write(path, models);

  /// Whether this machine has a config file at all — i.e. `init` has run.
  static bool hasGlobalConfig({String? globalConfigPath}) =>
      File(globalConfigPath ?? globalPath()).existsSync();

  /// The models directory to use, or null when nothing is configured.
  ///
  /// [globalConfigPath] exists so tests can resolve against a temporary file
  /// rather than whatever this machine happens to have set.
  static ResolvedModels? resolve(
    String projectRoot, {
    String? globalConfigPath,
  }) {
    final project = readProject(projectRoot);
    if (project != null) {
      return ResolvedModels(project, ModelsSource.project);
    }
    final global = _read(globalConfigPath ?? globalPath());
    if (global != null) {
      return ResolvedModels(global, ModelsSource.global);
    }
    return null;
  }
}

/// Thrown when a command needs a models directory and none is configured.
///
/// Deliberately not recoverable by guessing: see `resolveModels`.
class ModelsDirectoryNotSet implements Exception {
  /// Whether `init` has been run on this machine.
  ///
  /// The two cases need different advice. Nobody who has never run `init`
  /// should be told to run `init --project`, and someone who ran it and chose
  /// to set the directory per project should not be told to start over.
  final bool initialised;

  const ModelsDirectoryNotSet({this.initialised = false});

  /// What to tell the user, as lines.
  List<String> get guidance => initialised
      ? const [
          'No models directory is set for this project.',
          '',
          'Point this project at the folder holding its API model classes:',
          '  amscan init --project',
          '',
          'Or set a default for every project with `amscan init`, '
              'or pass --models=<dir> for a single run.',
        ]
      : const [
          'api_model_scanner is not set up yet.',
          '',
          'Run this once:',
          '  amscan init',
          '',
          'It asks where your API model classes live and which editor to '
              'use. Or pass --models=<dir> for a single run.',
        ];

  @override
  String toString() => guidance.first;
}
