@Tags(['version'])
library;

import 'dart:io';

import 'package:omnystore/omnystore.dart' show omnyStoreVersion;
import 'package:test/test.dart';

void main() {
  group('omnyStoreVersion', () {
    test('matches the version declared in pubspec.yaml', () {
      final pubspec = File('pubspec.yaml');
      expect(
        pubspec.existsSync(),
        isTrue,
        reason: 'test must run from the package root',
      );

      final match = RegExp(
        r'''^version:\s*['"]?([^'"\s]+)''',
        multiLine: true,
      ).firstMatch(pubspec.readAsStringSync());

      expect(
        match,
        isNotNull,
        reason: 'no version: line found in pubspec.yaml',
      );

      expect(
        omnyStoreVersion,
        equals(match!.group(1)),
        reason:
            'omnyStoreVersion (lib/src/version.dart) is out of sync with '
            'pubspec.yaml — update the constant when bumping the version. It '
            'is reported by GET /health and sent as the client user-agent, so '
            'a stale value misidentifies every deployment.',
      );
    });
  });
}
