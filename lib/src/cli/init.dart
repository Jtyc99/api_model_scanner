import 'dart:io';

import 'package:path/path.dart' as p;

import '../scanning/model_discovery.dart';
import 'config.dart';

/// What is wrong with a models path a user offered, if anything.
///
/// Split from the reaction so the caller decides what is fatal: the wizard
/// re-asks on the first four and merely says so on [noModelClasses], since a
/// directory can legitimately be empty today and filled tomorrow.
enum ModelsPathVerdict {
  ok,

  /// Escapes the project root, so it could not mean the same thing in
  /// another checkout — and the config stores it relative.
  outsideProject,

  /// Nothing is at that path.
  missing,

  /// Names a file that is not Dart source.
  notADartFile,

  /// A real Dart path, but nothing there declares `fromJson`/`toJson`.
  noModelClasses,
}

/// Judges [relative] as a models path for [projectRoot].
Future<ModelsPathVerdict> checkModelsPath({
  required String projectRoot,
  required String relative,
}) async {
  final normalized = p.normalize(
    p.isAbsolute(relative) ? p.relative(relative, from: projectRoot) : relative,
  );

  if (normalized.startsWith('..')) {
    return ModelsPathVerdict.outsideProject;
  }

  final target = p.join(projectRoot, normalized);

  try {
    final discovered = await findModels(modelsPath: target);
    return discovered.classes.isEmpty
        ? ModelsPathVerdict.noModelClasses
        : ModelsPathVerdict.ok;
  } on ModelsDirectoryNotFound {
    return ModelsPathVerdict.missing;
  } on NotADartFile {
    return ModelsPathVerdict.notADartFile;
  }
}

/// What `init` decided, however it was decided — wizard or flags.
///
/// Every field is nullable and null means "not answered", which is why `-a`
/// can settle a models directory without also recording an opinion about an
/// editor nobody was asked about.
class InitAnswers {
  /// Relative to the project root, or null to leave the setting alone.
  final String? models;

  /// Whether the report editor was wanted.
  final bool? gui;

  /// Which editor command to drive.
  final String? editor;

  /// Write to this project rather than machine-wide.
  final bool forProject;

  const InitAnswers({
    this.models,
    this.gui,
    this.editor,
    this.forProject = false,
  });
}

/// Persists [answers] and returns the config file it wrote.
///
/// A project answer carries only the models directory: which editor is
/// installed is a fact about the machine, not about a repository.
String applyInit(
  InitAnswers answers, {
  required String projectRoot,
  String? globalConfigPath,
}) {
  if (answers.forProject) {
    if (answers.models != null) {
      ModelsConfig.writeProject(projectRoot, answers.models!);
    }
    return ModelsConfig.projectPath(projectRoot);
  }

  final path = globalConfigPath ?? ModelsConfig.globalPath();

  // Touched even when every answer was skipped, so a later command can tell
  // "init was never run" from "init ran and I chose to set it per project".
  // Those two need different advice.
  ModelsConfig.ensureExists(path);

  if (answers.models != null) {
    ModelsConfig.writeGlobalTo(path, answers.models!);
  }
  if (answers.editor != null) {
    ModelsConfig.writeEditor(answers.editor!, globalConfigPath: path);
  }
  if (answers.gui != null) {
    ModelsConfig.writeGuiPreference(answers.gui!, globalConfigPath: path);
  }

  return path;
}

/// Whether [root] is a Dart project.
///
/// `init --project` refuses without this, since `.dart_tool/` in a directory
/// that is not a project is litter nothing will ever read.
bool looksLikeDartProject(String root) =>
    File(p.join(root, 'pubspec.yaml')).existsSync();
