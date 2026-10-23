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

Catalog edges participate in dependency graph and conflict traversal. For transitive security updates requiring an
ancestor change, security jobs make a bounded attempt using each ancestor's own policy, then verify every resolved
target version. The final updater must preserve the preview's verified resolution set. Accumulated groups revalidate
each target against its original policy and existing branches to retained older safe versions. Later changes must
still satisfy that policy; updated ancestors cannot newly select otherwise disallowed versions. This path can report
that no verified update is available; it does not search every combination of ancestor releases. It may also decline
a standalone repair when a safe direct catalog dependency shares its package name with a vulnerable transitive
resolution.

Security verification also covers the complete installed inventory for direct and in-range transitive proposals.
Grouped updates retain the initial target policy through incidental changes, including fixes that preserve a safe
representative version and removal of vulnerable targets. Catalog security updates are unsupported when the lockfile
contains an npm alias for the security target; aliases for unrelated packages do not prevent verification.

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
