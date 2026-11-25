# typed: false
# frozen_string_literal: true

require "spec_helper"
require "dependabot/npm_and_yarn"
require "dependabot/dependency_change_builder"
require "dependabot/job"

RSpec.describe Dependabot::DependencyChangeBuilder do
  let(:files) do
    project_dependency_files("../../../../npm_and_yarn/spec/fixtures/projects/yarn_berry/catalog_workspace")
  end
  let(:original) do
    Dependabot::NpmAndYarn::FileParser.new(dependency_files: files, source: nil).parse.find { |dep| dep.name == "prettier" }
  end
  let(:dependency) do
    Dependabot::Dependency.new(
      name: original.name,
      version: "2.8.6",
      previous_version: original.version,
      package_manager: "npm_and_yarn",
      requirements: original.requirements.map { |req| req.merge(requirement: "^2.8.6") },
      previous_requirements: original.requirements
    )
  end
  let(:job) do
    instance_double(
      Dependabot::Job,
      package_manager: "npm_and_yarn",
      repo_contents_path: nil,
      credentials: [],
      experiments: {},
      security_updates_only?: false,
      cooldown: nil,
      blocked_versions: [],
      reject_external_code?: false,
      source: Dependabot::Source.new(provider: "github", repo: "test/repo", directory: "/")
    )
  end

  it "retains the edited owned config alongside the lockfile without mutating support-file inputs" do
    config = files.find { |file| file.name == ".yarnrc.yml" }
    config.support_file = true
    change = described_class.create_from(
      job: job,
      dependency_files: files,
      updated_dependencies: [dependency],
      change_source: dependency
    )
    expect(change.updated_dependency_files.map(&:name)).to contain_exactly(".yarnrc.yml", "yarn.lock")
    expect(config).to be_support_file
    expect(config.content).to include('"2.8.0"')
  end
end
