import 'package:meta/meta.dart';

import '../channels/release_channel.dart';
import '../models/release.dart';

/// Filters and paging for a release listing.
///
/// Passed down into the repository rather than applied by the caller, so a
/// SQL-backed adapter can push the filter into the query instead of loading
/// every release of a package into memory to discard most of it. The in-memory
/// implementation applies the same semantics via [matches] and [apply], which
/// is also what keeps the two backends' behaviour identical.
@immutable
class ReleaseQuery {
  /// Only releases on this channel. `null` matches every channel.
  ///
  /// This is an *exact* channel match, not the inclusive-downward matching used
  /// for update checks — listing `beta` shows beta releases, not beta plus
  /// stable. Use [acceptedBy] for the update-service semantics.
  final ReleaseChannel? channel;

  /// Only releases a client subscribed to this channel would accept — that
  /// channel and every more stable one (see [ReleaseChannel.accepts]).
  final ReleaseChannel? acceptedBy;

  /// Whether to include drafts. Defaults to `false`.
  final bool includeDrafts;

  /// Whether to include yanked releases. Defaults to `false`.
  final bool includeYanked;

  /// Whether to include releases that have not been published yet. Defaults to
  /// `false`.
  final bool includeUnpublished;

  /// Maximum number of releases to return, or `null` for all of them.
  final int? limit;

  /// How many releases to skip, for paging.
  final int offset;

  /// Creates a query. The defaults describe "what a client should be offered":
  /// published, not draft, not yanked, every channel, newest first.
  const ReleaseQuery({
    this.channel,
    this.acceptedBy,
    this.includeDrafts = false,
    this.includeYanked = false,
    this.includeUnpublished = false,
    this.limit,
    this.offset = 0,
  });

  /// A query that returns every release, including drafts and yanked ones —
  /// the publisher's view, as opposed to the client's.
  static const ReleaseQuery all = ReleaseQuery(
    includeDrafts: true,
    includeYanked: true,
    includeUnpublished: true,
  );

  /// A query for the offerable releases on [channel] only.
  factory ReleaseQuery.onChannel(ReleaseChannel channel, {int? limit}) =>
      ReleaseQuery(channel: channel, limit: limit);

  /// A query for the releases a client on [channel] would accept — that
  /// channel and every more stable one.
  factory ReleaseQuery.acceptedBy(ReleaseChannel channel, {int? limit}) =>
      ReleaseQuery(acceptedBy: channel, limit: limit);

  /// Whether [release] satisfies this query's filters (paging aside).
  bool matches(Release release) {
    if (!includeDrafts && release.draft) return false;
    if (!includeYanked && release.yanked) return false;
    if (!includeUnpublished && release.publishedAt == null) return false;
    if (channel != null && release.channel != channel) return false;
    final accepted = acceptedBy;
    if (accepted != null && !accepted.accepts(release.channel)) return false;
    return true;
  }

  /// Filters, sorts (newest first) and pages [releases] according to this
  /// query.
  ///
  /// Sorting happens before paging, so `offset`/`limit` walk a stable
  /// newest-first sequence rather than whatever order the store yielded.
  List<Release> apply(Iterable<Release> releases) {
    final matched = releases.where(matches).toList()
      ..sort(Release.compareNewestFirst);
    if (offset >= matched.length) return const [];
    final from = offset;
    final to = limit == null
        ? matched.length
        : (from + limit!).clamp(from, matched.length);
    return matched.sublist(from, to);
  }

  /// Returns a copy with the given fields replaced.
  ReleaseQuery copyWith({
    ReleaseChannel? channel,
    ReleaseChannel? acceptedBy,
    bool? includeDrafts,
    bool? includeYanked,
    bool? includeUnpublished,
    int? limit,
    int? offset,
  }) => ReleaseQuery(
    channel: channel ?? this.channel,
    acceptedBy: acceptedBy ?? this.acceptedBy,
    includeDrafts: includeDrafts ?? this.includeDrafts,
    includeYanked: includeYanked ?? this.includeYanked,
    includeUnpublished: includeUnpublished ?? this.includeUnpublished,
    limit: limit ?? this.limit,
    offset: offset ?? this.offset,
  );

  /// Renders this query as URL query parameters, for the REST client.
  Map<String, String> toQueryParameters() => {
    if (channel != null) 'channel': channel!.name,
    if (acceptedBy != null) 'acceptedBy': acceptedBy!.name,
    if (includeDrafts) 'includeDrafts': 'true',
    if (includeYanked) 'includeYanked': 'true',
    if (includeUnpublished) 'includeUnpublished': 'true',
    if (limit != null) 'limit': '$limit',
    if (offset != 0) 'offset': '$offset',
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ReleaseQuery &&
          other.channel == channel &&
          other.acceptedBy == acceptedBy &&
          other.includeDrafts == includeDrafts &&
          other.includeYanked == includeYanked &&
          other.includeUnpublished == includeUnpublished &&
          other.limit == limit &&
          other.offset == offset;

  @override
  int get hashCode => Object.hash(
    channel,
    acceptedBy,
    includeDrafts,
    includeYanked,
    includeUnpublished,
    limit,
    offset,
  );

  @override
  String toString() =>
      'ReleaseQuery(channel: ${channel?.name}, acceptedBy: '
      '${acceptedBy?.name}, drafts: $includeDrafts, yanked: $includeYanked, '
      'limit: $limit, offset: $offset)';
}
