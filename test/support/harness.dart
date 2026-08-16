import 'dart:convert';
import 'dart:io';

import 'package:omnystore/omnystore.dart';

/// A [Clock] fixed at a chosen instant, advanced explicitly.
///
/// Every timestamp the store writes comes from the injected clock, so fixing it
/// makes `createdAt`/`publishedAt` assertions exact rather than approximate,
/// and makes "newer than" tests deterministic instead of racing the wall clock.
class FixedClock implements Clock {
  DateTime _now;

  /// Creates a clock reading [start] (defaults to a fixed, arbitrary instant).
  FixedClock([DateTime? start])
    : _now = (start ?? DateTime.utc(2026, 1, 1, 12)).toUtc();

  @override
  DateTime now() => _now;

  /// Moves the clock forward by [duration].
  void advance(Duration duration) => _now = _now.add(duration);

  /// Sets the clock to [instant].
  void set(DateTime instant) => _now = instant.toUtc();
}

/// An [IdGenerator] producing `prefix-1`, `prefix-2`, … so test expectations
/// can name ids literally instead of capturing whatever random value appeared.
class SequentialIdGenerator implements IdGenerator {
  final Map<String, int> _counters = {};

  @override
  String next([String prefix = 'id']) {
    final next = (_counters[prefix] ?? 0) + 1;
    _counters[prefix] = next;
    return prefix.isEmpty ? '$next' : '$prefix-$next';
  }
}

/// A [Logger] that records every entry instead of writing it anywhere.
class RecordingLogger implements Logger {
  /// The records emitted, in order.
  final List<({LogLevel level, String message, Map<String, Object?> context})>
  records = [];

  final Map<String, Object?> _base;

  /// Creates a recording logger.
  RecordingLogger([this._base = const {}]);

  /// Messages logged at [level].
  List<String> messagesAt(LogLevel level) => [
    for (final record in records)
      if (record.level == level) record.message,
  ];

  @override
  void log(
    LogLevel level,
    String message, {
    Map<String, Object?> context = const {},
  }) => records.add((
    level: level,
    message: message,
    context: {..._base, ...context},
  ));

  @override
  void debug(String message, {Map<String, Object?> context = const {}}) =>
      log(LogLevel.debug, message, context: context);

  @override
  void info(String message, {Map<String, Object?> context = const {}}) =>
      log(LogLevel.info, message, context: context);

  @override
  void warn(String message, {Map<String, Object?> context = const {}}) =>
      log(LogLevel.warn, message, context: context);

  @override
  void error(String message, {Map<String, Object?> context = const {}}) =>
      log(LogLevel.error, message, context: context);

  @override
  Logger child(Map<String, Object?> context) =>
      RecordingLogger({..._base, ...context});
}

/// A ready-to-use [OmnyStore] over in-memory repositories and storage, with a
/// fixed clock and sequential ids.
///
/// The shape almost every test wants: deterministic, isolated, and exercising
/// exactly the same code paths a production store does.
class TestStore {
  /// The fixed clock driving every timestamp.
  final FixedClock clock;

  /// The deterministic id generator.
  final SequentialIdGenerator ids;

  /// The recorded log.
  final RecordingLogger logger;

  /// The in-memory object storage.
  final MemoryObjectStorage storage;

  /// The store under test.
  final OmnyStore store;

  TestStore._(this.clock, this.ids, this.logger, this.storage, this.store);

  /// Creates a store with fresh in-memory dependencies.
  ///
  /// [idScope] namespaces the generated ids. In a federation every store must
  /// mint globally unique ids — the hub caches which provider owns which id —
  /// so a fixture with several stores must scope them exactly as production
  /// does, or it would test a uniqueness property the real system does not
  /// have.
  factory TestStore({MemoryObjectStorage? storage, String? idScope}) {
    final clock = FixedClock();
    final ids = SequentialIdGenerator();
    final logger = RecordingLogger();
    final objects = storage ?? MemoryObjectStorage();
    return TestStore._(
      clock,
      ids,
      logger,
      objects,
      OmnyStore(
        repositories: MemoryRepositories(),
        storage: objects,
        clock: clock,
        idGenerator: idScope == null ? ids : ScopedIdGenerator(ids, idScope),
        logger: logger,
        providerId: idScope,
      ),
    );
  }

  /// Creates `acme` / `agent` / `omnyagent` and returns the package.
  ///
  /// The fixture nearly every release test starts from; spelled out once so
  /// the tests themselves are about releases rather than about setup.
  Future<Package> seedPackage({
    String organization = 'acme',
    String project = 'agent',
    String package = 'omnyagent',
    ReleaseChannel defaultChannel = ReleaseChannel.release,
    List<String> platforms = const [],
  }) async {
    final org = await store.createOrganization(name: organization);
    final proj = await store.createProject(
      organizationId: org.id,
      name: project,
    );
    return store.createPackage(
      projectId: proj.id,
      name: package,
      defaultChannel: defaultChannel,
      platforms: platforms,
    );
  }

  /// Publishes [version] of [packageReference], attaching [assets] as
  /// `name -> content` pairs.
  Future<Release> publish(
    String packageReference,
    String version, {
    Map<String, String> assets = const {},
    String? platform,
    String? notes,
    bool draft = false,
  }) async {
    final release = await store.publishRelease(
      packageReference: packageReference,
      version: Version.parse(version),
      notes: notes,
      draft: draft,
    );
    for (final entry in assets.entries) {
      await store.attachAsset(
        releaseId: release.id,
        name: entry.key,
        data: Stream.value(utf8.encode(entry.value)),
        platform: platform,
      );
    }
    return release;
  }

  /// Releases the store's resources.
  Future<void> close() => store.close();
}

/// Creates a temporary directory that is deleted when [body] finishes.
///
/// Used by the tests that exercise the local-directory storage backend against
/// a real filesystem rather than a stand-in.
Future<T> withTempDir<T>(Future<T> Function(Directory dir) body) async {
  final dir = await Directory.systemTemp.createTemp('omnystore_test_');
  try {
    return await body(dir);
  } finally {
    if (dir.existsSync()) {
      await dir.delete(recursive: true);
    }
  }
}

/// Collects [stream] into a UTF-8 string.
Future<String> readAsString(Stream<List<int>> stream) async =>
    utf8.decode(await readBytes(stream));

/// Collects [stream] into a byte list.
Future<List<int>> readBytes(Stream<List<int>> stream) async {
  final bytes = <int>[];
  await for (final chunk in stream) {
    bytes.addAll(chunk);
  }
  return bytes;
}
