import 'package:omnystore/omnystore_hub.dart';
import 'package:test/test.dart';

import '../../support/harness.dart';

/// A provider with a fixed descriptor over a throwaway store.
StoreProvider providerFor(
  String id, {
  Set<String> organizations = const {},
  bool servesAll = false,
  int priority = 0,
  ProviderStatus status = ProviderStatus.online,
  Map<String, String> labels = const {},
  int? capacityBytes,
  int? usedBytes,
}) => LocalStoreProvider(
  TestStore(idScope: id).store,
  descriptor: ProviderDescriptor(
    id: id,
    kind: ProviderKind.node,
    organizations: organizations,
    servesAll: servesAll,
    priority: priority,
    status: status,
    labels: labels,
    capacityBytes: capacityBytes,
    usedBytes: usedBytes,
  ),
);

void main() {
  late ProviderRegistry registry;

  setUp(() => registry = ProviderRegistry());
  tearDown(() => registry.close());

  group('membership', () {
    test('registers, finds and removes providers', () {
      final node = providerFor('node-a', organizations: {'acme'});
      registry.register(node);

      expect(registry.length, 1);
      expect(registry.byId('node-a'), same(node));
      expect(registry.requireById('node-a'), same(node));
      expect(registry.remove('node-a'), isTrue);
      expect(registry.byId('node-a'), isNull);
      expect(registry.remove('node-a'), isFalse);
    });

    test('re-admits a reconnecting node under the same id', () {
      // Refusing a reconnect would strand the node's organizations until the
      // stale entry timed out.
      registry.register(providerFor('node-a', organizations: {'acme'}));
      final reconnected = providerFor('node-a', organizations: {'acme'});
      registry.register(reconnected);

      expect(registry.length, 1);
      expect(registry.byId('node-a'), same(reconnected));
    });

    test('reports an unknown id as a validation failure', () {
      expect(
        () => registry.requireById('ghost'),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.field,
            'field',
            'providerId',
          ),
        ),
      );
    });

    test('emits membership events', () async {
      final events = <ProviderEvent>[];
      registry.events.listen(events.add);

      registry.register(providerFor('node-a', organizations: {'acme'}));
      registry.register(providerFor('node-a', organizations: {'acme'}));
      registry.remove('node-a');
      await Future<void>.delayed(Duration.zero);

      expect(events.map((e) => e.kind), [
        ProviderEventKind.registered,
        ProviderEventKind.updated,
        ProviderEventKind.removed,
      ]);
    });

    test('lists descriptors and bound organizations', () {
      registry
        ..register(providerFor('node-a', organizations: {'acme', 'globex'}))
        ..register(providerFor('node-b', organizations: {'acme'}))
        ..register(providerFor('hub', servesAll: true));

      expect(registry.descriptors.map((d) => d.id), [
        'hub',
        'node-a',
        'node-b',
      ]);
      // A catch-all contributes nothing: it serves organizations it has never
      // been told about, so there is no finite set to report.
      expect(registry.boundOrganizations, ['acme', 'globex']);
    });
  });

  group('routing', () {
    setUp(() {
      registry
        ..register(
          providerFor('node-eu', organizations: {'acme'}, priority: 10),
        )
        ..register(providerFor('node-us', organizations: {'acme'}, priority: 1))
        ..register(providerFor('node-gx', organizations: {'globex'}))
        ..register(providerFor('hub-local', servesAll: true, priority: -100));
    });

    test('prefers organization-specific providers over the catch-all', () {
      expect(registry.providersFor('acme').map((p) => p.id), [
        'node-eu',
        'node-us',
        'hub-local',
      ]);
    });

    test('falls back to the catch-all for an unclaimed organization', () {
      expect(registry.providersFor('initech').map((p) => p.id), ['hub-local']);
    });

    test('sends a write to the highest-priority eligible provider', () {
      expect(registry.primaryFor('acme').id, 'node-eu');
      expect(registry.primaryFor('globex').id, 'node-gx');
      expect(registry.primaryFor('initech').id, 'hub-local');
    });

    test('an organization can be served by several nodes', () {
      expect(registry.providersFor('acme'), hasLength(3));
    });

    test('a node can serve several organizations', () {
      registry.register(
        providerFor('node-multi', organizations: {'a', 'b', 'c'}),
      );

      for (final organization in ['a', 'b', 'c']) {
        expect(
          registry.providersFor(organization).map((p) => p.id),
          contains('node-multi'),
        );
      }
    });

    test('breaks a priority tie on free space, then on id', () {
      final tie = ProviderRegistry();
      addTearDown(tie.close);
      tie
        ..register(
          providerFor(
            'node-b',
            organizations: {'acme'},
            capacityBytes: 100,
            usedBytes: 10,
          ),
        )
        ..register(
          providerFor(
            'node-a',
            organizations: {'acme'},
            capacityBytes: 100,
            usedBytes: 90,
          ),
        );

      // Placement must never depend on registration order.
      expect(tie.providersFor('acme').map((p) => p.id), ['node-b', 'node-a']);
    });

    test('filters by placement labels', () {
      final labelled = ProviderRegistry();
      addTearDown(labelled.close);
      labelled
        ..register(
          providerFor('eu', organizations: {'acme'}, labels: {'region': 'eu'}),
        )
        ..register(
          providerFor('us', organizations: {'acme'}, labels: {'region': 'us'}),
        );

      expect(
        labelled
            .providersFor('acme', labels: {'region': 'eu'})
            .map((p) => p.id),
        ['eu'],
      );
      expect(labelled.primaryFor('acme', labels: {'region': 'us'}).id, 'us');
    });
  });

  group('provider state', () {
    test('a draining provider serves reads but takes no writes', () {
      registry.register(
        providerFor(
          'node-a',
          organizations: {'acme'},
          status: ProviderStatus.draining,
        ),
      );

      expect(registry.providersFor('acme').map((p) => p.id), ['node-a']);
      expect(registry.providersFor('acme', writable: true), isEmpty);
      expect(
        () => registry.primaryFor('acme'),
        throwsA(
          isA<StorageException>().having(
            (e) => e.message,
            'message',
            contains('draining'),
          ),
        ),
      );
    });

    test('an offline provider is excluded from reads too', () {
      registry.register(
        providerFor(
          'node-a',
          organizations: {'acme'},
          status: ProviderStatus.offline,
        ),
      );

      expect(registry.providersFor('acme'), isEmpty);
      expect(registry.readable, isEmpty);
    });

    test('explains what to do when nothing serves an organization', () {
      expect(
        () => registry.primaryFor('acme'),
        throwsA(
          isA<StorageException>().having(
            (e) => e.message,
            'message',
            allOf(contains('acme'), contains('Attach a node')),
          ),
        ),
      );
    });
  });

  group('hub-side bindings', () {
    test('binds an organization to a provider that did not declare it', () {
      registry.register(providerFor('node-a'));

      expect(registry.providersFor('acme'), isEmpty);
      registry.bind('acme', 'node-a');

      expect(registry.providersFor('acme').map((p) => p.id), ['node-a']);
      expect(registry.serves('node-a', 'acme'), isTrue);
      expect(registry.boundOrganizations, ['acme']);
    });

    test('unbinds only what the hub added', () {
      registry.register(providerFor('node-a', organizations: {'declared'}));
      registry.bind('bound', 'node-a');

      expect(registry.unbind('bound', 'node-a'), isTrue);
      expect(registry.providersFor('bound'), isEmpty);

      // The node's own declaration is its statement about what it is storing;
      // the hub overriding it would make real data unreachable.
      expect(registry.unbind('declared', 'node-a'), isFalse);
      expect(registry.providersFor('declared').map((p) => p.id), ['node-a']);
    });

    test('rejects binding to an unknown provider', () {
      expect(
        () => registry.bind('acme', 'ghost'),
        throwsA(isA<ValidationException>()),
      );
    });

    test('forgets bindings when the provider is removed', () {
      registry.register(providerFor('node-a'));
      registry.bind('acme', 'node-a');
      registry.remove('node-a');

      expect(registry.serves('node-a', 'acme'), isFalse);
      expect(registry.boundOrganizations, isEmpty);
    });
  });

  group('ProviderDescriptor', () {
    test('reports free space and room, treating unknown as available', () {
      final unknown = ProviderDescriptor(id: 'a');
      expect(unknown.freeBytes, isNull);
      // An unreported limit is not a limit of zero — refusing to place there
      // would make the common case (a directory on a big disk) unusable.
      expect(unknown.hasRoomFor(1 << 40), isTrue);

      final bounded = ProviderDescriptor(
        id: 'b',
        capacityBytes: 100,
        usedBytes: 90,
      );
      expect(bounded.freeBytes, 10);
      expect(bounded.hasRoomFor(10), isTrue);
      expect(bounded.hasRoomFor(11), isFalse);
    });

    test('never reports negative free space', () {
      final over = ProviderDescriptor(
        id: 'a',
        capacityBytes: 100,
        usedBytes: 150,
      );
      expect(over.freeBytes, 0);
      expect(over.hasRoomFor(1), isFalse);
    });

    test('serves matches explicit organizations and catch-alls', () {
      final specific = ProviderDescriptor(id: 'a', organizations: {'acme'});
      final catchAll = ProviderDescriptor(id: 'b', servesAll: true);

      expect(specific.serves('acme'), isTrue);
      expect(specific.serves('globex'), isFalse);
      expect(catchAll.serves('anything'), isTrue);
    });

    test('has value equality across a JSON round-trip', () {
      final descriptor = ProviderDescriptor(
        id: 'node-eu',
        kind: ProviderKind.node,
        organizations: {'acme', 'globex'},
        dataPlane: DataPlaneMode.presigned,
        baseUrl: 'https://eu.example.com',
        labels: {'region': 'eu'},
        priority: 10,
        capacityBytes: 1000,
        usedBytes: 100,
        agentVersion: '1.0.0',
        status: ProviderStatus.draining,
        lastSeenAt: DateTime.utc(2026),
        metadata: {'a': 'b'},
      );

      expect(ProviderDescriptor.fromJson(descriptor.toJson()), descriptor);
      expect(
        ProviderDescriptor.fromJson(descriptor.toJson()).hashCode,
        descriptor.hashCode,
      );
    });
  });
}
