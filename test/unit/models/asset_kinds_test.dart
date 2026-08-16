import 'package:omnystore/omnystore.dart';
import 'package:test/test.dart';

/// An asset record with only the fields kind resolution depends on.
Asset assetNamed(String name, {String? kind}) => Asset(
  id: 'asset-$name',
  releaseId: 'rel-1',
  packageId: 'pkg-1',
  organizationId: 'org-1',
  name: name,
  storageKey: 'k/$name',
  sizeBytes: 1,
  sha256: 'x',
  kind: kind,
  createdAt: DateTime.utc(2026),
);

/// The vocabulary three parts of the system read: the update service, which
/// must never offer a signature as the thing to install; the CLI's `--kind`
/// filter; and anyone reading a listing.
void main() {
  group('of', () {
    test('returns the tag when one is set', () {
      expect(
        AssetKinds.of(assetNamed('agent.dmg', kind: 'installer')),
        'installer',
      );
    });

    test('prefers the tag over what the filename suggests', () {
      // A publisher who tags explicitly has said what they mean.
      expect(
        AssetKinds.of(assetNamed('agent.tar.gz.sha256', kind: 'archive')),
        'archive',
      );
    });

    test('infers checksums from the digest suffixes', () {
      for (final name in [
        'agent.tar.gz.sha256',
        'agent.tar.gz.sha512',
        'agent.tar.gz.md5',
      ]) {
        expect(AssetKinds.of(assetNamed(name)), 'checksums', reason: name);
      }
    });

    test('infers checksums from the conventional manifest filenames', () {
      expect(AssetKinds.of(assetNamed('CHECKSUMS.txt')), 'checksums');
      expect(AssetKinds.of(assetNamed('SHA256SUMS.txt')), 'checksums');
    });

    test('infers signature and sbom from their suffixes', () {
      expect(AssetKinds.of(assetNamed('agent.tar.gz.sig')), 'signature');
      expect(AssetKinds.of(assetNamed('agent.tar.gz.asc')), 'signature');
      expect(AssetKinds.of(assetNamed('agent.sbom.json')), 'sbom');
    });

    test('leaves an installable artifact untagged rather than guessing', () {
      // Inferring `installer` from `.dmg` would be a guess with consequences:
      // it would change which artifact the update service offers.
      expect(AssetKinds.of(assetNamed('agent.dmg')), isNull);
      expect(AssetKinds.of(assetNamed('agent.tar.gz')), isNull);
    });

    test('treats an empty tag as untagged', () {
      expect(AssetKinds.of(assetNamed('agent.tar.gz', kind: '')), isNull);
    });
  });

  group('isAuxiliary', () {
    test('accepts both spellings of the checksum kind', () {
      // Both are in the wild; a publisher should not have to guess which one
      // the update service recognises.
      expect(
        AssetKinds.isAuxiliary(assetNamed('a', kind: 'checksums')),
        isTrue,
      );
      expect(AssetKinds.isAuxiliary(assetNamed('a', kind: 'checksum')), isTrue);
    });

    test('covers signatures and SBOMs', () {
      expect(
        AssetKinds.isAuxiliary(assetNamed('a', kind: 'signature')),
        isTrue,
      );
      expect(AssetKinds.isAuxiliary(assetNamed('a', kind: 'sbom')), isTrue);
    });

    test('is false for installables and for untagged artifacts', () {
      expect(
        AssetKinds.isAuxiliary(assetNamed('a.dmg', kind: 'installer')),
        isFalse,
      );
      expect(AssetKinds.isAuxiliary(assetNamed('a.tar.gz')), isFalse);
    });

    test('catches an untagged checksum file', () {
      // The case that matters: a release published before `kind` existed still
      // must not offer its digest file as the build.
      expect(AssetKinds.isAuxiliary(assetNamed('a.tar.gz.sha256')), isTrue);
    });
  });

  group('matches', () {
    test('matches a tagged artifact by its tag', () {
      expect(
        AssetKinds.matches(assetNamed('a.dmg', kind: 'installer'), 'installer'),
        isTrue,
      );
    });

    test('matches an untagged checksum file by its filename', () {
      expect(
        AssetKinds.matches(assetNamed('a.tar.gz.sha256'), 'checksums'),
        isTrue,
      );
    });

    test('does not match an untagged installable against any kind', () {
      expect(AssetKinds.matches(assetNamed('a.dmg'), 'installer'), isFalse);
    });
  });

  group('byPreference', () {
    /// Sorts [names] by preference and returns them in the chosen order.
    List<String> ordered(List<Asset> assets) =>
        (assets.toList()..sort(AssetKinds.byPreference))
            .map((a) => a.name)
            .toList();

    test('ranks installer above archive above untagged', () {
      expect(
        ordered([
          assetNamed('c.bin'),
          assetNamed('b.tar.gz', kind: 'archive'),
          assetNamed('a.dmg', kind: 'installer'),
        ]),
        ['a.dmg', 'b.tar.gz', 'c.bin'],
      );
    });

    test('ranks an unrecognised kind last', () {
      expect(
        ordered([
          assetNamed('a.bin', kind: 'something-else'),
          assetNamed('b.bin'),
        ]),
        ['b.bin', 'a.bin'],
      );
    });

    test('breaks ties on name so the choice is stable', () {
      expect(
        ordered([
          assetNamed('b.dmg', kind: 'installer'),
          assetNamed('a.dmg', kind: 'installer'),
        ]),
        ['a.dmg', 'b.dmg'],
      );
    });
  });
}
