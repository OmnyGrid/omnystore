/// OmnyStore client SDK — **web-compatible**, for apps that talk to a remote
/// registry.
///
/// Nothing in this barrel imports `dart:io`, so it compiles to JavaScript and
/// runs unchanged on the Dart VM, in Flutter, and in a browser. The only
/// transport is `package:http`.
///
/// ```dart
/// final client = OmnyStoreClient(baseUrl: 'https://store.example.com');
///
/// final latest = await client.latestRelease('omnyagent');
///
/// final update = await client.checkForUpdates(
///   packageReference: 'omnyagent',
///   currentVersion: Version.parse('1.0.0'),
///   channel: ReleaseChannel.beta,
///   platform: 'macos-arm64',
/// );
/// if (update.isInstallable) {
///   final bytes = await client.downloadAsset(update.asset!.id);
/// }
/// ```
///
/// `OmnyStoreClient` implements the same [OmnyStoreApi] as the embedded
/// `OmnyStore`, and rebuilds the server's typed exceptions from the wire — so
/// code written against the interface runs embedded or remote without change,
/// and `on ReleaseNotFoundException` works either way.
///
/// On the Dart VM, `package:omnystore/omnystore.dart` adds the download manager
/// (streaming to disk, resume, checksum verification) and the storage backends.
library;

// Version.
export 'src/version.dart';

// Exceptions.
export 'src/exceptions/error_codes.dart';
export 'src/exceptions/omnystore_exception.dart';

// Web-safe utilities.
export 'src/utils/checksum.dart';
export 'src/utils/equality.dart';
export 'src/utils/http_dates.dart';
export 'src/utils/json.dart';
export 'src/utils/names.dart';
export 'src/utils/version_codec.dart';

// Channels.
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

// Queries and the shared contract.
export 'src/repositories/release_query.dart';
export 'src/services/asset_download.dart';
export 'src/services/omnystore_api.dart';

// Byte ranges, shared by the API and the client.
export 'src/storage/object_storage.dart' show ByteRange;

// Authentication.
export 'src/auth/auth_provider.dart';

// The client itself.
export 'src/client/omnystore_client.dart';

// Updates.
export 'src/updates/update_checker.dart';
export 'src/updates/update_resolver.dart';

export 'package:pub_semver/pub_semver.dart' show Version, VersionConstraint;
