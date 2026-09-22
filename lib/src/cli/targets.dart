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

/// Everywhere the report editor could go, most likely first.
///
/// VS Code and its forks come first because the extension is the older and
/// better-tested of the two, and only the newest Android Studio is offered:
/// a machine carries a settings directory per version, and listing six of
/// them would bury the one in use.
List<EditorTarget> editorTargets({
  required List<String> editors,
  required List<JetBrainsIde> ides,
}) {
  final newest = newestJetBrainsIde(ides);

  return [
    for (final command in editors) VsCodeTarget(command),
    if (newest != null) AndroidStudioTarget(newest),
  ];
}

/// The targets on this machine.
List<EditorTarget> currentEditorTargets() => editorTargets(
      editors: detectEditors(),
      ides: findJetBrainsIdes(roots: currentConfigRoots()),
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
