# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"
require "dependabot/npm_and_yarn/file_parser/yarn_lock"

module Dependabot
  module NpmAndYarn
    class DependencyGrapher < Dependabot::DependencyGraphers::Base
      class YarnRelationshipResolver
        extend T::Sig

        sig { params(lockfile: Dependabot::DependencyFile, catalogs: T::Hash[String, T::Hash[String, String]]).void }
        def initialize(lockfile, catalogs: {})
          @lockfile = lockfile
          @catalogs = catalogs
        end

        sig { returns(T::Hash[String, T::Array[String]]) }
        def relationships
          parsed = FileParser::YarnLock.new(@lockfile).parsed

          parsed.each_with_object({}) do |(req, details), rels|
            version = details.version
            parent_name = T.must(req.split(/(?<=\w)\@/).first)
            children = details.dependencies

            next if children.empty?

            key = "#{parent_name}@#{version}"
            resolved_children = resolve_children(children, parsed)

            rels[key] ||= []
            rels[key].concat(resolved_children).uniq!
          end
        end

        private

        sig do
          params(children: T::Hash[String, String], parsed: T::Hash[String, FileParser::YarnLock::Record])
            .returns(T::Array[String])
        end
        def resolve_children(children, parsed)
          children.filter_map do |child_name, child_req|
            version = resolve_child_version(child_name, child_req, parsed)
            "#{child_name}@#{version}" if version
          end
        end

        sig do
          params(child_name: String, child_req: String, parsed: T::Hash[String, FileParser::YarnLock::Record])
            .returns(T.nilable(String))
        end
        def resolve_child_version(child_name, child_req, parsed)
          catalog_reference = child_req if child_req.start_with?("catalog:")
          child_req = catalog_requirement(child_name, child_req) if catalog_reference
          version = descriptor_version("#{child_name}@#{child_req}", parsed)
          return version if version

          if catalog_reference
            raise DependencyFileNotResolvable, "#{child_name}@#{catalog_reference}: matching lockfile entry missing"
          end

          # Fallback: find by name only if there's exactly one candidate
          candidates = parsed.select { |k, _| k.split(/(?<=\w)\@/).first == child_name }
          candidate = candidates.first
          candidate.last.version if candidates.size == 1 && candidate
        end

        sig { params(descriptor: String, parsed: T::Hash[String, FileParser::YarnLock::Record]).returns(T.nilable(String)) }
        def descriptor_version(descriptor, parsed)
          entry = parsed[descriptor] || parsed.find { |key, _| key.split(", ").include?(descriptor) }&.last
          entry&.version
        end

        sig { params(name: String, reference: String).returns(String) }
        def catalog_requirement(name, reference)
          range = @catalogs.dig(reference, name)
          raise DependencyFileNotResolvable, "#{name}@#{reference}: catalog entry missing" unless range

          range.match?(/\A[a-z]+:/) ? range : "npm:#{range}"
        end
      end
    end
  end
end
