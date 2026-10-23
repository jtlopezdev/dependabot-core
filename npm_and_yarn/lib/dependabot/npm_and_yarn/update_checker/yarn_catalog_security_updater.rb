# typed: strict
# frozen_string_literal: true

require "dependabot/npm_and_yarn/dependency_grapher"
require "dependabot/npm_and_yarn/file_updater"
require "dependabot/npm_and_yarn/update_checker/conflicting_dependency_resolver"

module Dependabot
  module NpmAndYarn
    class UpdateChecker
      # Verify catalog security resolutions, making a bounded attempt to update
      # blocking ancestors when the target cannot be updated on its own.
      class YarnCatalogSecurityUpdater
        extend T::Sig

        CheckerFactory = T.type_alias do
          T.proc.params(dependency: Dependency).returns(Dependabot::UpdateCheckers::Base)
        end

        sig { params(checker: Dependabot::UpdateCheckers::Base).returns(YarnCatalogSecurityUpdater) }
        def self.for_resolution_check(checker:)
          finder = PackageLatestVersionFinder.new(
            dependency: security_resolution_dependency(checker),
            dependency_files: checker.dependency_files,
            credentials: checker.credentials,
            ignored_versions: checker.ignored_versions,
            raise_on_ignored: checker.raise_on_ignored,
            security_advisories: checker.security_advisories,
            cooldown_options: checker.update_cooldown
          )
          new(
            dependency: checker.dependency,
            dependency_files: checker.dependency_files,
            credentials: checker.credentials,
            security_advisories: checker.security_advisories,
            latest_version_finder: finder,
            ancestor_checker: nil
          )
        end

        sig { params(checker: Dependabot::UpdateCheckers::Base).returns(Dependency) }
        def self.security_resolution_dependency(checker)
          dependency = checker.dependency
          vulnerable_version = dependency.all_versions.filter_map do |version|
            next unless version && Version.correct?(version)

            parsed = Version.new(version)
            parsed if checker.security_advisories.any? { |advisory| advisory.vulnerable?(parsed) }
          end.min
          return dependency unless vulnerable_version

          # A safe direct resolution can be newer than the vulnerable installed
          # branch. Base the minimum fix on that branch, not its representative.
          Dependency.new(
            name: dependency.name,
            version: vulnerable_version,
            package_manager: dependency.package_manager,
            requirements: dependency.requirements,
            metadata: dependency.metadata
          )
        end
        private_class_method :security_resolution_dependency

        sig do
          params(
            dependency: Dependency,
            dependency_files: T::Array[DependencyFile],
            credentials: T::Array[Credential],
            security_advisories: T::Array[SecurityAdvisory],
            latest_version_finder: PackageLatestVersionFinder,
            ancestor_checker: T.nilable(CheckerFactory)
          ).void
        end
        def initialize(
          dependency:,
          dependency_files:,
          credentials:,
          security_advisories:,
          latest_version_finder:,
          ancestor_checker:
        )
          @dependency = dependency
          @dependency_files = dependency_files
          @credentials = credentials
          @security_advisories = security_advisories
          @latest_version_finder = latest_version_finder
          @ancestor_checker = ancestor_checker
          @checked = T.let(false, T::Boolean)
          @updates = T.let(nil, T.nilable(T::Array[Dependency]))
        end

        sig { returns(T.nilable(T::Array[Dependency])) }
        def updates
          return @updates if @checked

          @updates = verified_updates
          @checked = true
          @updates
        ensure
          Helpers.dependency_files = @dependency_files
          Helpers.credentials = @credentials
          Helpers.activate_npm_version_selector(@dependency_files)
        end

        # Verify every resolution for own/none proposals as well as direct
        # full-unlock updates, and preserve the contract on actual changes.
        sig { params(updates: T::Array[Dependency]).returns(T.nilable(T::Array[Dependency])) }
        def verify_updates(updates)
          minimum = @latest_version_finder.lowest_security_fix_version
          return unless minimum

          verify_proposal(updates, minimum)&.drop(1)
        rescue SharedHelpers::HelperSubprocessFailed, DependencyFileNotResolvable
          nil
        ensure
          Helpers.dependency_files = @dependency_files
          Helpers.credentials = @credentials
          Helpers.activate_npm_version_selector(@dependency_files)
        end

        # Check accumulated group files against the original target's policy
        # without starting another installation.
        sig { params(files: T::Array[DependencyFile]).returns(T.nilable(YarnCatalogSecurityValidation::Contract)) }
        def verified_resolution_contract(files)
          target = parsed_target(files)
          unless target
            return YarnCatalogSecurityValidation::Contract.new(
              target: @dependency.name, versions: [], retained_versions: [], retained_edges: []
            )
          end

          minimum = @latest_version_finder.lowest_security_fix_version
          return unless minimum

          verified_target_contract(target: target, files: files, minimum: minimum)
        end

        private

        sig { returns(T.nilable(T::Array[Dependency])) }
        def verified_updates
          minimum = @latest_version_finder.lowest_security_fix_version
          return unless minimum

          catalogs = YarnCatalogs.new(dependency_files: @dependency_files)
          parents = blocking_ancestors(catalogs, minimum)
          return if parents.empty?

          # Validate every ancestor before starting any candidate installation.
          parents.each { |parent| catalogs.validate_update!(parent.name) }
          factory = @ancestor_checker
          return unless factory

          updates = select_parent_updates(parents, factory)
          return unless updates

          verify_proposal(updates, minimum)
        rescue SharedHelpers::HelperSubprocessFailed, DependencyFileNotResolvable
          nil
        end

        sig { params(updates: T::Array[Dependency], minimum: Dependabot::Version).returns(T.nilable(T::Array[Dependency])) }
        def verify_proposal(updates, minimum)
          files = preview_files(updates)
          target = parsed_target(files)
          contract = verified_target_contract(target: target, files: files, minimum: minimum)
          return unless contract

          annotate_updates(updates, target, contract)
        end

        sig { params(files: T::Array[DependencyFile]).returns(T.nilable(Dependency)) }
        def parsed_target(files)
          YarnCatalogSecurityValidation.validate_target_aliases!(dependency_files: files, targets: [@dependency.name])
          FileParser.new(dependency_files: files, source: nil, credentials: @credentials)
                    .parse.find { |dep| dep.name == @dependency.name }
        end

        sig do
          params(target: T.nilable(Dependency), files: T::Array[DependencyFile], minimum: Dependabot::Version)
            .returns(T.nilable(YarnCatalogSecurityValidation::Contract))
        end
        def verified_target_contract(target:, files:, minimum:)
          versions = target&.all_versions&.compact || []
          return unless permitted_versions?(versions, minimum) && retained_safe_resolutions?(files, minimum)

          resolution_contract(versions, minimum)
        end

        sig { params(parents: T::Array[Dependency], factory: CheckerFactory).returns(T.nilable(T::Array[Dependency])) }
        def select_parent_updates(parents, factory)
          selections = parents.map { |parent| parent_updates(factory.call(parent)) }
          return if selections.any?(&:nil?)

          updates = selections.compact.flatten
          updates unless updates.empty?
        end

        sig { params(checker: Dependabot::UpdateCheckers::Base).returns(T.nilable(T::Array[Dependency])) }
        def parent_updates(checker)
          return unless checker.can_update?(requirements_to_unlock: :own)

          checker.updated_dependencies(requirements_to_unlock: :own)
        rescue AllVersionsIgnored
          nil
        end

        sig { params(updates: T::Array[Dependency]).returns(T::Array[DependencyFile]) }
        def preview_files(updates)
          changed = FileUpdater.new(
            dependencies: updates,
            dependency_files: @dependency_files,
            credentials: @credentials,
            options: { security_updates_only: true }
          ).updated_dependency_files
          @dependency_files.map { |file| changed.find { |update| update.path == file.path } || file }
        end

        sig { params(versions: T::Array[String], minimum: Dependabot::Version).returns(T::Boolean) }
        def permitted_versions?(versions, minimum)
          permitted = permitted_new_versions(minimum)
          # Safe resolutions already present may legitimately be older than
          # the vulnerable branch's minimum fix. Preserve them without allowing
          # a newly selected ignored release or a downgrade.
          (versions - permitted - unchanged_safe_versions).empty?
        end

        sig { params(minimum: Dependabot::Version).returns(T::Array[String]) }
        def permitted_new_versions(minimum)
          @latest_version_finder.possible_versions.select do |version|
            version >= minimum && @security_advisories.none? { |advisory| advisory.vulnerable?(version) }
          end.map(&:to_s)
        end

        sig { params(files: T::Array[DependencyFile], minimum: Dependabot::Version).returns(T::Boolean) }
        def retained_safe_resolutions?(files, minimum)
          retained = (unchanged_safe_versions - permitted_new_versions(minimum)).map do |version|
            "#{@dependency.name}@#{version}"
          end
          return true if retained.empty?

          original = relationships(@dependency_files)
          # Grandfather only existing edges to safe but otherwise disallowed
          # versions. An updated ancestor must not newly select one of them.
          relationships(files).all? do |parent, children|
            !children.intersect?(retained - original.fetch(parent, []))
          end
        end

        sig { params(files: T::Array[DependencyFile]).returns(T::Hash[String, T::Array[String]]) }
        def relationships(files)
          catalogs = YarnCatalogs.new(dependency_files: files)
          lockfile = T.must(files.find { |file| file.name == "yarn.lock" })
          DependencyGrapher::YarnRelationshipResolver.new(lockfile, catalogs: catalogs.helper_catalogs).relationships
        end

        sig { returns(T::Array[String]) }
        def unchanged_safe_versions
          original = parsed_dependencies.find { |dependency| dependency.name == @dependency.name }
          (original&.all_versions || []).compact.select do |version|
            @security_advisories.none? { |advisory| advisory.vulnerable?(Version.new(version)) }
          end
        end

        sig do
          params(
            updates: T::Array[Dependency],
            target: T.nilable(Dependency),
            contract: YarnCatalogSecurityValidation::Contract
          ).returns(T::Array[Dependency])
        end
        def annotate_updates(updates, target, contract)
          # Information-only targets are removed before the final FileUpdater
          # runs. Carry the verified resolution set on the actual file changes.
          updates.each do |update|
            YarnCatalogSecurityValidation.add_contract!(update, contract)
            next unless update.name == @dependency.name

            update.metadata[:yarn_catalog_security_previous_versions] = @dependency.all_versions.compact

            # Report the verified inventory rather than the original snapshot
            # copied by Base's own/none unlock builders.
            update.metadata.delete(:all_versions)
            inventory = target&.metadata&.fetch(:all_versions, nil)
            update.metadata[:all_versions] = inventory if inventory
          end

          [informational_update(target, contract)] + updates
        end

        sig do
          params(target: T.nilable(Dependency), contract: YarnCatalogSecurityValidation::Contract).returns(Dependency)
        end
        def informational_update(target, contract)
          Dependency.new(
            name: @dependency.name,
            version: target&.version,
            previous_version: @dependency.version,
            package_manager: @dependency.package_manager,
            requirements: [],
            previous_requirements: [],
            removed: target.nil?,
            metadata: (target&.metadata || {}).merge(
              information_only: true,
              yarn_catalog_security_previous_versions: @dependency.all_versions.compact,
              yarn_catalog_security_contracts: [contract.serialize]
            )
          )
        end

        sig do
          params(versions: T::Array[String], minimum: Dependabot::Version)
            .returns(YarnCatalogSecurityValidation::Contract)
        end
        def resolution_contract(versions, minimum)
          retained = unchanged_safe_versions - permitted_new_versions(minimum)
          edges = relationships(@dependency_files).flat_map do |parent, children|
            children.filter_map do |child|
              [parent, child].to_json if retained.any? { |version| child == "#{@dependency.name}@#{version}" }
            end
          end
          YarnCatalogSecurityValidation::Contract.new(
            target: @dependency.name, versions: versions, retained_versions: retained, retained_edges: edges
          )
        end

        sig { params(catalogs: YarnCatalogs, minimum: Dependabot::Version).returns(T::Array[Dependency]) }
        def blocking_ancestors(catalogs, minimum)
          conflicts = ConflictingDependencyResolver.new(dependency_files: @dependency_files, credentials: @credentials)
                                                   .conflicting_dependencies(
                                                     dependency: @dependency, target_version: minimum
                                                   )
          blockers = conflicts.map { |conflict| "#{conflict.fetch('name')}@#{conflict.fetch('version')}" }
          lockfile = T.must(@dependency_files.find { |file| file.name == "yarn.lock" })
          graph = DependencyGrapher::YarnRelationshipResolver.new(
            lockfile,
            catalogs: catalogs.helper_catalogs
          ).relationships
          vulnerable = vulnerable_target_nodes
          # Conflicts on unchanged safe branches do not require an ancestor
          # update. Their original resolutions and edges are verified later.
          blockers.select! { |parent| graph.fetch(parent, []).intersect?(vulnerable) }
          parsed_dependencies.select(&:top_level?).select do |parent|
            parent.all_versions.any? { |version| reaches_blocker?("#{parent.name}@#{version}", graph, blockers, []) }
          end
        end

        sig { returns(T::Array[String]) }
        def vulnerable_target_nodes
          versions = parsed_dependencies.find { |dep| dep.name == @dependency.name }&.all_versions || []
          versions.filter_map do |version|
            next unless version && @security_advisories.any? { |advisory| advisory.vulnerable?(Version.new(version)) }

            "#{@dependency.name}@#{version}"
          end
        end

        sig { returns(T::Array[Dependency]) }
        def parsed_dependencies
          @parsed_dependencies ||= T.let(
            FileParser.new(dependency_files: @dependency_files, source: nil, credentials: @credentials).parse,
            T.nilable(T::Array[Dependency])
          )
        end

        sig do
          params(
            node: String,
            graph: T::Hash[String, T::Array[String]],
            blockers: T::Array[String],
            visited: T::Array[String]
          ).returns(T::Boolean)
        end
        def reaches_blocker?(node, graph, blockers, visited)
          return true if blockers.include?(node)
          return false if visited.include?(node)

          visited << node
          graph.fetch(node, []).any? { |child| reaches_blocker?(child, graph, blockers, visited) }
        end
      end
    end
  end
end
