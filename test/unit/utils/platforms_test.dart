import 'dart:io';

import 'package:omnystore/omnystore.dart';
import 'package:test/test.dart';

void main() {
  group('current', () {
    test('reports this machine as os-arch', () {
      final current = Platforms.current;

      expect(current, matches(RegExp(r'^[a-z0-9]+-[a-z0-9]+$')));
      expect(current, startsWith(Platform.operatingSystem));
      expect(current, isNot(endsWith(Platforms.unknown)));
    });

    test('is stable across calls', () {
      expect(Platforms.current, Platforms.current);
    });
  });

  group('detect', () {
    test('reads the architecture out of the Dart version string', () {
      // The only place the VM exposes the CPU architecture.
      expect(
        Platforms.detect(
          version: '3.13.0 (stable) (Wed Aug 5 2026) on "macos_arm64"',
          operatingSystem: 'macos',
        ),
        'macos-arm64',
      );
      expect(
        Platforms.detect(
          version: '3.13.0 (stable) (Wed Aug 5 2026) on "macos_x64"',
          operatingSystem: 'macos',
        ),
        'macos-x64',
      );
      expect(
        Platforms.detect(
          version: '3.13.0 (stable) (Wed Aug 5 2026) on "linux_arm64"',
          operatingSystem: 'linux',
        ),
        'linux-arm64',
      );
      expect(
        Platforms.detect(
          version: '3.13.0 (stable) (Wed Aug 5 2026) on "windows_x64"',
          operatingSystem: 'windows',
        ),
        'windows-x64',
      );
    });

    test('normalises the architecture the VM reports', () {
      expect(
        Platforms.detect(
          version: 'on "linux_riscv64"',
          operatingSystem: 'linux',
        ),
        'linux-riscv64',
      );
      expect(
        Platforms.detect(version: 'on "linux_ia32"', operatingSystem: 'linux'),
        'linux-x86',
      );
    });

    test('reports the OS with an unknown arch rather than guessing', () {
      // An artifact tagged with the wrong architecture fails at launch on the
      // user's machine — worse than failing to match at all.
      expect(
        Platforms.detect(version: 'no triple here', operatingSystem: 'linux'),
        'linux-${Platforms.unknown}',
      );
    });
  });

  group('normalize', () {
    test('accepts the aliases other toolchains emit', () {
      // A platform string copied from another build system should line up
      // rather than silently never matching.
      expect(Platforms.normalize('darwin-aarch64'), 'macos-arm64');
      expect(Platforms.normalize('Darwin_ARM64'), 'macos-arm64');
      expect(Platforms.normalize('osx-x86_64'), 'macos-x64');
      expect(Platforms.normalize('win32-amd64'), 'windows-x64');
      expect(Platforms.normalize('linux-i686'), 'linux-x86');
      expect(Platforms.normalize('linux-armv7l'), 'linux-arm');
    });

    test('leaves a canonical token alone', () {
      for (final platform in [
        'linux-x64',
        'linux-arm64',
        'macos-x64',
        'macos-arm64',
        'windows-x64',
        'android-arm64',
        'ios-arm64',
      ]) {
        expect(Platforms.normalize(platform), platform);
      }
    });

    test('treats a bare OS as an OS', () {
      expect(Platforms.normalize('linux'), 'linux');
      expect(Platforms.normalize('darwin'), 'macos');
    });

    test('passes web and empty through sensibly', () {
      expect(Platforms.normalize('web'), Platforms.web);
      expect(Platforms.normalize(''), Platforms.unknown);
      expect(Platforms.normalize('  '), Platforms.unknown);
    });

    test('leaves an unrecognised token intact rather than mangling it', () {
      expect(Platforms.normalize('freebsd-riscv64'), 'freebsd-riscv64');
    });
  });

  group('matches', () {
    test('matches across spellings of the same platform', () {
      expect(Platforms.matches('darwin-aarch64', 'macos-arm64'), isTrue);
      expect(Platforms.matches('macos-arm64', 'macos-arm64'), isTrue);
      expect(Platforms.matches('MACOS-ARM64', 'macos-arm64'), isTrue);
    });

    test('never matches a different architecture', () {
      // Rosetta *could* run an x64 build on Apple Silicon, but choosing that
      // silently would ship the slower binary to every Apple Silicon user
      // forever, and hide the missing native build from whoever publishes it.
      expect(Platforms.matches('macos-x64', 'macos-arm64'), isFalse);
      expect(Platforms.matches('macos-arm64', 'macos-x64'), isFalse);
      expect(Platforms.matches('linux-x64', 'macos-x64'), isFalse);
      expect(Platforms.matches('linux-arm64', 'linux-x64'), isFalse);
    });
  });
}
