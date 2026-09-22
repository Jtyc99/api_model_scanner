import 'dart:io';

import 'gui.dart';
import 'jetbrains.dart';

/// Somewhere the report editor can be installed.
///
/// The two are nothing alike underneath — one is a `.vsix` handed to an
/// editor's own CLI, the other a directory copied into an IDE's settings —
/// so the commands that offer them work through this instead of knowing
/// which is which.
sealed class EditorTarget {
  /// As it appears in a list the user picks from.
  String get label;

  /// Whether the report editor is already there.
  bool get installed;
}

/// VS Code, or one of its forks.
class VsCodeTarget extends EditorTarget {
  /// The command that manages extensions: `code`, `cursor`, …
  final String command;

  VsCodeTarget(this.command);

  @override
  String get label => command;

  @override
  bool get installed => guiInstalled(editor: command);
}

/// An Android Studio installation.
class AndroidStudioTarget extends EditorTarget {
  final JetBrainsIde ide;

  AndroidStudioTarget(this.ide);

  @override
  String get label => ide.name;

  @override
  bool get installed => ide.hasPlugin;
}

/// The IDE whose terminal this is running in, when it can be told.
enum HostIde {
  vsCode,
  jetBrains,
}

/// Reads [environment] to work out which IDE opened this terminal.
///
/// Both announce themselves, which is a better signal than guessing from what
/// happens to be installed: somebody typing in Android Studio's terminal
/// wants the Android Studio editor, even with VS Code on the same machine.
///
/// Passed in rather than read so every case can be checked from one platform.
HostIde? detectHostIde(Map<String, String> environment) {
  // JetBrains first. Opening its terminal from a VS Code session leaves
  // TERM_PROGRAM behind in the environment, and the innermost terminal is
  // the one being typed into.
  final emulator = environment['TERMINAL_EMULATOR'] ?? '';
  if (emulator.toLowerCase().contains('jetbrains') ||
      environment.containsKey('__INTELLIJ_COMMAND_HISTFILE__')) {
    return HostIde.jetBrains;
  }

  // Set by VS Code and by its forks, which run the same terminal.
  if ((environment['TERM_PROGRAM'] ?? '').toLowerCase() == 'vscode') {
    return HostIde.vsCode;
  }

  return null;
}

/// The IDE this process is running inside, if any.
HostIde? currentHostIde() => detectHostIde(Platform.environment);

/// Everywhere the report editor could go, most likely first.
///
/// VS Code and its forks come first because the extension is the older and
/// better-tested of the two, and only the newest Android Studio is offered:
/// a machine carries a settings directory per version, and listing six of
/// them would bury the one in use.
List<EditorTarget> editorTargets({
  required List<String> editors,
  required List<JetBrainsIde> ides,
  HostIde? host,
}) {
  final newest = newestJetBrainsIde(ides);

  final vsCode = [for (final command in editors) VsCodeTarget(command)];
  final studio = [if (newest != null) AndroidStudioTarget(newest)];

  // The terminal you are typing in decides, when it says. Otherwise VS Code
  // and its forks come first, being the older and better-tested of the two.
  return host == HostIde.jetBrains
      ? [...studio, ...vsCode]
      : [...vsCode, ...studio];
}

/// The targets on this machine, ordered by the IDE this terminal belongs to.
List<EditorTarget> currentEditorTargets() => editorTargets(
      editors: detectEditors(),
      ides: findJetBrainsIdes(roots: currentConfigRoots()),
      host: currentHostIde(),
    );

/// The target `init` should offer: the first that has not got it already.
///
/// Stopping at the first target rather than the first *offerable* one is what
/// made `init` go quiet on a machine with VS Code already set up — it had
/// nothing to say about VS Code, and never looked past it to the Android
/// Studio sitting behind it without the plugin.
EditorTarget? offerableTarget(List<EditorTarget> targets) {
  for (final target in targets) {
    if (!target.installed) {
      return target;
    }
  }
  return null;
}

/// How to name the host IDE in a message.
String? hostIdeLabel(HostIde? host) => switch (host) {
      HostIde.vsCode => 'VS Code',
      HostIde.jetBrains => 'Android Studio',
      null => null,
    };
