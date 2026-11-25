# typed: false
# frozen_string_literal: true

require "spec_helper"
require "dependabot/npm_and_yarn/yarn_catalog_security_validation"

RSpec.describe Dependabot::NpmAndYarn::YarnCatalogSecurityValidation do
  let(:files) { project_dependency_files("yarn_berry/catalog_multiversion") }
  let(:updates) do
    { "prettier" => ["2.8.7"], "is-number" => %w(4.0.0 6.0.0) }.map do |name, versions|
      Dependabot::Dependency.new(
        name: "ancestor-of-#{name}",
        version: "1.0.0",
        package_manager: "npm_and_yarn",
        requirements: [],
        metadata: { yarn_catalog_security_contracts: [{
          "target" => name, "versions" => versions, "retained_versions" => [], "retained_edges" => []
        }] }
      )
    end
  end

  { "prettier" => %w(2.8.7 2.8.8), "is-number" => %w(6.0.0 7.0.0) }.each do |name, (old_version, new_version)|
    it "rejects drift in the #{name} contract among accumulated targets" do
      expect do
        described_class.validate!(dependency_files: files, dependencies: updates, credentials: [])
      end.not_to raise_error
      lock = files.find { |file| file.name == "yarn.lock" }
      lock.content = lock.content.sub("version: #{old_version}", "version: #{new_version}")
      expect { described_class.validate!(dependency_files: files, dependencies: updates, credentials: []) }
        .to raise_error(Dependabot::DependencyFileNotResolvable, /#{name}.*after verification/)
    end
  end

  it "rejects a new branch to a grandfathered release even when the complete version set is unchanged" do
    update = updates.last
    described_class.add_contract!(
      update,
      described_class::Contract.new(
        target: "is-number",
        versions: %w(4.0.0 6.0.0),
        retained_versions: ["4.0.0"],
        retained_edges: [["is-odd@2.0.0", "is-number@4.0.0"].to_json]
      )
    )
    expect { described_class.validate!(dependency_files: files, dependencies: updates, credentials: []) }
      .not_to raise_error
    lock = files.find { |file| file.name == "yarn.lock" }
    lock.content += <<~YAML

      "new-parent@npm:1.0.0":
        version: 1.0.0
        resolution: "new-parent@npm:1.0.0"
        dependencies:
          is-number: "npm:^4.0.0"
    YAML
    expect { described_class.validate!(dependency_files: files, dependencies: updates, credentials: []) }
      .to raise_error(Dependabot::DependencyFileNotResolvable, /is-number.*disallowed branch/)
  end

  it "validates every composed contract after dependency metadata is serialized" do
    combined = updates.first
    described_class.add_contract!(combined, described_class.contracts_for(updates.last).first)
    roundtrip = Dependabot::Dependency.new(
      name: combined.name,
      version: combined.version,
      package_manager: combined.package_manager,
      requirements: [],
      metadata: JSON.parse(JSON.generate(combined.metadata))
    )
    expect { described_class.validate!(dependency_files: files, dependencies: [roundtrip], credentials: []) }
      .not_to raise_error
    lock = files.find { |file| file.name == "yarn.lock" }
    lock.content = lock.content.sub("version: 6.0.0", "version: 7.0.0")
    expect { described_class.validate!(dependency_files: files, dependencies: [roundtrip], credentials: []) }
      .to raise_error(Dependabot::DependencyFileNotResolvable, /is-number.*after verification/)
  end

  it "rejects a target alias even when its version is already in the verified inventory" do
    lock = files.find { |file| file.name == "yarn.lock" }
    lock.content += <<~YAML

      "zzz-number@npm:is-number@^4.0.0":
        version: 4.0.0
        resolution: "is-number@npm:4.0.0"
    YAML
    expect { described_class.validate!(dependency_files: files, dependencies: updates, credentials: []) }
      .to raise_error(Dependabot::ToolFeatureNotSupported, /is-number.*security verification of npm aliases/)
  end

  it "does not reject aliases for packages outside the security contracts" do
    lock = files.find { |file| file.name == "yarn.lock" }
    lock.content += <<~YAML

      "other-alias@npm:is-odd@^2.0.0":
        version: 2.0.0
        resolution: "is-odd@npm:2.0.0"
    YAML
    expect { described_class.validate!(dependency_files: files, dependencies: updates, credentials: []) }
      .not_to raise_error
  end
end
