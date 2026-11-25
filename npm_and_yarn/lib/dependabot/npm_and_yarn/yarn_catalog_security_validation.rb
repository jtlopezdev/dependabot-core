# typed: strict
# frozen_string_literal: true

require "dependabot/npm_and_yarn/file_parser"
require "dependabot/npm_and_yarn/dependency_grapher"

module Dependabot
  module NpmAndYarn
    # Validate both final updater output and an accumulated group. A later
    # group member must not invalidate an earlier security resolution.
    module YarnCatalogSecurityValidation
      extend T::Sig

      class Contract < T::Struct
        const :target, String
        const :versions, T::Array[String]
        const :retained_versions, T::Array[String]
        const :retained_edges, T::Array[String]
      end

      sig { params(dependency: Dependency).returns(T::Array[Contract]) }
      def self.contracts_for(dependency)
        (dependency.metadata_array(:yarn_catalog_security_contracts) || []).map do |value|
          raise TypeError, "Yarn catalog security contracts must be mappings" unless value.is_a?(Hash)

          Contract.from_hash(value, strict: true)
        end
      end

      sig { params(dependency: Dependency, contract: Contract).void }
      def self.add_contract!(dependency, contract)
        dependency.metadata[:yarn_catalog_security_contracts] =
          (contracts_for(dependency) + [contract]).map(&:serialize).uniq
      end

      sig do
        params(
          dependency_files: T::Array[DependencyFile],
          dependencies: T::Array[Dependency],
          credentials: T::Array[Credential]
        ).void
      end
      def self.validate!(dependency_files:, dependencies:, credentials:)
        validations = dependencies.flat_map { |dependency| contracts_for(dependency) }.uniq(&:serialize)
        return if validations.empty?

        validate_target_aliases!(dependency_files: dependency_files, targets: validations.map(&:target).uniq)
        parsed = FileParser.new(dependency_files: dependency_files, source: nil, credentials: credentials).parse
        graph = relationships(dependency_files) if validations.any? { |contract| contract.retained_versions.any? }
        validations.each do |contract|
          validate_resolution!(parsed, contract)
          validate_retained_edges!(T.must(graph), contract) if contract.retained_versions.any?
        end
      end

      sig { params(dependency_files: T::Array[DependencyFile], targets: T::Array[String]).void }
      def self.validate_target_aliases!(dependency_files:, targets:)
        lockfile = T.must(dependency_files.find { |file| file.name == "yarn.lock" })
        records = FileParser::YarnLock.new(lockfile).parsed
        targets.each do |target|
          aliased = records.any? do |descriptors, record|
            resolution = record.lookup_details.resolution
            descriptors.split(", ").any? do |descriptor|
              descriptor.include?("@npm:#{target}@") ||
                (resolution&.start_with?("#{target}@") && !descriptor.start_with?("#{target}@"))
            end
          end
          next unless aliased

          # The inventory parser and relationship graph do not share alias
          # identities. Do not mistake an aliased target for a removed one or
          # grandfather an ignored alias through an unrelated existing edge.
          raise ToolFeatureNotSupported.new(
            tool_name: "yarn",
            tool_type: "package_manager",
            feature: "#{target}: catalog security verification of npm aliases"
          )
        end
      end

      sig { params(files: T::Array[DependencyFile]).returns(T::Hash[String, T::Array[String]]) }
      def self.relationships(files)
        catalogs = YarnCatalogs.new(dependency_files: files)
        lockfile = T.must(files.find { |file| file.name == "yarn.lock" })
        DependencyGrapher::YarnRelationshipResolver.new(
          lockfile, catalogs: catalogs.helper_catalogs
        ).relationships
      end
      private_class_method :relationships

      sig { params(graph: T::Hash[String, T::Array[String]], contract: Contract).void }
      def self.validate_retained_edges!(graph, contract)
        nodes = contract.retained_versions.map { |version| "#{contract.target}@#{version}" }
        return if graph.all? do |parent, children|
          (children & nodes).all? { |child| contract.retained_edges.include?([parent, child].to_json) }
        end

        raise DependencyFileNotResolvable,
              "#{contract.target}: catalog security resolution introduced a disallowed branch"
      end
      private_class_method :validate_retained_edges!

      sig { params(parsed: T::Array[Dependency], contract: Contract).void }
      def self.validate_resolution!(parsed, contract)
        versions = parsed.find { |dep| dep.name == contract.target }&.all_versions || []
        return if versions.sort == contract.versions.sort

        raise DependencyFileNotResolvable, "#{contract.target}: catalog security resolution changed after verification"
      end
      private_class_method :validate_resolution!
    end
  end
end
