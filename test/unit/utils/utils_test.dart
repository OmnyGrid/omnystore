import 'dart:convert';

import 'package:omnystore/omnystore.dart';
import 'package:test/test.dart';

void main() {
  group('Versions.parse', () {
    test('parses a plain semantic version', () {
      expect(Versions.parse('1.2.3'), Version.parse('1.2.3'));
    });

    test('strips a leading v, which is what git tags carry', () {
      expect(Versions.parse('v1.2.3'), Version.parse('1.2.3'));
      expect(Versions.parse('V2.0.0+build5'), Version.parse('2.0.0+build5'));
    });

    test('trims surrounding whitespace', () {
      expect(Versions.parse('  1.2.3\n'), Version.parse('1.2.3'));
    });

    test('raises a typed failure, not a FormatException', () {
      // A malformed version in a request body has to render as a 400, not
      // escape as an unmapped FormatException.
      expect(
        () => Versions.parse('not-a-version'),
        throwsA(
          isA<ValidationException>()
              .having((e) => e.field, 'field', 'version')
              .having(
                (e) => e.message,
                'message',
                contains('MAJOR.MINOR.PATCH'),
              ),
        ),
      );
      expect(() => Versions.parse(''), throwsA(isA<ValidationException>()));
      expect(() => Versions.parse('1.2'), throwsA(isA<ValidationException>()));
    });

    test('tryParse returns null instead of throwing', () {
      expect(Versions.tryParse('nope'), isNull);
      expect(Versions.tryParse('1.0.0'), Version.parse('1.0.0'));
    });
  });

  group('Versions.compare', () {
    test('orders by precedence', () {
      expect(
        Versions.compare(Version.parse('1.1.0'), Version.parse('1.0.0')),
        greaterThan(0),
      );
      expect(
        Versions.compare(Version.parse('1.0.0-beta.1'), Version.parse('1.0.0')),
        lessThan(0),
      );
    });

    test('breaks a precedence tie on build metadata', () {
      // Strict semver calls these equal. A registry cannot: two builds of one
      // version are distinct artifacts, and "latest" must not depend on
      // repository iteration order.
      final a = Version.parse('1.0.0+build1');
      final b = Version.parse('1.0.0+build2');

      expect(Versions.compare(b, a), greaterThan(0));
      expect(Versions.compare(a, b), lessThan(0));
      expect(Versions.compare(a, a), 0);
      expect(
        Versions.compare(Version.parse('1.0.0'), Version.parse('1.0.0')),
        0,
      );
    });
  });

  group('Versions.stamp', () {
    test('applies a channel tag and build number', () {
      final base = Version.parse('1.2.0');
      expect(
        Versions.stamp(base, ReleaseChannel.beta, 3).toString(),
        '1.2.0-beta.3',
      );
      expect(
        Versions.stamp(base, ReleaseChannel.dev, 41).toString(),
        '1.2.0-dev.41',
      );
      expect(Versions.stamp(base, ReleaseChannel.release).toString(), '1.2.0');
    });

    test('replaces an existing pre-release tag', () {
      expect(
        Versions.stamp(
          Version.parse('1.2.0-dev.9'),
          ReleaseChannel.beta,
          1,
        ).toString(),
        '1.2.0-beta.1',
      );
    });

    test('preserves build metadata', () {
      expect(
        Versions.stamp(
          Version.parse('1.2.0+ci.7'),
          ReleaseChannel.beta,
          2,
        ).toString(),
        '1.2.0-beta.2+ci.7',
      );
    });

    test('omits the number when none is given', () {
      expect(
        Versions.stamp(Version.parse('1.2.0'), ReleaseChannel.beta).toString(),
        '1.2.0-beta',
      );
    });
  });

  group('Versions.baseOf', () {
    test('strips the pre-release tag and build metadata', () {
      expect(
        Versions.baseOf(Version.parse('1.2.0-beta.3+ci.7')).toString(),
        '1.2.0',
      );
    });
  });

  group('Versions.parseConstraint', () {
    test('parses a caret constraint', () {
      final constraint = Versions.parseConstraint('^1.2.0');
      expect(constraint.allows(Version.parse('1.5.0')), isTrue);
      expect(constraint.allows(Version.parse('2.0.0')), isFalse);
    });

    test('raises a typed failure for a bad constraint', () {
      expect(
        () => Versions.parseConstraint('not a constraint'),
        throwsA(isA<ValidationException>()),
      );
    });
  });

  group('Names', () {
    test('accepts the shapes a URL and a storage key can carry', () {
      for (final name in [
        'acme',
        'omny-agent',
        'omny_agent',
        'omny.agent',
        'a1',
        'a',
      ]) {
        expect(Names.isValid(name), isTrue, reason: name);
      }
    });

    test('rejects anything that would need escaping', () {
      for (final name in [
        '',
        'Acme',
        'omny agent',
        '-leading',
        'trailing-',
        'double--dash',
        'slash/name',
        '../escape',
        'name!',
      ]) {
        expect(Names.isValid(name), isFalse, reason: name);
      }
    });

    test('rejects an over-long name', () {
      expect(Names.isValid('a' * Names.maxLength), isTrue);
      expect(Names.isValid('a' * (Names.maxLength + 1)), isFalse);
    });

    test('require names the offending field', () {
      expect(
        () => Names.require('Acme Corp', 'organization name'),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.field,
            'field',
            'organization name',
          ),
        ),
      );
    });

    test('slugify derives a valid name from a display name', () {
      expect(Names.slugify('Acme Corporation'), 'acme-corporation');
      expect(Names.slugify('  OmnyAgent  '), 'omnyagent');
      expect(Names.slugify('a//b'), 'a-b');
    });

    test('slugify fails when nothing usable remains', () {
      expect(() => Names.slugify('!!!'), throwsA(isA<ValidationException>()));
    });

    group('requireFilename', () {
      test('accepts an ordinary artifact name', () {
        expect(
          Names.requireFilename('omnyagent-linux-x64.tar.gz'),
          'omnyagent-linux-x64.tar.gz',
        );
      });

      test('accepts a name with spaces, which real installers have', () {
        // Every context the name reaches encodes or quotes it: the ?name=
        // query parameter, the quoted content-disposition filename, and S3's
        // canonical URI.
        expect(
          Names.requireFilename('Acme Installer.dmg'),
          'Acme Installer.dmg',
        );
      });

      test('rejects control characters that could split a header', () {
        // Built with fromCharCode rather than written as literals: a raw NUL
        // in a source file makes git treat the whole file as binary, so it
        // stops producing diffs.
        for (final code in [0x00, 0x0a, 0x0d, 0x1f, 0x7f]) {
          expect(
            () => Names.requireFilename('agent${String.fromCharCode(code)}.gz'),
            throwsA(isA<ValidationException>()),
            reason: 'code point $code',
          );
        }
      });

      test('rejects anything that could escape its prefix', () {
        // This is the check that stops a publisher writing outside the
        // release's directory in a local-directory store.
        for (final name in ['', '.', '..', 'a/b', r'a\b', '../../etc/passwd']) {
          expect(
            () => Names.requireFilename(name),
            throwsA(isA<ValidationException>()),
            reason: name,
          );
        }
      });

      test('rejects an over-long filename', () {
        expect(
          () => Names.requireFilename('a' * 256),
          throwsA(isA<ValidationException>()),
        );
      });
    });
  });

  group('Checksums', () {
    test('hashes the empty input to the known SHA-256', () {
      expect(
        Checksums.sha256Hex(const []),
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
    });

    test('hashes a known string', () {
      expect(
        Checksums.sha256OfString('abc'),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
    });

    test('matches case-insensitively', () {
      const digest =
          'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';
      expect(Checksums.matches(digest, digest.toUpperCase()), isTrue);
      expect(Checksums.matches(digest, 'deadbeef'), isFalse);
    });

    test('require throws with both digests attached', () {
      expect(
        () => Checksums.require('aaaa', 'bbbb'),
        throwsA(
          isA<ChecksumMismatchException>()
              .having((e) => e.expected, 'expected', 'aaaa')
              .having((e) => e.actual, 'actual', 'bbbb')
              .having((e) => e.algorithm, 'algorithm', 'sha256'),
        ),
      );
    });
  });

  group('Sha256Accumulator', () {
    test('matches a one-shot hash across chunk boundaries', () {
      final accumulator = Sha256Accumulator();
      for (final chunk in ['a', 'b', 'c']) {
        accumulator.add(utf8.encode(chunk));
      }
      final result = accumulator.finish();

      expect(result.sizeBytes, 3);
      expect(result.sha256, Checksums.sha256OfString('abc'));
    });

    test('is idempotent on finish', () {
      final accumulator = Sha256Accumulator()..add(utf8.encode('abc'));
      expect(accumulator.finish().sha256, accumulator.finish().sha256);
    });

    test('refuses bytes after being finished', () {
      // A digest that kept accepting bytes would describe neither the data it
      // reported on nor the data it saw.
      final accumulator = Sha256Accumulator()..add(utf8.encode('abc'));
      accumulator.finish();

      expect(() => accumulator.add(utf8.encode('d')), throwsStateError);
    });

    test('ignores empty chunks', () {
      final accumulator = Sha256Accumulator()
        ..add(const [])
        ..add(utf8.encode('abc'))
        ..add(const []);
      expect(accumulator.finish().sha256, Checksums.sha256OfString('abc'));
    });
  });

  group('ChecksumStream', () {
    test('passes bytes through untouched while hashing them', () async {
      late ChecksumResult observed;
      final source = Stream.fromIterable([
        utf8.encode('a'),
        utf8.encode('b'),
        utf8.encode('c'),
      ]);

      final collected = <int>[];
      await for (final chunk in ChecksumStream.transform(
        source,
        (r) => observed = r,
      )) {
        collected.addAll(chunk);
      }

      expect(utf8.decode(collected), 'abc');
      expect(observed.sha256, Checksums.sha256OfString('abc'));
      expect(observed.sizeBytes, 3);
    });

    test('of consumes a stream without retaining it', () async {
      final result = await ChecksumStream.of(
        Stream.fromIterable([utf8.encode('abc')]),
      );
      expect(result.sha256, Checksums.sha256OfString('abc'));
    });

    test('collect returns both the bytes and the digest', () async {
      final (bytes, checksum) = await ChecksumStream.collect(
        Stream.fromIterable([utf8.encode('ab'), utf8.encode('c')]),
      );
      expect(utf8.decode(bytes), 'abc');
      expect(checksum.sha256, Checksums.sha256OfString('abc'));
    });
  });

  group('Json', () {
    test('reads required and optional fields', () {
      final json = {'name': 'acme', 'count': 3, 'flag': true};

      expect(Json.requireString(json, 'name'), 'acme');
      expect(Json.requireInt(json, 'count'), 3);
      expect(Json.optBool(json, 'flag'), isTrue);
      expect(Json.optString(json, 'missing', 'fallback'), 'fallback');
      expect(Json.optInt(json, 'missing', 7), 7);
      expect(Json.optBool(json, 'missing'), isFalse);
    });

    test('accepts a whole-number double as an int', () {
      // A size round-tripped through a JavaScript runtime arrives this way.
      expect(Json.requireInt({'size': 42.0}, 'size'), 42);
    });

    test('raises a typed failure for a bad shape', () {
      expect(
        () => Json.requireString({'name': 3}, 'name'),
        throwsA(isA<InvalidJsonException>()),
      );
      expect(
        () => Json.requireInt({'count': 'three'}, 'count'),
        throwsA(isA<InvalidJsonException>()),
      );
      expect(
        () => Json.asObject('not an object'),
        throwsA(isA<InvalidJsonException>()),
      );
      expect(
        () => Json.asList('not a list'),
        throwsA(isA<InvalidJsonException>()),
      );
    });

    test('treats an empty required string as missing', () {
      expect(
        () => Json.requireString({'name': ''}, 'name'),
        throwsA(isA<InvalidJsonException>()),
      );
    });

    test('reads timestamps as UTC', () {
      final json = {'at': '2026-01-01T12:00:00+02:00'};
      final parsed = Json.requireTimestamp(json, 'at');

      expect(parsed.isUtc, isTrue);
      expect(parsed, DateTime.utc(2026, 1, 1, 10));
    });

    test('reads collections with empty defaults', () {
      expect(Json.optStringMap({}, 'metadata'), isEmpty);
      expect(Json.optStringList({}, 'platforms'), isEmpty);
      expect(
        Json.optStringMap({
          'metadata': {'a': 1},
        }, 'metadata'),
        {'a': '1'},
      );
    });
  });

  group('HttpDates', () {
    test('parses RFC 1123', () {
      expect(
        HttpDates.tryParse('Wed, 21 Oct 2015 07:28:00 GMT'),
        DateTime.utc(2015, 10, 21, 7, 28),
      );
    });

    test('parses RFC 850 with a windowed two-digit year', () {
      expect(
        HttpDates.tryParse('Wednesday, 21-Oct-15 07:28:00 GMT'),
        DateTime.utc(2015, 10, 21, 7, 28),
      );
    });

    test('parses ISO-8601, which some S3-compatible services emit', () {
      expect(
        HttpDates.tryParse('2015-10-21T07:28:00Z'),
        DateTime.utc(2015, 10, 21, 7, 28),
      );
    });

    test('returns null instead of throwing on nonsense', () {
      // A missing modification time is cosmetic and must never fail a download.
      expect(HttpDates.tryParse(null), isNull);
      expect(HttpDates.tryParse(''), isNull);
      expect(HttpDates.tryParse('not a date'), isNull);
    });

    test('round-trips through format', () {
      final instant = DateTime.utc(2015, 10, 21, 7, 28);
      expect(HttpDates.tryParse(HttpDates.format(instant)), instant);
    });
  });

  group('ScopedIdGenerator', () {
    test('stamps the scope into every id', () {
      final ids = ScopedIdGenerator(_Counter(), 'node-eu');

      expect(ids.next('rel'), 'rel-node-eu-1');
      expect(ids.next('rel'), 'rel-node-eu-2');
      expect(ids.next(), 'node-eu-3');
    });

    test('normalises an unsafe scope', () {
      // The scope lands in ids that become URL segments and storage keys.
      expect(
        ScopedIdGenerator(_Counter(), 'Node EU!').next('a'),
        'a-node-eu-1',
      );
    });

    test('keeps two stores from colliding', () {
      // The property the hub depends on: it caches which provider owns which
      // id, and two providers minting the same id would route writes wrongly.
      final a = ScopedIdGenerator(_Counter(), 'node-a');
      final b = ScopedIdGenerator(_Counter(), 'node-b');

      expect(a.next('rel'), isNot(b.next('rel')));
    });
  });

  group('Eq', () {
    test('compares maps order-insensitively', () {
      expect(Eq.maps({'a': 1, 'b': 2}, {'b': 2, 'a': 1}), isTrue);
      expect(Eq.maps({'a': 1}, {'a': 2}), isFalse);
      expect(Eq.maps({'a': 1}, {'a': 1, 'b': 2}), isFalse);
      expect(Eq.mapHash({'a': 1, 'b': 2}), Eq.mapHash({'b': 2, 'a': 1}));
    });

    test('compares lists order-sensitively', () {
      expect(Eq.lists([1, 2], [1, 2]), isTrue);
      expect(Eq.lists([1, 2], [2, 1]), isFalse);
      expect(Eq.listHash([1, 2]), Eq.listHash([1, 2]));
    });

    test('compares sets order-insensitively', () {
      expect(Eq.sets({1, 2}, {2, 1}), isTrue);
      expect(Eq.sets({1}, {1, 2}), isFalse);
      expect(Eq.setHash({1, 2}), Eq.setHash({2, 1}));
    });
  });
}

/// A deterministic inner generator, so scoped ids are predictable.
class _Counter implements IdGenerator {
  int _n = 0;

  @override
  String next([String prefix = '']) => '${++_n}';
}
