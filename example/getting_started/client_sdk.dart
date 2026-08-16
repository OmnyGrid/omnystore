import 'dart:convert';

import 'package:omnystore/omnystore_client.dart';

/// **4 — The client SDK against a remote registry.**
///
/// Nothing here imports `dart:io`, so this same code compiles to JavaScript and
/// runs in a browser. `OmnyStoreClient` implements the same [OmnyStoreApi] as
/// the embedded `OmnyStore`, so code written against the interface moves
/// between the two unchanged.
///
/// Start `example/getting_started/rest_api_server.dart` first, then:
///
/// ```sh
/// dart run example/getting_started/client_sdk.dart
/// ```
Future<void> main() async {
  final client = OmnyStoreClient(
    baseUrl: 'http://localhost:8080',
    auth: const TokenAuthProvider('ci-publish-token'),
  );

  try {
    final health = await client.health();
    print('Server ${health['version']} — API ${health['api']}');

    final organization =
        await client.organizationByName('acme') ??
        await client.createOrganization(name: 'acme');
    final project =
        await client.projectByName(organization.id, 'agent') ??
        await client.createProject(
          organizationId: organization.id,
          name: 'agent',
        );
    final package =
        await client.packageByName(project.id, 'omnyagent') ??
        await client.createPackage(projectId: project.id, name: 'omnyagent');

    final release = await client.publishRelease(
      packageReference: package.id,
      version: Version.parse('1.3.0'),
      notes: 'Published from the client SDK.',
    );

    final asset = await client.attachAsset(
      releaseId: release.id,
      name: 'omnyagent-linux-x64.tar.gz',
      data: Stream.value(utf8.encode('<artifact>')),
      platform: 'linux-x64',
    );
    print('Uploaded ${asset.name}, sha256 ${asset.sha256}');

    // Verified on arrival: bytes that do not match the recorded digest raise
    // rather than being handed back for the caller to maybe check.
    final bytes = await client.downloadAsset(asset.id);
    print('Downloaded and verified ${bytes.length} bytes');

    final latest = await client.latestRelease('omnyagent');
    print('latestRelease() => ${latest?.version}');
  } on PackageNotFoundException catch (e) {
    // The server's exception type survives the wire, so this catch works
    // exactly as it would against an embedded store.
    print('No such package: ${e.reference}');
  } on ApiException catch (e) {
    print('Cannot reach the registry: ${e.message}');
  } finally {
    await client.close();
  }
}
