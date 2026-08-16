import '../models/asset.dart';
import '../storage/object_storage.dart';

/// An open read of an asset's bytes, whichever provider ended up serving them.
///
/// Returned by `OmnyStoreApi.openAsset`. The stream is live and consumable
/// once; nothing buffers the artifact, so a 4 GB installer flows from the
/// object store to the client without ever being held in the server's heap.
class AssetDownload {
  /// The asset record these bytes belong to.
  final Asset asset;

  /// The bytes, covering [range] when one was requested.
  final Stream<List<int>> stream;

  /// How many bytes [stream] will yield.
  final int length;

  /// The range being served, or `null` for the whole asset.
  final ByteRange? range;

  /// The id of the provider (hub or node) serving the bytes, for download
  /// records and for diagnosing a slow replica.
  final String? providerId;

  /// Creates a download.
  const AssetDownload({
    required this.asset,
    required this.stream,
    required this.length,
    this.range,
    this.providerId,
  });

  /// Whether this covers only part of the asset — the caller must answer
  /// `206 Partial Content` rather than `200`.
  bool get isPartial => range != null && length != asset.sizeBytes;

  /// The `content-type` to serve these bytes with.
  String get contentType => asset.contentType;

  @override
  String toString() =>
      'AssetDownload(${asset.name}, $length bytes'
      '${providerId == null ? '' : ' from $providerId'})';
}

/// Where a client should go to fetch an asset.
///
/// The registry answers a download request with one of these rather than always
/// streaming, because who carries the bytes is the single biggest performance
/// decision in a distribution platform. A [RedirectDownload] costs the hub one
/// small response; a [StreamedDownload] costs it the whole artifact's
/// bandwidth.
sealed class DownloadTarget {
  const DownloadTarget();
}

/// The client should follow [url] — a presigned bucket URL, or a signed URL at
/// the node that holds the bytes.
///
/// The URL is time-limited and carries its own authorisation, so it can be
/// handed to a browser or `curl` with no credentials.
class RedirectDownload extends DownloadTarget {
  /// Where to fetch the bytes.
  final Uri url;

  /// When the URL stops working (UTC).
  final DateTime expiresAt;

  /// The provider that issued it.
  final String providerId;

  /// Creates a redirect target.
  const RedirectDownload({
    required this.url,
    required this.expiresAt,
    required this.providerId,
  });

  @override
  String toString() => 'RedirectDownload($url, expires $expiresAt)';
}

/// No URL could be issued, so the caller must stream the bytes itself through
/// `OmnyStoreApi.openAsset`.
///
/// The case for a local-directory or in-memory backend, and for a node behind
/// NAT reachable only over its control channel.
class StreamedDownload extends DownloadTarget {
  /// The provider that will serve the bytes.
  final String providerId;

  /// Why a redirect was not possible, for logs and diagnostics.
  final String reason;

  /// Creates a streamed target.
  const StreamedDownload({required this.providerId, required this.reason});

  @override
  String toString() => 'StreamedDownload(via $providerId: $reason)';
}
