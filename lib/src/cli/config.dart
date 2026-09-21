import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Where a configured models directory came from.
enum ModelsSource {
  /// Passed explicitly as `--models`.
  flag,

  /// `.dart_tool/api_model_scanner/config.json` in this project.
  project,

  /// The machine-wide default written by `set-default`.
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

  static void writeGuiPreference(bool wanted, {String? globalConfigPath}) {
    final path = globalConfigPath ?? globalPath();
    final existing = _readKey(path, 'models');
    Directory(p.dirname(path)).createSync(recursive: true);
    File(path).writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert({
            if (existing is String) 'models': existing,
            'gui': wanted,
          })}\n',
    );
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

  static void _write(String path, String models) {
    final gui = _readKey(path, 'gui');
    Directory(p.dirname(path)).createSync(recursive: true);
    File(path).writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert({
            'models': models,
            if (gui is bool) 'gui': gui,
          })}\n',
    );
  }

  static String? readProject(String projectRoot) =>
      _read(projectPath(projectRoot));

  static String? readGlobal() => _read(globalPath());

  static void writeProject(String projectRoot, String models) =>
      _write(projectPath(projectRoot), models);

  static void writeGlobal(String models) => _write(globalPath(), models);

  /// Writes a global-shaped config to an explicit path. For tests.
  static void writeGlobalTo(String path, String models) => _write(path, models);

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
  const ModelsDirectoryNotSet();

  @override
  String toString() =>
      'No models directory is set. Run `amscan set-default <dir>`.';
}
