# typed: strict
# frozen_string_literal: true

require "dependabot/update_checkers"

module Dependabot
  class Updater
    # Ancestor selection must use the job's policy for that ancestor, rather
    # than inheriting the vulnerable child's ignores or dropping block rules.
    module YarnCatalogUpdateCheckerOptions
      extend T::Sig

      sig { params(job: Job, dependency_files: T::Array[DependencyFile]).returns(T::Hash[Symbol, T.anything]) }
      def self.for(job:, dependency_files:)
        return job.experiments unless job.package_manager == "npm_and_yarn"
        return job.experiments unless dependency_files.any? do |file|
          file.name.end_with?(".yarnrc.yml")
        end

        job.experiments.merge(
          yarn_catalog_ancestor_checker: lambda do |dependency|
            UpdateCheckers.for_package_manager(job.package_manager).new(
              dependency: dependency,
              dependency_files: dependency_files,
              credentials: job.credentials,
              ignored_versions: job.ignore_conditions_for(dependency),
              security_advisories: job.security_advisories_for(dependency),
              raise_on_ignored: true,
              requirements_update_strategy: job.requirements_update_strategy,
              options: job.experiments
            )
          end
        )
      end
    end
  end
end
