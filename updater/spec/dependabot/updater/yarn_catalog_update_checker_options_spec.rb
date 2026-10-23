# typed: false
# frozen_string_literal: true

require "spec_helper"
require "dependabot/npm_and_yarn"
require "dependabot/updater/yarn_catalog_update_checker_options"

RSpec.describe Dependabot::Updater::YarnCatalogUpdateCheckerOptions do
  let(:files) do
    project_dependency_files("../../../../npm_and_yarn/spec/fixtures/projects/yarn_berry/catalog_security")
  end
  let(:ancestor) do
    Dependabot::NpmAndYarn::FileParser.new(dependency_files: files, source: nil).parse.find { |dep| dep.name == "is-odd" }
  end
  let(:security_advisories) do
    [Dependabot::SecurityAdvisory.new(
      dependency_name: "is-odd", package_manager: "npm_and_yarn", vulnerable_versions: ["< 3.0.1"]
    )]
  end
  let(:job) do
    instance_double(
      Dependabot::Job,
      package_manager: "npm_and_yarn",
      experiments: {},
      credentials: [],
      requirements_update_strategy: Dependabot::RequirementsUpdateStrategy::BumpVersions
    )
  end

  it "supplies the ancestor's ignore and security policies without a security cooldown" do
    config = files.find { |file| file.name == ".yarnrc.yml" }
    config.content = config.content.sub("catalogs:", "'catalogs' :")
    allow(job).to receive(:ignore_conditions_for).with(ancestor).and_return([">= 3.0.0"])
    allow(job).to receive(:security_advisories_for).with(ancestor).and_return(security_advisories)
    options = described_class.for(job: job, dependency_files: files)
    checker = options.fetch(:yarn_catalog_ancestor_checker).call(ancestor)
    expect(checker.ignored_versions).to eq([">= 3.0.0"])
    expect(checker.security_advisories).to eq(security_advisories)
    expect(checker.raise_on_ignored).to be true
    expect(checker.update_cooldown).to be_nil
  end
end
