/// OmnyStore — a complete release management and software distribution
/// platform in pure Dart.
///
/// This is the core SDK barrel: the domain models, the channel and version
/// rules, the repository ports and their in-memory adapters, the pluggable
/// object-storage backends (local directory, AWS S3, Google Cloud Storage), the
/// [OmnyStore] service itself, the download manager and the update service.
///
/// ```dart
/// final store = OmnyStore(
///   repositories: MemoryRepositories(),
///   storage: LocalObjectStorage('/var/lib/omnystore'),
/// );
///
/// final release = await store.publishRelease(
///   packageReference: 'omnyagent',
///   version: Version.parse('1.2.0'),
/// );
/// await store.attachAsset(
///   releaseId: release.id,
///   name: 'omnyagent-linux-x64.tar.gz',
///   data: File('build/omnyagent-linux-x64.tar.gz').openRead(),
///   platform: 'linux-x64',
/// );
/// ```
///
/// Other entry points:
///
/// * `package:omnystore/omnystore_hub.dart` — the discovery hub that federates
///   storage nodes, and the REST API server built on OmnyHub.
/// * `package:omnystore/omnystore_node.dart` — a storage node that dials a hub
///   and serves its organizations' artifacts.
/// * `package:omnystore/omnystore_client.dart` — the web-compatible client SDK
///   (no `dart:io`).
/// * `package:omnystore/omnystore_cli.dart` — the `omnystore` command set.
library;

// Version.
export 'src/version.dart';

// Exceptions.
export 'src/exceptions/error_codes.dart';
export 'src/exceptions/omnystore_exception.dart';

// Utilities.
export 'src/utils/checksum.dart';
export 'src/utils/equality.dart';
export 'src/utils/http_dates.dart';
export 'src/utils/ids.dart';
export 'src/utils/json.dart';
export 'src/utils/names.dart';
export 'src/utils/platforms.dart';
export 'src/utils/version_codec.dart';

// Channels and versions.
export 'src/channels/release_channel.dart';

// Models.
export 'src/models/asset.dart';
export 'src/models/asset_location.dart';
export 'src/models/download_record.dart';
export 'src/models/organization.dart';
export 'src/models/package.dart';
export 'src/models/project.dart';
export 'src/models/provider_descriptor.dart';
export 'src/models/release.dart';
export 'src/models/update_info.dart';

// Repositories.
export 'src/repositories/file/json_file_repositories.dart';
export 'src/repositories/memory/memory_repositories.dart';
export 'src/repositories/release_query.dart';
export 'src/repositories/repositories.dart';

// Object storage.
export 'src/storage/gcs/gcp_credentials.dart';
export 'src/storage/gcs/gcs_object_storage.dart';
export 'src/storage/local_object_storage.dart';
export 'src/storage/memory_object_storage.dart';
export 'src/storage/object_storage.dart';
export 'src/storage/s3/aws_credentials.dart';
export 'src/storage/s3/s3_object_storage.dart';
export 'src/storage/s3/sig_v4.dart';

// Services.
export 'src/services/asset_download.dart';
export 'src/services/omnystore.dart';
export 'src/services/omnystore_api.dart';

// Downloads (VM/Flutter only — uses `dart:io`).
export 'src/downloads/download_manager.dart';

// Updates.
export 'src/updates/update_checker.dart';
export 'src/updates/update_resolver.dart';

// Authentication (client-side credentials).
export 'src/auth/auth_provider.dart';

// The client SDK, so an embedded application can talk to a remote registry
// without a second import.
export 'src/client/omnystore_client.dart';

// Re-exported so callers need no second import for the primitives OmnyStore's
// own API is expressed in.
export 'package:pub_semver/pub_semver.dart' show Version, VersionConstraint;
export 'package:omnyhub/omnyhub.dart'
    show
        Clock,
        IdGenerator,
        Logger,
        LogLevel,
        NoopLogger,
        Principal,
        RandomIdGenerator,
        StructuredLogger,
        SystemClock;
