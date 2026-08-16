import 'dart:async';

import 'package:pub_semver/pub_semver.dart';

import '../channels/release_channel.dart';
import '../models/asset.dart';
import '../models/release.dart';
import '../models/update_info.dart';
import '../services/omnystore_api.dart';
import '../utils/version_codec.dart';
import 'update_resolver.dart';

/// The client-side update service: "am I running the newest build, and what
/// should I download if not?".
///
/// Wraps any [OmnyStoreApi] — an [OmnyStoreClient] talking to a remote
/// registry, or an embedded store — so an application asks the same question
/// the same way regardless of where the registry lives.
///
/// ```dart
/// final checker = UpdateChecker(
///   store: OmnyStoreClient(baseUrl: 'https://store.example.com'),
///   packageReference: 'omnyagent',
///   currentVersion: Version.parse(omnyAgentVersion),
///   channel: ReleaseChannel.beta,
///   platform: 'macos-arm64',
/// );
///
/// final update = await checker.checkForUpdates();
/// if (update.isInstallable) {
///   print('${update.latestVersion} is available: ${update.notes}');
/// }
/// ```
///
/// **Polling is built in and off by default.** [watch] emits an [UpdateInfo]
/// on an interval, suppressing repeats so a subscriber is notified once per
/// *new* version rather than on every poll. A failed poll is swallowed rather
/// than closing the stream: a background updater must survive the registry
/// being briefly unreachable, which over a long-running process it will be.
class UpdateChecker {
  /// The registry to ask.
  final OmnyStoreApi store;

  /// The package this checker tracks.
  final String packageReference;

  /// The version the application is currently running.
  final Version currentVersion;

  /// The channel to check, or `null` to use the package's own default.
  final ReleaseChannel? channel;

  /// The platform artifacts must match (`linux-x64`, `macos-arm64`), or `null`
  /// for a platform-independent package.
  final String? platform;

  /// Creates a checker.
  UpdateChecker({
    required this.store,
    required this.packageReference,
    required this.currentVersion,
    this.channel,
    this.platform,
  });

  /// Creates a checker whose [currentVersion] is parsed from a string.
  ///
  /// Convenience for the usual call site, where the running version is a
  /// generated constant. Throws [ValidationException] if it is not a valid
  /// semantic version.
  factory UpdateChecker.forVersion({
    required OmnyStoreApi store,
    required String packageReference,
    required String currentVersion,
    ReleaseChannel? channel,
    String? platform,
  }) => UpdateChecker(
    store: store,
    packageReference: packageReference,
    currentVersion: Versions.parse(currentVersion),
    channel: channel,
    platform: platform,
  );

  /// The newest version on the tracked channel, or `null` if there is none.
  Future<Version?> latestVersion() async => (await latestRelease())?.version;

  /// The newest release on the tracked channel, or `null`.
  Future<Release?> latestRelease() async {
    final target = channel;
    return target == null
        ? store.latestAny(packageReference)
        : store.latestChannel(packageReference, target);
  }

  /// The newest release on [target], regardless of this checker's channel.
  ///
  /// For an application offering the user a choice of channels: show what is
  /// on beta without switching the running configuration to it.
  Future<Release?> latestChannel(ReleaseChannel target) =>
      store.latestChannel(packageReference, target);

  /// Whether a newer version is available on the tracked channel.
  Future<bool> hasUpdate() async => (await checkForUpdates()).updateAvailable;

  /// The full update answer: whether one exists, which release, and the asset
  /// this platform should download.
  Future<UpdateInfo> checkForUpdates() => store.checkForUpdates(
    packageReference: packageReference,
    currentVersion: currentVersion,
    channel: channel,
    platform: platform,
  );

  /// The asset this platform should download for [release], or `null` if the
  /// release ships nothing installable here.
  ///
  /// Uses the same selection rule the server applies when answering
  /// `/updates`, so a client that resolves the asset itself and one that reads
  /// `UpdateInfo.asset` always agree.
  Future<Asset?> assetFor(Release release) async => UpdateResolver.selectAsset(
    await store.listAssets(release.id),
    platform: platform,
  );

  /// Emits an [UpdateInfo] every [interval], and once immediately.
  ///
  /// Only *changes* are emitted: while the answer stays the same the stream is
  /// silent, so a subscriber can drive a "restart to update" banner directly
  /// without deduplicating. Errors are swallowed — a background updater must
  /// not die because the registry was unreachable for one poll — and reported
  /// through [onError] when one is supplied.
  ///
  /// The polling stops when the subscription is cancelled.
  Stream<UpdateInfo> watch({
    Duration interval = const Duration(hours: 6),
    bool emitImmediately = true,
    void Function(Object error, StackTrace stackTrace)? onError,
  }) {
    late StreamController<UpdateInfo> controller;
    Timer? timer;
    UpdateInfo? last;
    var polling = false;

    Future<void> poll() async {
      // Skip rather than queue: a slow registry must not build a backlog of
      // checks that then all fire at once.
      if (polling || controller.isClosed) return;
      polling = true;
      try {
        final info = await checkForUpdates();
        if (controller.isClosed) return;
        if (last == null ||
            last!.latestVersion != info.latestVersion ||
            last!.updateAvailable != info.updateAvailable) {
          last = info;
          controller.add(info);
        }
      } on Object catch (e, stackTrace) {
        onError?.call(e, stackTrace);
      } finally {
        polling = false;
      }
    }

    controller = StreamController<UpdateInfo>(
      onListen: () {
        if (emitImmediately) unawaited(poll());
        timer = Timer.periodic(interval, (_) => unawaited(poll()));
      },
      onCancel: () {
        timer?.cancel();
        timer = null;
      },
    );
    return controller.stream;
  }
}
