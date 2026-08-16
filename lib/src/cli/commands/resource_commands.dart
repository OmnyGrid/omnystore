import 'package:args/command_runner.dart';

import '../../channels/release_channel.dart';
import '../../exceptions/omnystore_exception.dart';
import '../cli_context.dart';

/// A command that needs a resolved [CliContext].
///
/// The context is supplied by the runner rather than built per command, so a
/// single `--server`/`--data` decision applies to the whole invocation and
/// tests can drive commands against an in-memory store without a socket.
abstract class StoreCommand extends Command<int> {
  /// Supplies the resolved context.
  final Future<CliContext> Function() contextFactory;

  /// Creates a command over [contextFactory].
  StoreCommand(this.contextFactory);

  /// The resolved context, memoised for the command's lifetime.
  Future<CliContext> get context async => _context ??= await contextFactory();
  CliContext? _context;

  /// Reads a required option, raising a usage error when absent.
  String require(String name) {
    final value = argResults?.option(name);
    if (value == null || value.isEmpty) {
      throw CliException(
        "Missing required option --$name. Run 'omnystore $invocation' for "
        'usage.',
        exitCode: 64,
      );
    }
    return value;
  }

  /// Reads an optional option.
  String? optional(String name) {
    final value = argResults?.option(name);
    return value == null || value.isEmpty ? null : value;
  }

  /// Reads a flag.
  bool flag(String name) => argResults?.flag(name) ?? false;

  /// Reads a repeatable option, with blanks dropped.
  ///
  /// A blank arrives from `--platform ''` or from a trailing comma in
  /// `--platform linux-x64,`, neither of which should become a selector that
  /// matches nothing.
  List<String> multi(String name) => [
    for (final value in argResults?.multiOption(name) ?? const <String>[])
      if (value.trim().isNotEmpty) value.trim(),
  ];

  /// Parses repeated `--metadata key=value` options into a map.
  Map<String, String> metadata([String name = 'metadata']) {
    final entries = argResults?.multiOption(name) ?? const <String>[];
    final result = <String, String>{};
    for (final entry in entries) {
      final index = entry.indexOf('=');
      if (index <= 0) {
        throw CliException(
          "Invalid --$name '$entry': expected key=value.",
          exitCode: 64,
        );
      }
      result[entry.substring(0, index)] = entry.substring(index + 1);
    }
    return result;
  }
}

/// `omnystore org` — organization management.
class OrgCommand extends Command<int> {
  @override
  final String name = 'org';

  @override
  final String description = 'Manage organizations.';

  @override
  List<String> get aliases => const ['organization', 'orgs'];

  /// Creates the command group.
  OrgCommand(Future<CliContext> Function() context) {
    addSubcommand(_OrgCreateCommand(context));
    addSubcommand(_OrgListCommand(context));
    addSubcommand(_OrgDeleteCommand(context));
  }
}

class _OrgCreateCommand extends StoreCommand {
  @override
  final String name = 'create';

  @override
  final String description = 'Create an organization.';

  @override
  String get invocation => 'omnystore org create <name>';

  _OrgCreateCommand(super.context) {
    argParser
      ..addOption('display-name', help: 'Human-friendly name.')
      ..addOption('description', help: 'Free-text description.')
      ..addOption('website', help: 'Homepage URL.')
      ..addMultiOption('metadata', help: 'Extra key=value pairs.');
  }

  @override
  Future<int> run() async {
    final ctx = await context;
    final rest = argResults!.rest;
    if (rest.isEmpty) {
      throw const CliException(
        'Provide the organization name: omnystore org create acme',
        exitCode: 64,
      );
    }
    final organization = await ctx.store.createOrganization(
      name: rest.first,
      displayName: optional('display-name'),
      description: optional('description'),
      website: optional('website'),
      metadata: metadata(),
    );
    ctx.writeOne(
      organization,
      'Created organization ${organization.name} (${organization.id})',
    );
    return 0;
  }
}

class _OrgListCommand extends StoreCommand {
  @override
  final String name = 'list';

  @override
  final String description = 'List organizations.';

  _OrgListCommand(super.context);

  @override
  Future<int> run() async {
    final ctx = await context;
    final organizations = await ctx.store.listOrganizations();
    ctx.writeTable(
      organizations,
      headers: ['NAME', 'DISPLAY NAME', 'ID'],
      rows: [
        for (final o in organizations) [o.name, o.displayName, o.id],
      ],
      emptyMessage: 'No organizations yet.',
    );
    return 0;
  }
}

class _OrgDeleteCommand extends StoreCommand {
  @override
  final String name = 'delete';

  @override
  final String description = 'Delete an organization.';

  @override
  String get invocation => 'omnystore org delete <name-or-id>';

  _OrgDeleteCommand(super.context) {
    argParser.addFlag(
      'force',
      help: 'Delete its projects, packages, releases and artifacts too.',
      negatable: false,
    );
  }

  @override
  Future<int> run() async {
    final ctx = await context;
    final rest = argResults!.rest;
    if (rest.isEmpty) {
      throw const CliException(
        'Provide the organization to delete.',
        exitCode: 64,
      );
    }
    final organization =
        await ctx.store.organizationByName(rest.first) ??
        await ctx.store.organization(rest.first);
    if (organization == null) throw OrganizationNotFoundException(rest.first);

    await ctx.store.deleteOrganization(organization.id, force: flag('force'));
    ctx.info('Deleted organization ${organization.name}');
    return 0;
  }
}

/// `omnystore project` — project management.
class ProjectCommand extends Command<int> {
  @override
  final String name = 'project';

  @override
  final String description = 'Manage projects.';

  @override
  List<String> get aliases => const ['projects'];

  /// Creates the command group.
  ProjectCommand(Future<CliContext> Function() context) {
    addSubcommand(_ProjectCreateCommand(context));
    addSubcommand(_ProjectListCommand(context));
    addSubcommand(_ProjectDeleteCommand(context));
  }
}

class _ProjectCreateCommand extends StoreCommand {
  @override
  final String name = 'create';

  @override
  final String description = 'Create a project within an organization.';

  @override
  String get invocation => 'omnystore project create <name> --org <org>';

  _ProjectCreateCommand(super.context) {
    argParser
      ..addOption('org', abbr: 'o', help: 'Owning organization name or id.')
      ..addOption('display-name', help: 'Human-friendly name.')
      ..addOption('description', help: 'Free-text description.')
      ..addOption('repository', help: 'Source repository URL.')
      ..addOption('website', help: 'Homepage URL.')
      ..addMultiOption('metadata', help: 'Extra key=value pairs.');
  }

  @override
  Future<int> run() async {
    final ctx = await context;
    final rest = argResults!.rest;
    if (rest.isEmpty) {
      throw const CliException('Provide the project name.', exitCode: 64);
    }
    final orgRef = require('org');
    final organization =
        await ctx.store.organizationByName(orgRef) ??
        await ctx.store.organization(orgRef);
    if (organization == null) throw OrganizationNotFoundException(orgRef);

    final project = await ctx.store.createProject(
      organizationId: organization.id,
      name: rest.first,
      displayName: optional('display-name'),
      description: optional('description'),
      repository: optional('repository'),
      website: optional('website'),
      metadata: metadata(),
    );
    ctx.writeOne(
      project,
      'Created project ${organization.name}/${project.name} (${project.id})',
    );
    return 0;
  }
}

class _ProjectListCommand extends StoreCommand {
  @override
  final String name = 'list';

  @override
  final String description = 'List projects.';

  _ProjectListCommand(super.context) {
    argParser.addOption(
      'org',
      abbr: 'o',
      help: 'Only projects of this organization.',
    );
  }

  @override
  Future<int> run() async {
    final ctx = await context;
    final orgRef = optional('org');
    String? organizationId;
    if (orgRef != null) {
      final organization =
          await ctx.store.organizationByName(orgRef) ??
          await ctx.store.organization(orgRef);
      if (organization == null) throw OrganizationNotFoundException(orgRef);
      organizationId = organization.id;
    }

    final projects = await ctx.store.listProjects(
      organizationId: organizationId,
    );
    ctx.writeTable(
      projects,
      headers: ['NAME', 'ORGANIZATION', 'ID'],
      rows: [
        for (final p in projects) [p.name, p.organizationId, p.id],
      ],
      emptyMessage: 'No projects yet.',
    );
    return 0;
  }
}

class _ProjectDeleteCommand extends StoreCommand {
  @override
  final String name = 'delete';

  @override
  final String description = 'Delete a project.';

  @override
  String get invocation => 'omnystore project delete <id>';

  _ProjectDeleteCommand(super.context) {
    argParser.addFlag(
      'force',
      help: 'Delete its packages and releases too.',
      negatable: false,
    );
  }

  @override
  Future<int> run() async {
    final ctx = await context;
    final rest = argResults!.rest;
    if (rest.isEmpty) {
      throw const CliException('Provide the project id.', exitCode: 64);
    }
    await ctx.store.deleteProject(rest.first, force: flag('force'));
    ctx.info('Deleted project ${rest.first}');
    return 0;
  }
}

/// `omnystore package` — package management.
class PackageCommand extends Command<int> {
  @override
  final String name = 'package';

  @override
  final String description = 'Manage packages.';

  @override
  List<String> get aliases => const ['packages', 'pkg'];

  /// Creates the command group.
  PackageCommand(Future<CliContext> Function() context) {
    addSubcommand(_PackageCreateCommand(context));
    addSubcommand(_PackageListCommand(context));
    addSubcommand(_PackageDeleteCommand(context));
  }
}

class _PackageCreateCommand extends StoreCommand {
  @override
  final String name = 'create';

  @override
  final String description = 'Create a package within a project.';

  @override
  String get invocation => 'omnystore package create <name> --project <id>';

  _PackageCreateCommand(super.context) {
    argParser
      ..addOption('project', abbr: 'p', help: 'Owning project id.')
      ..addOption('display-name', help: 'Human-friendly name.')
      ..addOption('description', help: 'Free-text description.')
      ..addOption(
        'default-channel',
        help:
            'Channel offered to clients that do not name one. Defaults to '
            'release, so a caller who has not opted in to pre-releases is '
            'never handed one.',
        allowed: ['dev', 'beta', 'release'],
        defaultsTo: 'release',
      )
      ..addMultiOption(
        'platform',
        help: 'Platforms this package publishes artifacts for.',
      )
      ..addMultiOption('metadata', help: 'Extra key=value pairs.');
  }

  @override
  Future<int> run() async {
    final ctx = await context;
    final rest = argResults!.rest;
    if (rest.isEmpty) {
      throw const CliException('Provide the package name.', exitCode: 64);
    }
    final package = await ctx.store.createPackage(
      projectId: require('project'),
      name: rest.first,
      displayName: optional('display-name'),
      description: optional('description'),
      defaultChannel: ReleaseChannel.parse(
        optional('default-channel') ?? 'release',
      ),
      platforms: argResults?.multiOption('platform') ?? const [],
      metadata: metadata(),
    );
    ctx.writeOne(package, 'Created package ${package.name} (${package.id})');
    return 0;
  }
}

class _PackageListCommand extends StoreCommand {
  @override
  final String name = 'list';

  @override
  final String description = 'List packages.';

  _PackageListCommand(super.context) {
    argParser
      ..addOption('project', abbr: 'p', help: 'Only packages of this project.')
      ..addOption(
        'org',
        abbr: 'o',
        help: 'Only packages of this organization.',
      );
  }

  @override
  Future<int> run() async {
    final ctx = await context;
    final orgRef = optional('org');
    String? organizationId;
    if (orgRef != null) {
      final organization =
          await ctx.store.organizationByName(orgRef) ??
          await ctx.store.organization(orgRef);
      if (organization == null) throw OrganizationNotFoundException(orgRef);
      organizationId = organization.id;
    }

    final packages = await ctx.store.listPackages(
      projectId: optional('project'),
      organizationId: organizationId,
    );
    ctx.writeTable(
      packages,
      headers: ['NAME', 'CHANNEL', 'PLATFORMS', 'ID'],
      rows: [
        for (final p in packages)
          [
            p.name,
            p.defaultChannel.name,
            p.platforms.isEmpty ? '-' : p.platforms.join(','),
            p.id,
          ],
      ],
      emptyMessage: 'No packages yet.',
    );
    return 0;
  }
}

class _PackageDeleteCommand extends StoreCommand {
  @override
  final String name = 'delete';

  @override
  final String description = 'Delete a package.';

  @override
  String get invocation => 'omnystore package delete <name-or-id>';

  _PackageDeleteCommand(super.context) {
    argParser.addFlag(
      'force',
      help: 'Delete its releases and artifacts too.',
      negatable: false,
    );
  }

  @override
  Future<int> run() async {
    final ctx = await context;
    final rest = argResults!.rest;
    if (rest.isEmpty) {
      throw const CliException('Provide the package.', exitCode: 64);
    }
    final package = await ctx.store.resolvePackage(rest.first);
    await ctx.store.deletePackage(package.id, force: flag('force'));
    ctx.info('Deleted package ${package.name}');
    return 0;
  }
}

/// `omnystore providers` — show the storage providers behind the registry.
class ProvidersCommand extends StoreCommand {
  @override
  final String name = 'providers';

  @override
  final String description =
      'List the storage providers (hub and nodes) serving this registry.';

  /// Creates the command.
  ProvidersCommand(super.context) {
    argParser.addOption(
      'org',
      abbr: 'o',
      help: 'Only providers serving this organization.',
    );
  }

  @override
  Future<int> run() async {
    final ctx = await context;
    final providers = await ctx.store.listProviders(
      organization: optional('org'),
    );
    ctx.writeTable(
      providers,
      headers: ['ID', 'KIND', 'STATUS', 'DATA PLANE', 'ORGANIZATIONS'],
      rows: [
        for (final p in providers)
          [
            p.id,
            p.kind.name,
            p.status.name,
            p.dataPlane.name,
            p.servesAll ? '*' : p.organizations.join(','),
          ],
      ],
      emptyMessage: 'No providers registered.',
    );
    return 0;
  }
}
