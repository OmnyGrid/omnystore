import 'package:omnystore/omnystore.dart';
import 'package:test/test.dart';

void main() {
  group('forVersion', () {
    test('maps a plain version to release', () {
      expect(
        ReleaseChannel.forVersion(Version.parse('1.0.0')),
        ReleaseChannel.release,
      );
    });

    test('ignores build metadata', () {
      // Semver says build metadata is not part of a version's identity; a
      // stable build is stable however it was produced.
      expect(
        ReleaseChannel.forVersion(Version.parse('2.0.0+build5')),
        ReleaseChannel.release,
      );
    });

    test('reads the first pre-release identifier', () {
      expect(
        ReleaseChannel.forVersion(Version.parse('1.1.0-beta.2')),
        ReleaseChannel.beta,
      );
      expect(
        ReleaseChannel.forVersion(Version.parse('1.1.0-dev.3')),
        ReleaseChannel.dev,
      );
      expect(
        ReleaseChannel.forVersion(Version.parse('1.1.0-beta')),
        ReleaseChannel.beta,
      );
    });

    test('treats an unrecognised pre-release as dev', () {
      // The least stable thing it could be — never something that ships to
      // production by accident.
      for (final version in ['1.0.0-rc.1', '1.0.0-alpha', '1.0.0-nightly.9']) {
        expect(
          ReleaseChannel.forVersion(Version.parse(version)),
          ReleaseChannel.dev,
          reason: version,
        );
      }
    });

    test('is case-insensitive on the tag', () {
      expect(
        ReleaseChannel.forVersion(Version.parse('1.0.0-BETA.1')),
        ReleaseChannel.beta,
      );
    });
  });

  group('parse', () {
    test('accepts the canonical names', () {
      expect(ReleaseChannel.parse('dev'), ReleaseChannel.dev);
      expect(ReleaseChannel.parse('beta'), ReleaseChannel.beta);
      expect(ReleaseChannel.parse('release'), ReleaseChannel.release);
    });

    test('accepts the aliases people actually type', () {
      expect(ReleaseChannel.parse('stable'), ReleaseChannel.release);
      expect(ReleaseChannel.parse('production'), ReleaseChannel.release);
      expect(ReleaseChannel.parse('prod'), ReleaseChannel.release);
      expect(ReleaseChannel.parse('development'), ReleaseChannel.dev);
      expect(ReleaseChannel.parse('testing'), ReleaseChannel.beta);
    });

    test('is case- and whitespace-insensitive', () {
      expect(ReleaseChannel.parse('  BETA '), ReleaseChannel.beta);
    });

    test('rejects an unknown name with a helpful message', () {
      expect(
        () => ReleaseChannel.parse('canary'),
        throwsA(
          isA<ValidationException>()
              .having((e) => e.field, 'field', 'channel')
              .having(
                (e) => e.message,
                'message',
                contains('dev, beta, release'),
              ),
        ),
      );
    });

    test('tryParse returns null instead of throwing', () {
      expect(ReleaseChannel.tryParse('canary'), isNull);
      expect(ReleaseChannel.tryParse('beta'), ReleaseChannel.beta);
    });
  });

  group('accepts', () {
    test('is inclusive downward in stability', () {
      // A dev subscriber takes everything; a release subscriber takes only
      // stable. This is what makes promotion reach every subscriber without
      // re-publishing per channel.
      expect(ReleaseChannel.dev.accepts(ReleaseChannel.dev), isTrue);
      expect(ReleaseChannel.dev.accepts(ReleaseChannel.beta), isTrue);
      expect(ReleaseChannel.dev.accepts(ReleaseChannel.release), isTrue);

      expect(ReleaseChannel.beta.accepts(ReleaseChannel.dev), isFalse);
      expect(ReleaseChannel.beta.accepts(ReleaseChannel.beta), isTrue);
      expect(ReleaseChannel.beta.accepts(ReleaseChannel.release), isTrue);

      expect(ReleaseChannel.release.accepts(ReleaseChannel.dev), isFalse);
      expect(ReleaseChannel.release.accepts(ReleaseChannel.beta), isFalse);
      expect(ReleaseChannel.release.accepts(ReleaseChannel.release), isTrue);
    });

    test('orders stability consistently', () {
      expect(ReleaseChannel.dev.stability, 0);
      expect(ReleaseChannel.beta.stability, 1);
      expect(ReleaseChannel.release.stability, 2);
      expect(ReleaseChannel.byStability, [
        ReleaseChannel.dev,
        ReleaseChannel.beta,
        ReleaseChannel.release,
      ]);
    });
  });

  group('preReleaseTag', () {
    test('is null for release and the tag otherwise', () {
      expect(ReleaseChannel.release.preReleaseTag, isNull);
      expect(ReleaseChannel.beta.preReleaseTag, 'beta');
      expect(ReleaseChannel.dev.preReleaseTag, 'dev');
    });

    test('round-trips through forVersion', () {
      // Stamping a version with a channel's tag and reading the channel back
      // must be the identity, or the two halves could disagree.
      for (final channel in ReleaseChannel.values) {
        final stamped = Versions.stamp(Version.parse('1.2.3'), channel, 1);
        expect(ReleaseChannel.forVersion(stamped), channel, reason: '$stamped');
      }
    });
  });
}
