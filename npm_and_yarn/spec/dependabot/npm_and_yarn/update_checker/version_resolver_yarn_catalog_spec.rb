# typed: false
# frozen_string_literal: true

require "spec_helper"
require "dependabot/npm_and_yarn/file_parser"
require "dependabot/npm_and_yarn/file_updater"
require "dependabot/npm_and_yarn/update_checker"

RSpec.describe Dependabot::NpmAndYarn::UpdateChecker::VersionResolver do
  let(:files) { project_dependency_files("yarn_berry/catalog_workspace") }
  let(:dependency) do
    Dependabot::NpmAndYarn::FileParser.new(dependency_files: files, source: nil).parse.find { |dep| dep.name == "prettier" }
  end
  let(:repo_contents_path) { build_tmp_repo("yarn_berry/catalog_workspace", path: "projects") }
  let(:resolver) do
    described_class.new(
      dependency: dependency,
      dependency_files: files,
      credentials: [],
      latest_allowable_version: Gem::Version.new("2.8.6"),
      latest_version_finder: finder,
      repo_contents_path: repo_contents_path
    )
  end
  let(:finder) do
    Dependabot::NpmAndYarn::UpdateChecker::PackageLatestVersionFinder.new(
      dependency: dependency, dependency_files: files, credentials: [], ignored_versions: [], security_advisories: []
    )
  end

  describe "#catalog_version_resolvable?" do
    let(:repo_contents_path) { nil }
    let(:candidate_version) { Dependabot::NpmAndYarn::Version.new("2.8.6") }
    let(:conflict) do
      Dependabot::UpdateCheckers::PeerDependencyConflict.new(
        requirement_name: "prettier", requirement_version: "2.8.6", requiring_dep_name: "formatting-plugin"
      )
    end
    let(:previous_conflicts) { [] }

    before do
      allow(resolver).to receive(:fetch_peer_dependency_errors).with(version: candidate_version).and_return([conflict])
      allow(resolver).to receive(:fetch_peer_dependency_errors)
        .with(version: Dependabot::NpmAndYarn::Version.new("2.8.0")).and_return(previous_conflicts)
    end

    it "rejects a newly broken peer requirement on the catalog dependency" do
      expect(resolver.catalog_version_resolvable?(candidate_version)).to be false
    end

    context "when the catalog dependency requires the incompatible peer" do
      let(:conflict) do
        Dependabot::UpdateCheckers::PeerDependencyConflict.new(
          requirement_name: "formatting-plugin", requirement_version: "1.0.0", requiring_dep_name: "prettier"
        )
      end

      it "rejects the newly broken peer requirement" do
        expect(resolver.catalog_version_resolvable?(candidate_version)).to be false
      end
    end

    context "when the same dependency pair already has a peer conflict" do
      let(:previous_conflicts) do
        [Dependabot::UpdateCheckers::PeerDependencyConflict.new(
          requirement_name: "prettier", requirement_version: "2.8.0", requiring_dep_name: "formatting-plugin"
        )]
      end

      it "allows the existing conflict at the candidate version" do
        expect(resolver.catalog_version_resolvable?(candidate_version)).to be true
      end
    end

    context "when a new peer conflict involves other dependencies" do
      let(:conflict) do
        Dependabot::UpdateCheckers::PeerDependencyConflict.new(
          requirement_name: "other-package", requirement_version: "1.0.0", requiring_dep_name: "formatting-plugin"
        )
      end

      it "allows the catalog dependency update" do
        expect(resolver.catalog_version_resolvable?(candidate_version)).to be true
      end
    end
  end

  it "probes the shared catalog with install and restores every fetched source file" do
    commands = []
    helpers = Dependabot::NpmAndYarn::Helpers
    allow(helpers).to receive(:run_yarn_command).and_wrap_original do |original, command, **options|
      commands << command
      if command.start_with?("install")
        expect(YAML.safe_load_file(".yarnrc.yml").dig("catalog", "prettier")).to eq("2.8.6")
        expect(JSON.parse(File.read("packages/child/package.json")).dig("dependencies", "prettier")).to eq("catalog:")
      end
      original.call(command, **options)
    end
    expect(resolver.send(:fetch_peer_dependency_errors, version: Gem::Version.new("2.8.6"))).to eq([])
    expect(commands).to include(a_string_starting_with("install"))
    expect(commands.grep(/\A(?:add|up) /)).to be_empty
    files.each { |file| expect(File.read(File.join(repo_contents_path, file.name))).to eq(file.content) }
  end

  it "restores failed probe mutations before the next candidate runs" do
    helpers = Dependabot::NpmAndYarn::Helpers
    allow(helpers).to receive(:run_yarn_command).and_wrap_original do |original, command, **options|
      next original.call(command, **options) unless command.start_with?("install")

      File.write("package.json", "broken")
      File.write(".yarnrc.yml", "broken")
      raise Dependabot::SharedHelpers::HelperSubprocessFailed.new(message: "install failed", error_context: {})
    end
    expect { resolver.send(:fetch_peer_dependency_errors, version: Gem::Version.new("2.8.6")) }
      .to raise_error(Dependabot::DependencyFileNotResolvable, /install failed/)
    files.each { |file| expect(File.read(File.join(repo_contents_path, file.name))).to eq(file.content) }
    allow(Dependabot::NpmAndYarn::Helpers).to receive(:run_yarn_command).and_call_original
    expect(resolver.send(:fetch_peer_dependency_errors, version: Gem::Version.new("2.8.6"))).to eq([])
  end

  it "rejects an older runtime before any install or add command" do
    allow(Dependabot::NpmAndYarn::Helpers).to receive(:yarn_version).and_return("4.9.4")
    expect(Dependabot::NpmAndYarn::Helpers).not_to receive(:run_yarn_command).with(
      a_string_starting_with("install"),
      any_args
    )
    expect do
      resolver.send(:fetch_peer_dependency_errors, version: Gem::Version.new("2.8.6"))
    end.to raise_error(Dependabot::ToolFeatureNotSupported, /native catalogs/)
  end
end
