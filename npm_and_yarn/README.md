## `dependabot-npm_and_yarn`

Yarn and npm support for [`dependabot-core`][core-repo].

### Yarn catalogs

Native Yarn catalogs are supported on Yarn 4.10 and later. Dependabot updates consumed default and named catalog
entries in the project's own `.yarnrc.yml` and resolves the lockfile while preserving `catalog:` references in
workspace manifests. The project root must contain `package.json`, `.yarnrc.yml`, and `yarn.lock`; that root may be
a repository subdirectory. Both ordinary and lockfile-only updates retain Dependabot's selected version.

The initial scope is one active catalog identity per package name, shared by any number of workspaces, with plain
registry semver ranges in `dependencies` and `devDependencies`. Many catalogs and different catalog packages may be
updated together. A package consumed through multiple catalog identities, or through both a catalog and an ordinary
direct declaration, reports an unsupported feature. Catalog ranges resolved to local workspaces are excluded from
registry updates. Inherited configuration, plugin catalogs, and selected YAML aliases or anchors are also outside this scope.

Catalog edges participate in dependency graph and conflict traversal. Security updates for catalog dependencies
and transitive updates in projects using catalogs are not yet supported. Ordinary direct security updates remain available.

### Running locally

1. Start a development shell

  ```
  $ bin/docker-dev-shell npm_and_yarn
  ```

2. Run tests
   ```
   [dependabot-core-dev] ~ $ cd npm_and_yarn && rspec
   ```

[core-repo]: https://github.com/dependabot/dependabot-core
