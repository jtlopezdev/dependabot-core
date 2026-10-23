# typed: false
# frozen_string_literal: true

require "spec_helper"
require "dependabot/npm_and_yarn/file_parser"
require "dependabot/npm_and_yarn/file_updater"
require "dependabot/npm_and_yarn/update_checker"

RSpec.describe Dependabot::NpmAndYarn::UpdateChecker do
  let(:files) { project_dependency_files("yarn_berry/catalog_workspace") }
  let(:dependency) do
    Dependabot::NpmAndYarn::FileParser.new(dependency_files: files, source: nil).parse.find { |dep| dep.name == "prettier" }
  end
  let(:checker) do
    described_class.new(
      dependency: dependency,
      dependency_files: files,
      credentials: [],
      ignored_versions: ignored_versions,
      requirements_update_strategy: Dependabot::RequirementsUpdateStrategy::BumpVersions,
      security_advisories: security_advisories,
      options: checker_options
    )
  end
  let(:security_advisories) { [] }
  let(:ignored_versions) { [">= 2.8.7"] }
  let(:checker_options) { {} }

  before do
    listing = {
      "name" => "prettier", "dist-tags" => { "latest" => "2.8.8" },
      "versions" => %w(2.8.0 2.8.6 2.8.8).to_h { |version| [version, { "version" => version }] }
    }
    stub_request(:get, "https://registry.npmjs.org/prettier").to_return(status: 200, body: listing.to_json)
    stub_request(:get, "https://registry.npmjs.org/prettier/latest").to_return(status: 200, body: "{}")
    stub_request(:head, "https://registry.npmjs.org/prettier/-/prettier-2.8.6.tgz").to_return(status: 200)
  end

  it "carries the policy-selected target from checking through installation and becomes up to date" do
    expect(checker.can_update?(requirements_to_unlock: :all)).to be true
    updated_dependencies = checker.updated_dependencies(requirements_to_unlock: :all)
    expect(updated_dependencies.map(&:version)).to eq(["2.8.6"])
    updated_files = Dependabot::NpmAndYarn::FileUpdater.new(
      dependencies: updated_dependencies, dependency_files: files, credentials: []
    ).updated_dependency_files
    merged = files.map { |file| updated_files.find { |changed| changed.name == file.name } || file }
    parsed = Dependabot::NpmAndYarn::FileParser.new(dependency_files: merged, source: nil).parse
    next_checker = described_class.new(
      dependency: parsed.find { |dep| dep.name == "prettier" },
      dependency_files: merged,
      credentials: [],
      ignored_versions: [">= 2.8.7"]
    )
    expect(next_checker).to be_up_to_date
    expect(merged.select { |file| file.name.end_with?("package.json") }.map(&:content))
      .to eq(files.select { |file| file.name.end_with?("package.json") }.map(&:content))
  end

  context "with a vulnerable catalog dependency" do
    let(:security_advisories) do
      [Dependabot::SecurityAdvisory.new(
        dependency_name: "prettier", package_manager: "npm_and_yarn", vulnerable_versions: ["< 2.8.6"]
      )]
    end

    it "reports unsupported security updates before proposing a partial fix" do
      expect { checker }.to raise_error(Dependabot::ToolFeatureNotSupported, /security updates for Yarn catalogs/)
    end
  end

  context "with a vulnerable transitive dependency below a catalog" do
    let(:files) { project_dependency_files("yarn_berry/catalog_security") }
    let(:dependency) do
      Dependabot::NpmAndYarn::FileParser.new(dependency_files: files, source: nil).parse.find { |dep| dep.name == "is-number" }
    end
    let(:security_advisories) do
      [Dependabot::SecurityAdvisory.new(
        dependency_name: "is-number", package_manager: "npm_and_yarn", vulnerable_versions: ["< 6.0.0"]
      )]
    end

    it "reports unsupported ancestor updates before proposing a partial fix" do
      expect { checker }.to raise_error(Dependabot::ToolFeatureNotSupported, /security updates for Yarn catalogs/)
    end
  end

  context "with an unrelated ordinary security update in a catalog project" do
    let(:files) { project_dependency_files("yarn_berry/catalog_mixed_ordinary") }
    let(:security_advisories) do
      [Dependabot::SecurityAdvisory.new(
        dependency_name: "prettier", package_manager: "npm_and_yarn", vulnerable_versions: ["< 2.8.6"]
      )]
    end

    it "updates the ordinary dependency and preserves the catalog configuration" do
      updates = checker.updated_dependencies(requirements_to_unlock: :all)
      expect(updates.map(&:version)).to eq(["2.8.6"])
      changed = Dependabot::NpmAndYarn::FileUpdater.new(
        dependencies: updates, dependency_files: files, credentials: [], options: { security_updates_only: true }
      ).updated_dependency_files
      expect(changed.map(&:name)).not_to include(".yarnrc.yml")
      lock = YAML.safe_load(changed.find { |file| file.name == "yarn.lock" }.content)
      versions = lock.filter_map { |key, record| record.fetch("version") if key.start_with?("prettier@") }
      expect(versions).to eq(["2.8.6"])
      expect(lock.fetch("catalog-security@workspace:.").dig("dependencies", "is-odd")).to eq("catalog:math")
    end
  end
end
