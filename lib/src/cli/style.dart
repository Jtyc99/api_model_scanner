import 'dart:io';

import 'package:path/path.dart' as p;

/// Terminal styling, which switches itself off when nobody can see it.
///
/// Every helper here returns plain text when output is piped, redirected or
/// captured by CI, so a log file never fills with escape sequences. `NO_COLOR`
/// is honoured too — it is the convention, and somebody setting it means it.

/// Width of a heading rule, chosen to sit inside an 80-column terminal.
const int _ruleWidth = 52;

bool get _styled {
  if (!stdout.hasTerminal) {
    return false;
  }
  final off = Platform.environment['NO_COLOR'];
  return off == null || off.isEmpty;
}

String _wrap(String text, String code) =>
    _styled ? '\x1b[${code}m$text\x1b[0m' : text;

String bold(String text) => _wrap(text, '1');
String dim(String text) => _wrap(text, '2');
String accent(String text) => _wrap(text, '36');
String good(String text) => _wrap(text, '32');
String warnish(String text) => _wrap(text, '33');
String bad(String text) => _wrap(text, '31');

/// `── Title ────────` padded to a constant width, so consecutive sections
/// line up however long their titles are.
String headingLine(String title) {
  final prefix = '── $title ';
  final fill = _ruleWidth - prefix.length;
  return '$prefix${'─' * (fill < 3 ? 3 : fill)}';
}

/// `  Label     value`, with the label padded to [width] so a run of them
/// forms a column.
String labelled(String label, String value, {int width = 8}) =>
    '  ${label.padRight(width)}  $value';

/// A path as a reader wants to see it: relative to the project when it is
/// inside it, `~`-abbreviated when it is under home, and untouched otherwise.
///
/// Absolute paths are correct but unreadable, and the interesting part is
/// always the tail.
String shortPath(String path, String projectRoot, {String? home}) {
  final normalized = p.normalize(path);
  final root = p.normalize(projectRoot);

  if (normalized == root) {
    return '.';
  }

  if (p.isWithin(root, normalized)) {
    return p.relative(normalized, from: root);
  }

  return homePath(normalized, home: home);
}

/// A path with the home directory replaced by `~`, or unchanged when it lies
/// outside home.
String homePath(String path, {String? home}) {
  final normalized = p.normalize(path);
  final house = p.normalize(
    home ??
        Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '',
  );

  if (house.isEmpty || house == '.') {
    return normalized;
  }
  if (normalized == house) {
    return '~';
  }
  if (p.isWithin(house, normalized)) {
    return p.join('~', p.relative(normalized, from: house));
  }
  return normalized;
}
