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

  context "with a vulnerable direct catalog dependency" do
    let(:security_advisories) do
      [Dependabot::SecurityAdvisory.new(
        dependency_name: "prettier", package_manager: "npm_and_yarn", vulnerable_versions: ["< 2.8.6"]
      )]
    end

    before do
      files.find { |file| file.name == ".yarnrc.yml" }.content =
        files.find { |file| file.name == ".yarnrc.yml" }.content.sub('"2.8.0"', '"^2.8.0"')
      lock = files.find { |file| file.name == "yarn.lock" }
      lock.content = lock.content.sub("prettier@npm:2.8.0", "prettier@npm:^2.8.0")
    end

    %i(none own all).each do |unlock|
      it "verifies and carries the complete security resolution contract for #{unlock} unlock" do
        expect(checker.can_update?(requirements_to_unlock: unlock)).to be true
        updates = checker.updated_dependencies(requirements_to_unlock: unlock)
        expect(updates.first.version).to eq("2.8.6")
        expect(updates.first.all_versions).to eq(["2.8.6"])
        contract = Dependabot::NpmAndYarn::YarnCatalogSecurityValidation.contracts_for(updates.first).first
        expect(contract.target).to eq("prettier")
        expect(contract.versions).to eq(["2.8.6"])
        changed = Dependabot::NpmAndYarn::FileUpdater.new(
          dependencies: updates, dependency_files: files, credentials: [], options: { security_updates_only: true }
        ).updated_dependency_files
        merged = files.map { |file| changed.find { |update| update.path == file.path } || file }
        expect(
          Dependabot::NpmAndYarn::FileParser.new(dependency_files: merged, source: nil).parse
                    .find { |dep| dep.name == "prettier" }.all_versions
        ).to eq(["2.8.6"])
      end
    end

    it "rejects resolution drift during final generation after a verified direct preview" do
      updates = checker.updated_dependencies(requirements_to_unlock: :own)
      updater = Dependabot::NpmAndYarn::FileUpdater.new(dependencies: updates, dependency_files: files, credentials: [])
      allow(updater).to receive(:updated_yarn_lock_content).and_wrap_original do |original, *arguments|
        original.call(*arguments).sub("version: 2.8.6", "version: 2.8.8")
      end
      expect { updater.updated_dependency_files }
        .to raise_error(Dependabot::DependencyFileNotResolvable, /after verification/)
    end
  end

  context "with a safe direct catalog resolution and a vulnerable transitive resolution of the same package" do
    let(:files) { project_dependency_files("yarn_berry/catalog_multiversion_safe_direct") }
    let(:ignored_versions) { [] }
    let(:dependency) do
      Dependabot::NpmAndYarn::FileParser.new(dependency_files: files, source: nil).parse.find { |dep| dep.name == "is-number" }
    end
    let(:security_advisories) do
      [Dependabot::SecurityAdvisory.new(
        dependency_name: "is-number", package_manager: "npm_and_yarn", vulnerable_versions: [">= 4.0.0 < 6.0.0"]
      )]
    end

    before do
      listing = { "name" => "is-number", "dist-tags" => { "latest" => "7.0.0" },
                  "versions" => %w(2.1.0 3.0.0 4.0.0 6.0.0 7.0.0).to_h do |version|
                    [version, { "version" => version }]
                  end }
      stub_request(:get, "https://registry.npmjs.org/is-number").to_return(status: 200, body: listing.to_json)
      stub_request(:get, "https://registry.npmjs.org/is-number/latest").to_return(status: 200, body: "{}")
      stub_request(:head, %r{https://registry.npmjs.org/is-number/-/}).to_return(status: 200)
    end

    it "declines every direct-only unlock proposal while the vulnerable branch remains installed" do
      expect(dependency.all_versions).to contain_exactly("2.1.0", "4.0.0")
      expect(checker).to be_vulnerable
      %i(none own all).each do |unlock|
        expect(checker.can_update?(requirements_to_unlock: unlock)).to be false
        expect(checker.updated_dependencies(requirements_to_unlock: unlock)).to be_empty
      end
    end
  end

  context "with a vulnerable transitive dependency below a catalog consumer" do
    let(:ignored_versions) { [] }
    let(:files) { project_dependency_files("yarn_berry/catalog_security") }
    let(:dependency) do
      Dependabot::NpmAndYarn::FileParser.new(dependency_files: files, source: nil).parse.find { |dep| dep.name == "is-number" }
    end
    let(:security_advisories) do
      [Dependabot::SecurityAdvisory.new(
        dependency_name: "is-number",
        package_manager: "npm_and_yarn",
        vulnerable_versions: ["< 6.0.0"]
      )]
    end
    let(:checker_options) do
      { yarn_catalog_ancestor_checker: lambda do |ancestor|
        described_class.new(
          dependency: ancestor,
          dependency_files: files,
          credentials: [],
          ignored_versions: ancestor_ignored_versions,
          requirements_update_strategy: Dependabot::RequirementsUpdateStrategy::BumpVersions
        )
      end }
    end
    let(:ancestor_ignored_versions) { [] }

    before do
      { "is-odd" => %w(2.0.0 3.0.1), "is-number" => %w(4.0.0 6.0.0) }.each do |name, versions|
        listing = { "name" => name, "dist-tags" => { "latest" => versions.last },
                    "versions" => versions.to_h { |version| [version, { "version" => version }] } }
        stub_request(:get, "https://registry.npmjs.org/#{name}").to_return(status: 200, body: listing.to_json)
        stub_request(:get, "https://registry.npmjs.org/#{name}/latest").to_return(status: 200, body: "{}")
        stub_request(:head, %r{https://registry.npmjs.org/#{name}/-/}).to_return(status: 200)
      end
    end

    it "unlocks the catalog ancestor and validates the final security resolution" do
      expect(checker.can_update?(requirements_to_unlock: :own)).to be false
      expect(checker.can_update?(requirements_to_unlock: :all)).to be true
      updates = checker.updated_dependencies(requirements_to_unlock: :all)
      expect(updates.map { |dep| [dep.name, dep.version] }).to eq([["is-number", "6.0.0"], ["is-odd", "3.0.1"]])
      expect(updates.first.metadata[:information_only]).to be true
      updated = Dependabot::NpmAndYarn::FileUpdater.new(
        dependencies: updates.drop(1),
        dependency_files: files,
        credentials: [],
        options: { security_updates_only: true }
      ).updated_dependency_files
      expect(updated.find { |file| file.name == ".yarnrc.yml" }.content).to include("is-odd: ^3.0.1")
      merged = files.map { |file| updated.find { |changed| changed.name == file.name } || file }
      parsed = Dependabot::NpmAndYarn::FileParser.new(dependency_files: merged, source: nil).parse
      expect(parsed.find { |dep| dep.name == "is-number" }.all_versions).to eq(["6.0.0"])
    end

    it "rejects an unsupported ancestor before generating any update" do
      files.find { |file| file.name == "packages/child/package.json" }.content =
        files.find { |file| file.name == "packages/child/package.json" }.content.sub("catalog:math", "^2.0.0")
      expect { checker.can_update?(requirements_to_unlock: :all) }
        .to raise_error(Dependabot::ToolFeatureNotSupported, /ordinary direct/)
    end

    it "rejects drift in the final updater even when the informational child is filtered out" do
      updates = checker.updated_dependencies(requirements_to_unlock: :all).reject(&:informational_only?)
      updater = Dependabot::NpmAndYarn::FileUpdater.new(dependencies: updates, dependency_files: files, credentials: [])
      allow(updater).to receive(:updated_yarn_lock_content).and_wrap_original do |original, *arguments|
        original.call(*arguments).sub("version: 6.0.0", "version: 7.0.0")
      end
      expect do
        updater.updated_dependency_files
      end.to raise_error(Dependabot::DependencyFileNotResolvable, /after verification/)
    end

    context "when the ancestor release is ignored" do
      let(:ancestor_ignored_versions) { [">= 3.0.0"] }

      it "does not bypass the ancestor's independent policy" do
        expect(checker.can_update?(requirements_to_unlock: :all)).to be false
      end
    end

    context "when the safe transitive release is ignored" do
      let(:ignored_versions) { [">= 6.0.0"] }

      it "does not propose an ancestor update that installs the ignored fix" do
        expect(checker.can_update?(requirements_to_unlock: :all)).to be false
      end
    end

    context "with an unchanged safe older resolution" do
      let(:files) { project_dependency_files("yarn_berry/catalog_multiversion_safe_direct") }
      let(:dependency) do
        parsed = Dependabot::NpmAndYarn::FileParser.new(dependency_files: files, source: nil).parse
                                                   .find { |dep| dep.name == "is-number" }
        parsed.metadata_dependencies(:all_versions).find { |dep| dep.version == "4.0.0" }
      end
      let(:security_advisories) do
        [Dependabot::SecurityAdvisory.new(
          dependency_name: "is-number",
          package_manager: "npm_and_yarn",
          vulnerable_versions: [">= 4.0.0 < 6.0.0"]
        )]
      end

      it "fixes the vulnerable branch without rejecting the unchanged safe branch" do
        expect(checker.can_update?(requirements_to_unlock: :all)).to be true
        updates = checker.updated_dependencies(requirements_to_unlock: :all)
        expect(updates.first.all_versions).to contain_exactly("2.1.0", "6.0.0")
        expect(updates.last.name).to eq("is-odd")
      end
    end
  end

  context "with an in-range vulnerable transitive dependency below a catalog consumer" do
    let(:files) { project_dependency_files("yarn_berry/catalog_transitive_policy") }
    let(:dependency) do
      Dependabot::NpmAndYarn::FileParser.new(dependency_files: files, source: nil).parse
                                        .find { |dep| dep.name == "minimatch" }
    end
    let(:ignored_versions) { [">= 3.0.6"] }
    let(:security_advisories) do
      [Dependabot::SecurityAdvisory.new(
        dependency_name: "minimatch", package_manager: "npm_and_yarn", vulnerable_versions: ["< 3.0.5"]
      )]
    end

    before do
      versions = %w(3.0.4 3.0.5 3.1.2 3.1.3 3.1.4 3.1.5)
      listing = { "name" => "minimatch", "dist-tags" => { "latest" => versions.last },
                  "versions" => versions.to_h { |version| [version, { "version" => version }] } }
      stub_request(:get, "https://registry.npmjs.org/minimatch").to_return(status: 200, body: listing.to_json)
      stub_request(:get, "https://registry.npmjs.org/minimatch/latest").to_return(status: 200, body: "{}")
      stub_request(:head, %r{https://registry.npmjs.org/minimatch/-/}).to_return(status: 200)
    end

    %i(none own).each do |unlock|
      it "rejects the native ignored release during #{unlock} unlock" do
        expect(dependency).not_to be_top_level
        expect(dependency.all_versions).to eq(["3.0.4"])
        expect(checker.lowest_security_fix_version.to_s).to eq("3.0.5")
        expect(checker.conflicting_dependencies).to be_empty
        # Prove native resolution succeeded and overshot policy, rather than
        # letting a subprocess failure satisfy this negative assertion.
        expect(checker.latest_resolvable_version).to be > Dependabot::NpmAndYarn::Version.new("3.0.5")
        expect(checker.can_update?(requirements_to_unlock: unlock)).to be false
        expect(checker.updated_dependencies(requirements_to_unlock: unlock)).to be_empty
      end
    end

    context "when the native in-range release is permitted" do
      let(:ignored_versions) { [] }

      it "verifies the transitive inventory and carries it into final generation" do
        expect(checker.can_update?(requirements_to_unlock: :own)).to be true
        updates = checker.updated_dependencies(requirements_to_unlock: :own)
        contract = Dependabot::NpmAndYarn::YarnCatalogSecurityValidation.contracts_for(updates.first).first
        expect(contract.target).to eq("minimatch")
        expect(updates.first.all_versions).to eq(contract.versions)
        expect(updates.first.metadata_string_array(:yarn_catalog_security_previous_versions)).to eq(["3.0.4"])
        changed = Dependabot::NpmAndYarn::FileUpdater.new(
          dependencies: updates, dependency_files: files, credentials: [], options: { security_updates_only: true }
        ).updated_dependency_files
        merged = files.map { |file| changed.find { |update| update.path == file.path } || file }
        target = Dependabot::NpmAndYarn::FileParser.new(dependency_files: merged, source: nil).parse
                                                   .find { |dep| dep.name == "minimatch" }
        expect(target.all_versions).to eq(contract.versions)
        expect(target.all_versions.map { |version| Dependabot::NpmAndYarn::Version.new(version) })
          .to all(be >= Dependabot::NpmAndYarn::Version.new("3.0.5"))
      end
    end
  end
end
