import 'dart:io';

import 'package:api_model_scanner/src/version.dart';
import 'package:test/test.dart';

void main() {
  test('the reported version is the published one', () {
    // `packageVersion` exists because a globally activated snapshot cannot
    // read the pubspec it was built from. That makes it a hand-kept copy of
    // one fact, which is exactly the kind of thing that silently drifts —
    // 1.0.1 and 1.0.2 both shipped reporting 1.0.0. Nothing but this test
    // stands between the two.
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final declared =
        RegExp(r'^version:\s*(\S+)\s*$', multiLine: true).firstMatch(pubspec);

    expect(declared, isNotNull, reason: 'pubspec.yaml has no version:');
    expect(
      packageVersion,
      declared!.group(1),
      reason: 'lib/src/version.dart is behind pubspec.yaml — update it',
    );
  });
}
