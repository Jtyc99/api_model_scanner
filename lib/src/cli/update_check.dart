import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'config.dart';

/// Tells you when a newer release exists, without ever being in the way.
///
/// A CLI installed with `dart pub global activate` never updates itself and
/// says nothing about it, so whoever installed it once stays on that version
/// until they happen to hear otherwise. This is the one line that tells them.
///
/// Everything here is built to fail silently: the check is skipped unless a
/// day has passed, it gives up after [_timeout], and any error at all is
/// swallowed. A scan that cannot reach pub.dev is a scan, not an error.
class UpdateCheck {
  /// How long a fetched answer stays good for.
  static const Duration _interval = Duration(days: 1);

  /// How long to wait for pub.dev before giving up on the idea.
  static const Duration _timeout = Duration(seconds: 2);

  /// Set this to anything to never check. For CI, and for people who would
  /// rather their tools did not talk to the network behind their back.
  static const String optOutVariable = 'AMSCAN_NO_UPDATE_CHECK';

  static String cachePath() =>
      p.join(p.dirname(ModelsConfig.globalPath()), 'update_check.json');

  /// Whether a check should happen at all right now.
  ///
  /// [now] and [env] are injected so the decision can be tested without
  /// waiting a day or setting environment variables.
  static bool isDue({
    String? cacheFilePath,
    DateTime? now,
    Map<String, String>? env,
  }) {
    final environment = env ?? Platform.environment;
    if ((environment[optOutVariable] ?? '').isNotEmpty) {
      return false;
    }

    final checked = _readCache(cacheFilePath ?? cachePath())?['checked'];
    if (checked is! int) {
      return true;
    }

    final last = DateTime.fromMillisecondsSinceEpoch(checked);
    return (now ?? DateTime.now()).difference(last) >= _interval;
  }

  /// The version last heard about, whether or not it is still fresh.
  static String? lastKnown({String? cacheFilePath}) {
    final latest = _readCache(cacheFilePath ?? cachePath())?['latest'];
    return latest is String && latest.isNotEmpty ? latest : null;
  }

  /// Records [latest] as of [now]. Failing to write is not worth a word:
  /// the cost is one extra request tomorrow.
  static void remember(
    String latest, {
    String? cacheFilePath,
    DateTime? now,
  }) {
    final path = cacheFilePath ?? cachePath();
    try {
      Directory(p.dirname(path)).createSync(recursive: true);
      File(path).writeAsStringSync(jsonEncode({
        'checked': (now ?? DateTime.now()).millisecondsSinceEpoch,
        'latest': latest,
      }));
    } catch (_) {
      // Not worth telling anyone about.
    }
  }

  /// The newest version pub.dev knows about, or null if it cannot be had.
  static Future<String?> fetchLatest({HttpClient? client}) async {
    final http = client ?? HttpClient();
    http.connectionTimeout = _timeout;
    try {
      // `/versions/latest` is a 400: the version is part of that path, not
      // a word it accepts. The package endpoint carries the same answer.
      final uri = Uri.parse('https://pub.dev/api/packages/$packageName');
      final response =
          await http.getUrl(uri).then((r) => r.close()).timeout(_timeout);
      if (response.statusCode != 200) {
        return null;
      }
      final body = await response.transform(utf8.decoder).join().timeout(
            _timeout,
          );
      final latest = (jsonDecode(body) as Map<String, dynamic>)['latest'];
      final version = latest is Map<String, dynamic> ? latest['version'] : null;
      return version is String && version.isNotEmpty ? version : null;
    } catch (_) {
      return null;
    } finally {
      http.close(force: true);
    }
  }

  static Map<String, dynamic>? _readCache(String path) {
    try {
      final file = File(path);
      if (!file.existsSync()) {
        return null;
      }
      final decoded = jsonDecode(file.readAsStringSync());
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }
}

/// The package as pub.dev names it.
const String packageName = 'api_model_scanner';

/// Whether [latest] is a later release than [current].
///
/// Compares the numbers rather than the text, so 1.0.10 is correctly newer
/// than 1.0.9 — the comparison a plain string sort gets backwards. Build and
/// pre-release suffixes are dropped: this only ever decides whether to print
/// one line, and a pre-release is not something to nudge anyone towards.
bool isNewerVersion(String latest, String current) {
  final a = _parts(latest);
  final b = _parts(current);
  if (a == null || b == null) {
    return false;
  }

  for (var i = 0; i < 3; i++) {
    if (a[i] != b[i]) {
      return a[i] > b[i];
    }
  }
  return false;
}

List<int>? _parts(String version) {
  final core = version.split(RegExp('[-+]')).first.trim();
  final fields = core.split('.');
  if (fields.length != 3) {
    return null;
  }
  final numbers = [for (final field in fields) int.tryParse(field)];
  return numbers.contains(null) ? null : numbers.cast<int>();
}
