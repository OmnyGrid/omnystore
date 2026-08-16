import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

import '../../channels/release_channel.dart';
import '../../client/omnystore_client.dart';
import '../../downloads/download_manager.dart';
import '../../exceptions/omnystore_exception.dart';
import '../../models/asset.dart';
import '../../repositories/release_query.dart';
import '../../services/asset_download.dart';
import '../../utils/checksum.dart';
import '../../utils/platforms.dart';
import '../../utils/version_codec.dart';
import '../cli_context.dart';
import 'resource_commands.dart';

/// `omnystore release` — publishing and inspecting releases.
class ReleaseCommand extends Command<int> {
  @override
  final String name = 'release';

  @override
  final String description = 'Publish and inspect releases.';

  @override
  List<String> get aliases => const ['releases'];

  /// Creates the command group.
  ReleaseCommand(Future<CliContext> Function() context) {
    addSubcommand(_ReleasePublishCommand(context));
    addSubcommand(_ReleaseListCommand(context));
    addSubcommand(_ReleaseLatestCommand(context));
    addSubcommand(_ReleasePromoteCommand(context));
    addSubcommand(_ReleaseYankCommand(context));
    addSubcommand(_ReleaseDeleteCommand(context));
  }
}

class _ReleasePublishCommand extends StoreCommand {
  @override
  final String name = 'publish';

  @override
  final String description = 'Publish a release of a package.';

  @override
  String get invocation =>
      'omnystore release publish --package <pkg> --version <version>';

  _ReleasePublishCommand(super.context) {
    argParser
      ..addOption('package', abbr: 'p', help: 'Package name or id.')
      ..addOption(
        'version',
        help:
            'Semantic version. Its pre-release tag decides the channel: '
            '1.2.0-dev.3 is dev, 1.2.0-beta.1 is beta, 1.2.0 is release.',
      )
      ..addOption('title', help: 'Release title.')
      ..addOption('notes', help: 'Release notes, or @path to read a file.')
      ..addOption('tag', help: 'VCS tag or commit this was built from.')
      ..addFlag(
        'draft',
        help: 'Store it without offering it to clients yet.',
        negatable: false,
      )
      ..addMultiOption(
        'asset',
        abbr: 'a',
        help:
            'Attach a file, repeatable. Use path or path:platform to tag the '
            'artifact, e.g. build/agent-linux.tar.gz:linux-x64.',
      )
      ..addMultiOption('metadata', help: 'Extra key=value pairs.');
  }

  @override
  Future<int> run() async {
    final ctx = await context;
    final version = Versions.parse(require('version'));

    final release = await ctx.store.publishRelease(
      packageReference: require('package'),
      version: version,
      title: optional('title'),
      notes: await _readNotes(optional('notes')),
      tag: optional('tag'),
      draft: flag('draft'),
      metadata: metadata(),
    );

    ctx.progress(
      'Published ${release.version} on the ${release.channel.name} channel'
      '${release.draft ? ' (draft)' : ''}',
    );

    for (final spec in argResults?.multiOption('asset') ?? const <String>[]) {
      final (path, platform) = _splitAssetSpec(spec);
      final file = File(path);
      if (!await file.exists()) {
        throw CliException('Asset file not found: $path', exitCode: 66);
      }
      final asset = await ctx.store.attachAsset(
        releaseId: release.id,
        name: p.basename(path),
        data: file.openRead(),
        length: await file.length(),
        platform: platform,
      );
      ctx.progress('  + ${asset.name} (${asset.sizeBytes} bytes)');
    }

    ctx.writeOne(release, 'Released ${release.version} (${release.id})');
    return 0;
  }

  /// Reads notes inline, or from a file when the value starts with `@`.
  ///
  /// Release notes are usually a changelog file, and shells make passing
  /// multi-line text as an argument awkward.
  static Future<String?> _readNotes(String? value) async {
    if (value == null || !value.startsWith('@')) return value;
    final file = File(value.substring(1));
    if (!await file.exists()) {
      throw CliException('Notes file not found: ${file.path}', exitCode: 66);
    }
    return file.readAsString();
  }

  /// Splits `path` or `path:platform`.
  ///
  /// Splits on the *last* colon so a Windows path like `C:\build\agent.exe`
  /// still works, and only when what follows looks like a platform token
  /// rather than a path segment.
  static (String path, String? platform) _splitAssetSpec(String spec) {
    final index = spec.lastIndexOf(':');
    if (index <= 0) return (spec, null);
    final tail = spec.substring(index + 1);
    if (tail.isEmpty || tail.contains(RegExp(r'[/\\]'))) return (spec, null);
    return (spec.substring(0, index), tail);
  }
}

class _ReleaseListCommand extends StoreCommand {
  @override
  final String name = 'list';

  @override
  final String description = 'List a package\'s releases, newest first.';

  @override
  String get invocation => 'omnystore release list --package <pkg>';

  _ReleaseListCommand(super.context) {
    argParser
      ..addOption('package', abbr: 'p', help: 'Package name or id.')
      ..addOption(
        'channel',
        abbr: 'c',
        help: 'Only this channel.',
        allowed: ['dev', 'beta', 'release'],
      )
      ..addFlag('drafts', help: 'Include drafts.', negatable: false)
      ..addFlag('yanked', help: 'Include yanked releases.', negatable: false)
      ..addOption('limit', help: 'Maximum releases to show.');
  }

  @override
  Future<int> run() async {
    final ctx = await context;
    final channel = optional('channel');
    final releases = await ctx.store.listReleases(
      require('package'),
      query: ReleaseQuery(
        channel: channel == null ? null : ReleaseChannel.parse(channel),
        includeDrafts: flag('drafts'),
        includeYanked: flag('yanked'),
        includeUnpublished: flag('drafts'),
        limit: int.tryParse(optional('limit') ?? ''),
      ),
    );

    ctx.writeTable(
      releases,
      headers: ['VERSION', 'CHANNEL', 'PUBLISHED', 'STATE', 'ID'],
      rows: [
        for (final r in releases)
          [
            r.version.toString(),
            r.channel.name,
            r.publishedAt?.toIso8601String().split('T').first ?? '-',
            r.yanked
                ? 'yanked'
                : r.draft
                ? 'draft'
                : 'published',
            r.id,
          ],
      ],
      emptyMessage: 'No releases yet.',
    );
    return 0;
  }
}

class _ReleaseLatestCommand extends StoreCommand {
  @override
  final String name = 'latest';

  @override
  final String description = 'Show the latest release on a channel.';

  @override
  String get invocation =>
      'omnystore release latest --package <pkg> [--channel beta]';

  _ReleaseLatestCommand(super.context) {
    argParser
      ..addOption('package', abbr: 'p', help: 'Package name or id.')
      ..addOption(
        'channel',
        abbr: 'c',
        help:
            'Channel to query. Defaults to release, so a deploy script that '
            'forgets the flag never picks up a pre-release. Pass "any" for the '
            'newest release on any channel.',
        allowed: ['dev', 'beta', 'release', 'any'],
        defaultsTo: 'release',
      )
      ..addFlag(
        'exact',
        help:
            'Restrict to exactly this channel. Without it a beta query also '
            'returns a newer stable release, which is what a beta subscriber '
            'should be offered.',
        negatable: false,
      );
  }

  @override
  Future<int> run() async {
    final ctx = await context;
    final packageRef = require('package');
    final channel = optional('channel') ?? 'release';

    final release = channel == 'any'
        ? await ctx.store.latestAny(packageRef)
        : await ctx.store.latestChannel(
            packageRef,
            ReleaseChannel.parse(channel),
            exact: flag('exact'),
          );

    if (release == null) {
      // A package with no offerable release is a real state, not an error, but
      // a non-zero exit lets `if omnystore release latest …` work in a script.
      ctx.progress(
        channel == 'any'
            ? 'No offerable release for $packageRef.'
            : 'No $channel release for $packageRef.',
      );
      return 1;
    }

    ctx.writeOne(release, release.version.toString());
    return 0;
  }
}

class _ReleasePromoteCommand extends StoreCommand {
  @override
  final String name = 'promote';

  @override
  final String description =
      'Promote a release to a more stable channel, copying its artifacts.';

  @override
  String get invocation =>
      'omnystore release promote <release-id> --to release';

  _ReleasePromoteCommand(super.context) {
    argParser
      ..addOption(
        'to',
        help: 'Target channel.',
        allowed: ['beta', 'release'],
        defaultsTo: 'release',
      )
      ..addOption('notes', help: 'Notes for the promoted release.');
  }

  @override
  Future<int> run() async {
    final ctx = await context;
    final rest = argResults!.rest;
    if (rest.isEmpty) {
      throw const CliException(
        'Provide the release id to promote.',
        exitCode: 64,
      );
    }

    final promoted = await ctx.store.promoteRelease(
      rest.first,
      ReleaseChannel.parse(optional('to') ?? 'release'),
      notes: optional('notes'),
    );
    ctx.writeOne(
      promoted,
      'Promoted to ${promoted.version} on the ${promoted.channel.name} channel',
    );
    return 0;
  }
}

class _ReleaseYankCommand extends StoreCommand {
  @override
  final String name = 'yank';

  @override
  final String description =
      'Withdraw a release from update offers, without breaking pinned clients.';

  @override
  String get invocation => 'omnystore release yank <release-id> --reason "..."';

  _ReleaseYankCommand(super.context) {
    argParser
      ..addOption('reason', help: 'Why it was withdrawn.')
      ..addFlag('undo', help: 'Re-instate a yanked release.', negatable: false);
  }

  @override
  Future<int> run() async {
    final ctx = await context;
    final rest = argResults!.rest;
    if (rest.isEmpty) {
      throw const CliException('Provide the release id.', exitCode: 64);
    }

    final undo = flag('undo');
    final release = await ctx.store.updateRelease(
      rest.first,
      yanked: !undo,
      yankedReason: undo ? null : optional('reason'),
    );
    ctx.writeOne(
      release,
      undo
          ? 'Re-instated ${release.version}'
          : 'Yanked ${release.version}. It stays downloadable for clients that '
                'pinned it, but is no longer offered as an update.',
    );
    return 0;
  }
}

class _ReleaseDeleteCommand extends StoreCommand {
  @override
  final String name = 'delete';

  @override
  final String description = 'Delete a release and its artifacts. Prefer yank.';

  @override
  String get invocation => 'omnystore release delete <release-id>';

  _ReleaseDeleteCommand(super.context);

  @override
  Future<int> run() async {
    final ctx = await context;
    final rest = argResults!.rest;
    if (rest.isEmpty) {
      throw const CliException('Provide the release id.', exitCode: 64);
    }
    await ctx.store.deleteRelease(rest.first);
    ctx.info('Deleted release ${rest.first}');
    return 0;
  }
}

/// `omnystore asset` — artifact management.
class AssetCommand extends Command<int> {
  @override
  final String name = 'asset';

  @override
  final String description = 'Upload and manage release artifacts.';

  @override
  List<String> get aliases => const ['assets'];

  /// Creates the command group.
  AssetCommand(Future<CliContext> Function() context) {
    addSubcommand(_AssetUploadCommand(context));
    addSubcommand(_AssetListCommand(context));
    addSubcommand(_AssetDeleteCommand(context));
  }
}

class _AssetUploadCommand extends StoreCommand {
  @override
  final String name = 'upload';

  @override
  final String description = 'Attach a file to a release.';

  @override
  String get invocation =>
      'omnystore asset upload --release <id> --file <path>';

  _AssetUploadCommand(super.context) {
    argParser
      ..addOption('release', abbr: 'r', help: 'Release id.')
      ..addOption(
        'package',
        abbr: 'p',
        help: 'Package, when identifying the release by version.',
      )
      ..addOption(
        'version',
        help: 'Release version, as an alternative to --release.',
      )
      ..addOption('file', abbr: 'f', help: 'File to upload.')
      ..addOption('name', help: 'Asset name (defaults to the file name).')
      ..addOption('platform', help: 'Target platform, e.g. linux-x64.')
      ..addOption('kind', help: 'installer, archive, checksums, signature…')
      ..addOption('content-type', help: 'MIME type.')
      ..addFlag(
        'verify',
        help:
            'Compute the file checksum locally and require the server to '
            'agree, so a corrupted upload fails instead of being published.',
        defaultsTo: true,
      )
      ..addMultiOption('metadata', help: 'Extra key=value pairs.');
  }

  @override
  Future<int> run() async {
    final ctx = await context;
    final path = require('file');
    final file = File(path);
    if (!await file.exists()) {
      throw CliException('File not found: $path', exitCode: 66);
    }

    final releaseId = await _resolveReleaseId(ctx);
    final length = await file.length();

    // Hashing the file first costs one extra read and turns a silently
    // corrupted upload into a hard failure, which is the trade a release
    // pipeline wants.
    String? expected;
    if (flag('verify')) {
      expected = await DownloadManager().checksumOf(path);
    }

    final asset = await ctx.store.attachAsset(
      releaseId: releaseId,
      name: optional('name') ?? p.basename(path),
      data: file.openRead(),
      length: length,
      contentType: optional('content-type') ?? 'application/octet-stream',
      expectedSha256: expected,
      platform: optional('platform'),
      kind: optional('kind'),
      metadata: metadata(),
    );

    ctx.writeOne(
      asset,
      'Uploaded ${asset.name} (${asset.sizeBytes} bytes, '
      'sha256 ${asset.sha256})',
    );
    return 0;
  }

  Future<String> _resolveReleaseId(CliContext ctx) async {
    final direct = optional('release');
    final version = optional('version');
    if (direct != null && version == null) return direct;

    if (version != null) {
      final packageRef = optional('package');
      if (packageRef == null) {
        throw const CliException(
          'Identifying a release by --version also needs --package.',
          exitCode: 64,
        );
      }
      final release = await ctx.store.releaseByVersion(
        packageRef,
        Versions.parse(version),
      );
      if (release == null) {
        throw ReleaseNotFoundException('$packageRef@$version');
      }
      return release.id;
    }

    throw const CliException(
      'Provide --release <id>, or --package and --version.',
      exitCode: 64,
    );
  }
}

class _AssetListCommand extends StoreCommand {
  @override
  final String name = 'list';

  @override
  final String description = 'List a release\'s artifacts.';

  @override
  String get invocation => 'omnystore asset list --release <id>';

  _AssetListCommand(super.context) {
    argParser
      ..addOption('release', abbr: 'r', help: 'Release id.')
      ..addOption('package', abbr: 'p', help: 'Package, with --version.')
      ..addOption('version', help: 'Release version.');
  }

  @override
  Future<int> run() async {
    final ctx = await context;
    var releaseId = optional('release');
    if (releaseId == null) {
      final packageRef = optional('package');
      final version = optional('version');
      if (packageRef == null || version == null) {
        throw const CliException(
          'Provide --release <id>, or --package and --version.',
          exitCode: 64,
        );
      }
      final release = await ctx.store.releaseByVersion(
        packageRef,
        Versions.parse(version),
      );
      if (release == null) {
        throw ReleaseNotFoundException('$packageRef@$version');
      }
      releaseId = release.id;
    }

    final assets = await ctx.store.listAssets(releaseId);
    ctx.writeTable(
      assets,
      headers: ['NAME', 'PLATFORM', 'SIZE', 'DOWNLOADS', 'SHA256', 'ID'],
      rows: [
        for (final a in assets)
          [
            a.name,
            a.platform ?? '-',
            '${a.sizeBytes}',
            '${a.downloadCount}',
            a.sha256.length > 12 ? '${a.sha256.substring(0, 12)}…' : a.sha256,
            a.id,
          ],
      ],
      emptyMessage: 'No artifacts attached.',
    );
    return 0;
  }
}

class _AssetDeleteCommand extends StoreCommand {
  @override
  final String name = 'delete';

  @override
  final String description = 'Delete an artifact and its bytes.';

  @override
  String get invocation => 'omnystore asset delete <asset-id>';

  _AssetDeleteCommand(super.context);

  @override
  Future<int> run() async {
    final ctx = await context;
    final rest = argResults!.rest;
    if (rest.isEmpty) {
      throw const CliException('Provide the asset id.', exitCode: 64);
    }
    await ctx.store.deleteAsset(rest.first);
    ctx.info('Deleted asset ${rest.first}');
    return 0;
  }
}

/// `omnystore download` — fetch an artifact, verified.
class DownloadCommand extends StoreCommand {
  @override
  final String name = 'download';

  @override
  final String description =
      'Download a release artifact, verifying its checksum.';

  @override
  String get invocation =>
      'omnystore download --package <pkg> [--version 1.2.0] [--platform linux-x64]';

  /// Creates the command.
  DownloadCommand(super.context) {
    argParser
      ..addOption('package', abbr: 'p', help: 'Package name or id.')
      ..addOption(
        'version',
        help: 'Version to fetch. Defaults to the latest on --channel.',
      )
      ..addOption(
        'channel',
        abbr: 'c',
        help: 'Channel to take the latest from.',
        allowed: ['dev', 'beta', 'release'],
      )
      ..addOption(
        'platform',
        help:
            'Platform to pick an artifact for. Defaults to this machine '
            '(${Platforms.current}); pass "any" to choose from every artifact.',
      )
      ..addOption('asset', abbr: 'a', help: 'Asset id or name to fetch.')
      ..addOption(
        'output',
        abbr: 'o',
        help: 'Destination file or directory.',
        defaultsTo: '.',
      );
  }

  @override
  Future<int> run() async {
    final ctx = await context;
    final asset = await _resolveAsset(ctx);

    final destination = await Directory(optional('output') ?? '.').exists()
        ? p.join(optional('output') ?? '.', asset.name)
        : (optional('output') ?? asset.name);

    // A local registry has no URL to fetch from, but the bytes are right
    // there: copy them out and verify, rather than turning a reasonable
    // command into a dead end.
    if (ctx.store is! OmnyStoreClient) {
      return _copyOut(ctx, asset, destination);
    }

    final target = await ctx.store.downloadTarget(asset.id);
    final manager = DownloadManager();
    try {
      final url = switch (target) {
        RedirectDownload(:final url) => url,
        // A store that cannot issue a URL is reached through its own download
        // endpoint, which every deployment exposes.
        StreamedDownload() => _serverDownloadUrl(ctx, asset.id),
      };

      final result = await manager.downloadToFile(
        url: url,
        destination: destination,
        expectedSha256: asset.sha256.isEmpty ? null : asset.sha256,
        expectedSize: asset.sizeBytes,
        onProgress: ctx.quiet
            ? null
            : (progress) {
                final percent = progress.percent;
                if (percent != null) {
                  ctx.err.write('\rDownloading ${asset.name}: $percent%');
                }
              },
      );
      if (!ctx.quiet) ctx.err.writeln();

      ctx.info(
        result.wasCached
            ? '${result.file!.path} is already up to date (verified).'
            : 'Downloaded ${result.file!.path} '
                  '(${result.sizeBytes} bytes, sha256 verified).',
      );
      return 0;
    } finally {
      manager.close();
    }
  }

  /// Streams an artifact out of an embedded registry to [destination],
  /// verifying it against the digest on its record.
  ///
  /// The equivalent of the HTTP path for a `--data` registry, which has no URL
  /// to fetch from because the bytes never left this machine.
  Future<int> _copyOut(CliContext ctx, Asset asset, String destination) async {
    final file = File(destination);
    await file.parent.create(recursive: true);

    final download = await ctx.store.openAsset(asset.id);
    final digest = Sha256Accumulator();
    final sink = file.openWrite();
    try {
      await for (final chunk in download.stream) {
        digest.add(chunk);
        sink.add(chunk);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }

    final checksum = digest.finish();
    if (asset.sha256.isNotEmpty &&
        !Checksums.matches(asset.sha256, checksum.sha256)) {
      // Same guarantee as a network download: unverified bytes are deleted,
      // never left on disk for something else to pick up.
      await file.delete();
      throw ChecksumMismatchException(
        expected: asset.sha256.toLowerCase(),
        actual: checksum.sha256,
      );
    }

    ctx.info(
      'Copied ${file.path} (${checksum.sizeBytes} bytes, sha256 verified).',
    );
    return 0;
  }

  Future<dynamic> _resolveAsset(CliContext ctx) async {
    final assetRef = optional('asset');
    if (assetRef != null) {
      final byId = await ctx.store.asset(assetRef);
      if (byId != null) return byId;
    }

    final packageRef = require('package');
    final version = optional('version');
    final channel = optional('channel');

    final release = version != null
        ? await ctx.store.releaseByVersion(packageRef, Versions.parse(version))
        : channel != null
        ? await ctx.store.latestChannel(
            packageRef,
            ReleaseChannel.parse(channel),
          )
        : await ctx.store.latestRelease(packageRef);

    if (release == null) {
      throw ReleaseNotFoundException(
        '$packageRef@${version ?? channel ?? 'release'}',
      );
    }

    final assets = await ctx.store.listAssets(release.id);
    if (assets.isEmpty) {
      throw AssetNotFoundException('${release.version} has no artifacts');
    }

    final byName = assetRef == null
        ? null
        : assets.where((a) => a.name == assetRef).firstOrNull;
    if (byName != null) return byName;

    // Defaults to this machine. Downloading an artifact almost always means
    // "the one I can run", and making the common case explicit every time
    // invites the mistake of fetching a build for the wrong architecture.
    final requested = optional('platform') ?? Platforms.current;
    if (requested != 'any') {
      final match = assets
          .where(
            (a) =>
                a.platform != null && Platforms.matches(a.platform!, requested),
          )
          .firstOrNull;
      if (match != null) return match;

      // A portable artifact is the documented fallback when no
      // architecture-specific build matches — the same order the update
      // service uses.
      final portable = assets.where((a) => a.platform == null).toList();
      if (portable.length == 1) return portable.single;

      throw AssetNotFoundException(
        '${release.version} has no artifact for $requested '
        '(available: ${assets.map((a) => a.platform ?? 'any').join(', ')}). '
        'Pass --platform to choose another, or --platform any to pick by name.',
      );
    }

    if (assets.length > 1) {
      throw CliException(
        '${release.version} has ${assets.length} artifacts; choose one with '
        '--platform or --asset: ${assets.map((a) => a.name).join(', ')}',
        exitCode: 64,
      );
    }
    return assets.single;
  }

  /// The server's own download endpoint for [assetId].
  ///
  /// Only reachable in `--server` mode; a local `--data` registry has no HTTP
  /// endpoint, and its artifacts are already on this machine.
  Uri _serverDownloadUrl(CliContext ctx, String assetId) {
    final store = ctx.store;
    if (store is! OmnyStoreClient) {
      throw const CliException(
        'A local registry has no download URL. Its artifacts are already on '
        'this machine under <data>/objects, or run against a server with '
        '--server to download over HTTP.',
      );
    }
    return store.assetDownloadUrl(assetId);
  }
}

/// `omnystore check-update` — ask whether a newer version exists.
class CheckUpdateCommand extends StoreCommand {
  @override
  final String name = 'check-update';

  @override
  final String description =
      'Check whether a newer version of a package is available.';

  @override
  List<String> get aliases => const ['check-updates', 'update-check'];

  @override
  String get invocation =>
      'omnystore check-update --package <pkg> --current <version>';

  /// Creates the command.
  CheckUpdateCommand(super.context) {
    argParser
      ..addOption('package', abbr: 'p', help: 'Package name or id.')
      ..addOption('current', help: 'The version currently running.')
      ..addOption(
        'channel',
        abbr: 'c',
        help: 'Channel to check. Defaults to the package\'s own default.',
        allowed: ['dev', 'beta', 'release'],
      )
      ..addOption(
        'platform',
        help:
            'Platform to match an artifact for. Defaults to this machine '
            '(${Platforms.current}); pass "any" to ignore platform.',
      );
  }

  @override
  Future<int> run() async {
    final ctx = await context;
    final channel = optional('channel');

    final info = await ctx.store.checkForUpdates(
      packageReference: require('package'),
      currentVersion: Versions.parse(require('current')),
      channel: channel == null ? null : ReleaseChannel.parse(channel),
      // Defaults to this machine, so "is there an update" means "one I can
      // actually install" without the caller having to say so.
      platform: switch (optional('platform')) {
        'any' => null,
        final explicit? => explicit,
        null => Platforms.current,
      },
    );

    if (ctx.jsonOutput) {
      ctx.writeJson(info.toJson());
    } else if (!info.updateAvailable) {
      ctx.info(
        '${info.packageName} ${info.currentVersion} is up to date on the '
        '${info.channel.name} channel.',
      );
    } else {
      ctx.info(
        '${info.packageName} ${info.latestVersion} is available '
        '(you have ${info.currentVersion}, ${info.channel.name} channel).',
      );
      if (info.notes != null && info.notes!.isNotEmpty) {
        ctx.info('');
        ctx.info(info.notes!);
      }
      if (info.asset == null) {
        ctx.info('');
        ctx.info(
          'No artifact matches this platform, so there is nothing to install.',
        );
      }
    }

    // Exit codes let a shell script branch without parsing output: 0 = current,
    // 10 = an update is available. A non-zero code that is not an error needs
    // to be distinct from the 1 a real failure produces.
    return info.updateAvailable ? 10 : 0;
  }
}
