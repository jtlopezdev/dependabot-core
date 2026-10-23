# typed: strong
# frozen_string_literal: true

require "sorbet-runtime"
require "dependabot/npm_and_yarn/yarn_catalog_security_validation"

module Dependabot
  class Updater
    # Preserve each catalog security target's original policy as grouped updates
    # change its installed versions, including incidental fixes and removals.
    module YarnCatalogSecurityUpdateHelpers
      extend T::Sig
      extend T::Helpers

      requires_ancestor { GroupUpdateCreation }

      # rubocop:disable Metrics/AbcSize, Metrics/PerceivedComplexity
      sig do
        params(
          changes: Dependabot::Updater::DependencyGroupChangeBatch,
          checked_dependencies: T::Array[Dependabot::Dependency],
          initial_files: T::Array[Dependabot::DependencyFile],
          group: Dependabot::DependencyGroup
        ).void
      end
      def reconcile_catalog_security_updates!(changes, checked_dependencies, initial_files, group)
        return unless job.package_manager == "npm_and_yarn" && job.security_updates_only?
        return if changes.updated_dependency_files.empty?
        return if Dependabot::NpmAndYarn::YarnCatalogs.new(dependency_files: initial_files).bindings.empty?

        files = changes.current_dependency_files(job)
        final_dependencies = dependency_file_parser(files).parse.to_h { |dependency| [dependency.name, dependency] }
        reported = changes.updated_dependencies.map(&:name)
        # A target checked before its blocking ancestor may have failed on its
        # own. Reconsider only members visited in this directory and group;
        # their handled state has already changed during the main loop.
        checked_dependencies.uniq(&:name).each do |original|
          next if reported.include?(original.name) || job.security_advisories_for(original).empty?

          checker = update_checker_for(original, initial_files, group, raise_on_ignored: raise_on_ignored?(original))
          next unless checker.vulnerable?

          updated = deduce_catalog_security_update(
            final_dependencies[original.name], original, files, initial_files, group
          )
          next unless updated

          updated.metadata[:information_only] = true
          changes.add_updated_dependency(updated)
        end
      end
      # rubocop:enable Metrics/AbcSize, Metrics/PerceivedComplexity

      # rubocop:disable Metrics/AbcSize, Metrics/PerceivedComplexity
      sig do
        params(
          changes: Dependabot::Updater::DependencyGroupChangeBatch,
          initial_files: T::Array[Dependabot::DependencyFile],
          group: Dependabot::DependencyGroup
        ).void
      end
      def finalize_group_catalog_security!(changes, initial_files, group)
        return unless job.package_manager == "npm_and_yarn"

        validation = Dependabot::NpmAndYarn::YarnCatalogSecurityValidation
        targets = changes.updated_dependencies.flat_map do |dependency|
          validation.contracts_for(dependency).map(&:target)
        end
        return if targets.empty?

        files = changes.current_dependency_files(job)
        # Later group members may legitimately change an earlier target's safe
        # inventory. Reverify against the initial policy and edges, rather than
        # requiring every intermediate resolution snapshot to remain identical.
        contracts = targets.uniq.to_h do |name|
          original = T.must(dependency_snapshot.dependencies.find { |dependency| dependency.name == name })
          contract = original_catalog_security_contract!(
            original, current_files: files, initial_files: initial_files, group: group
          )
          [name, contract]
        end
        final_dependencies = dependency_file_parser(files).parse.to_h { |dependency| [dependency.name, dependency] }
        changes.updated_dependencies.map! do |dependency|
          previous_contracts = validation.contracts_for(dependency)
          if previous_contracts.any?
            dependency.metadata[:yarn_catalog_security_contracts] =
              previous_contracts.map do |contract|
                T.cast(contracts.fetch(contract.target).serialize, T::Hash[String, Object])
              end.uniq
          end
          next dependency unless contracts.key?(dependency.name)

          catalog_dependency_with_final_inventory(dependency, final_dependencies[dependency.name])
        end
      end
      # rubocop:enable Metrics/AbcSize, Metrics/PerceivedComplexity

      sig do
        params(dependency: Dependabot::Dependency, final: T.nilable(Dependabot::Dependency))
          .returns(Dependabot::Dependency)
      end
      def catalog_dependency_with_final_inventory(dependency, final)
        metadata = dependency.metadata.dup
        metadata.delete(:all_versions)
        inventory = final&.metadata&.fetch(:all_versions, nil)
        metadata[:all_versions] = inventory if inventory
        Dependabot::Dependency.new(
          name: dependency.name,
          version: final&.version,
          previous_version: dependency.previous_version,
          package_manager: dependency.package_manager,
          requirements: final ? dependency.requirements : [],
          previous_requirements: dependency.previous_requirements,
          directory: dependency.directory,
          subdependency_metadata: dependency.subdependency_metadata,
          removed: final.nil?,
          metadata: metadata
        )
      end

      sig do
        params(
          dependency: T.nilable(Dependabot::Dependency),
          original: T.nilable(Dependabot::Dependency),
          files: T::Array[Dependabot::DependencyFile],
          initial_files: T::Array[Dependabot::DependencyFile],
          group: Dependabot::DependencyGroup
        ).returns(T.nilable(Dependabot::Dependency))
      end
      def deduce_catalog_security_update(dependency, original, files, initial_files, group)
        return deduce_removed_catalog_security_update(original, files, initial_files, group) unless dependency
        return deduce_updated_dependency(dependency, original) unless original

        changed = original.version != dependency.version || original.all_versions.sort != dependency.all_versions.sort
        unless changed && catalog_security_target?(original, initial_files)
          return deduce_updated_dependency(dependency, original)
        end

        current_checker = update_checker_for(dependency, files, group, raise_on_ignored: raise_on_ignored?(dependency))
        return if current_checker.vulnerable?

        contract = original_catalog_security_contract!(
          original,
          current_files: files,
          initial_files: initial_files,
          group: group
        )

        updated = T.must(deduce_updated_dependency(dependency, original, inventory_changed: true))
        updated.metadata[:information_only] = true if original.version == dependency.version
        updated.metadata[:yarn_catalog_security_previous_versions] = original.all_versions.compact
        Dependabot::NpmAndYarn::YarnCatalogSecurityValidation.add_contract!(updated, contract)
        updated
      end

      sig do
        params(dependency: Dependabot::Dependency, files: T::Array[Dependabot::DependencyFile]).returns(T::Boolean)
      end
      def catalog_security_target?(dependency, files)
        job.package_manager == "npm_and_yarn" && job.security_updates_only? &&
          job.security_advisories_for(dependency).any? &&
          Dependabot::NpmAndYarn::YarnCatalogs.new(dependency_files: files).bindings.any?
      end

      sig do
        params(
          original: T.nilable(Dependabot::Dependency),
          files: T::Array[Dependabot::DependencyFile],
          initial_files: T::Array[Dependabot::DependencyFile],
          group: Dependabot::DependencyGroup
        ).returns(T.nilable(Dependabot::Dependency))
      end
      def deduce_removed_catalog_security_update(original, files, initial_files, group)
        return unless original && catalog_security_target?(original, initial_files)

        checker = update_checker_for(original, initial_files, group, raise_on_ignored: raise_on_ignored?(original))
        return unless checker.vulnerable?

        contract = original_catalog_security_contract!(
          original,
          current_files: files,
          initial_files: initial_files,
          group: group
        )
        removed = Dependabot::Dependency.new(
          name: original.name,
          previous_version: original.version,
          package_manager: original.package_manager,
          requirements: [],
          previous_requirements: original.requirements,
          removed: true,
          metadata: { information_only: true, yarn_catalog_security_previous_versions: original.all_versions.compact }
        )
        Dependabot::NpmAndYarn::YarnCatalogSecurityValidation.add_contract!(removed, contract)
        removed
      end

      sig do
        params(
          change: Dependabot::DependencyChange,
          original: T.nilable(Dependabot::Dependency),
          current_files: T::Array[Dependabot::DependencyFile],
          initial_files: T::Array[Dependabot::DependencyFile],
          group: Dependabot::DependencyGroup
        ).void
      end
      def verify_catalog_change!(change, original, current_files, initial_files, group)
        return unless original && catalog_security_target?(original, initial_files)

        files = current_files.map do |file|
          change.updated_dependency_files.find { |updated| updated.path == file.path } || file
        end
        # A partial incidental fix must not reset the policy baseline and
        # grandfather versions or edges introduced earlier in this group.
        contract = original_catalog_security_contract!(
          original,
          current_files: files,
          initial_files: initial_files,
          group: group
        )
        change.updated_dependencies.each do |updated|
          if updated.name == original.name
            updated.metadata[:yarn_catalog_security_previous_versions] = original.all_versions.compact
          end
          Dependabot::NpmAndYarn::YarnCatalogSecurityValidation.add_contract!(updated, contract)
        end
      end

      sig do
        params(
          original: Dependabot::Dependency,
          current_files: T::Array[Dependabot::DependencyFile],
          initial_files: T::Array[Dependabot::DependencyFile],
          group: Dependabot::DependencyGroup
        ).returns(Dependabot::NpmAndYarn::YarnCatalogSecurityValidation::Contract)
      end
      def original_catalog_security_contract!(original, current_files:, initial_files:, group:)
        checker = update_checker_for(original, initial_files, group, raise_on_ignored: raise_on_ignored?(original))
        contract = Dependabot::NpmAndYarn::UpdateChecker::YarnCatalogSecurityUpdater
                   .for_resolution_check(checker: checker).verified_resolution_contract(current_files)
        unless contract
          Kernel.raise Dependabot::DependencyFileNotResolvable,
                       "#{original.name}: catalog security update violates original target policy"
        end
        contract
      end
    end
  end
end
