import 'dart:io';

/// Copies `version:` from the pubspec into `lib/src/version.dart`.
///
/// The constant exists because a globally activated snapshot cannot read the
/// pubspec it was built from, which leaves one fact written in two places.
/// `version_test.dart` fails when they disagree; this is how you make them
/// agree without retyping it:
///
/// ```bash
/// dart run tool/sync_version.dart
/// ```
void main() {
  final pubspec = File('pubspec.yaml');
  if (!pubspec.existsSync()) {
    stderr.writeln('Run this from the package root.');
    exit(1);
  }

  final declared = RegExp(r'^version:\s*(\S+)\s*$', multiLine: true)
      .firstMatch(pubspec.readAsStringSync());
  if (declared == null) {
    stderr.writeln('pubspec.yaml has no version:');
    exit(1);
  }

  final version = declared.group(1)!;
  final target = File('lib/src/version.dart');
  final source = target.readAsStringSync();
  final pattern = RegExp("const String packageVersion = '[^']*';");

  if (!pattern.hasMatch(source)) {
    stderr.writeln('lib/src/version.dart no longer declares packageVersion.');
    exit(1);
  }

  final updated =
      source.replaceFirst(pattern, "const String packageVersion = '$version';");

  if (updated == source) {
    stdout.writeln('Already $version.');
    return;
  }

  target.writeAsStringSync(updated);
  stdout.writeln('lib/src/version.dart -> $version');
}
