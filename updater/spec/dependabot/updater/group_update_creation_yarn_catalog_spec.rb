# typed: false
# frozen_string_literal: true

require "spec_helper"
require "dependabot/npm_and_yarn"
require "dependabot/updater/group_update_creation"
require "dependabot/updater/group_dependency_selector"
require "dependabot/dependency_snapshot"
require "dependabot/updater/error_handler"
require "dependabot/job"
require "dependabot/dependency_group"

RSpec.describe Dependabot::Updater::GroupUpdateCreation do
  let(:files) do
    project_dependency_files("../../../../npm_and_yarn/spec/fixtures/projects/yarn_berry/catalog_security")
  end
  let(:dependencies) { Dependabot::NpmAndYarn::FileParser.new(dependency_files: files, source: nil).parse }
  let(:parent) { dependencies.find { |dep| dep.name == "is-odd" } }
  let(:child) { dependencies.find { |dep| dep.name == "is-number" } }
  let(:parent_advisory_range) { "< 3.0.0" }
  let(:child_advisory_range) { "< 7.0.0" }
  let(:advisory_ranges) { { "is-odd" => parent_advisory_range, "is-number" => child_advisory_range } }
  let(:advisories) do
    advisory_ranges.to_h do |name, range|
      [name, Dependabot::SecurityAdvisory.new(
        dependency_name: name, package_manager: "npm_and_yarn", vulnerable_versions: [range]
      )]
    end
  end
  let(:group_members) { [parent, child] }
  let(:group) do
    Dependabot::DependencyGroup.new(name: "security", rules: { "patterns" => ["*"] }).tap do |result|
      result.dependencies.concat(group_members)
    end
  end
  let(:job) do
    instance_double(
      Dependabot::Job,
      source: Dependabot::Source.new(provider: "github", repo: "test/repo", directory: "/"),
      package_manager: "npm_and_yarn",
      credentials: [],
      experiments: {},
      repo_contents_path: nil,
      security_updates_only?: true,
      ignore_conditions_for: [],
      cooldown: nil,
      dependencies: %w(is-odd is-number),
      requirements_update_strategy: Dependabot::RequirementsUpdateStrategy::BumpVersions,
      log_ignore_conditions_for: nil,
      blocked_versions_for?: false,
      blocked_versions: [],
      dependency_group_to_refresh: nil,
      reject_external_code?: false,
      clone?: false
    ).tap do |result|
      allow(result).to receive(:security_advisories_for) { |dep| [advisories[dep.name]].compact }
    end
  end
  let(:real_job) do
    Dependabot::Job.new(
      id: "catalog-security",
      package_manager: "npm_and_yarn",
      dependencies: %w(is-odd is-number),
      allowed_updates: [{ "dependency-type" => "all", "update-type" => "security" }],
      existing_pull_requests: [],
      ignore_conditions: [],
      security_advisories: advisory_ranges.map do |name, range|
        { "dependency-name" => name, "affected-versions" => [range] }
      end,
      source: { "provider" => "github", "repo" => "test/repo", "directory" => "/" },
      lockfile_only: false,
      security_updates_only: true,
      update_subdependencies: false,
      updating_a_pull_request: false,
      requirements_update_strategy: nil
    )
  end

  let(:snapshot) do
    instance_double(
      Dependabot::DependencySnapshot,
      dependency_files: files,
      dependencies: dependencies,
      handled_dependencies: [],
      notices: [],
      groups: [group],
      ecosystem: "npm_and_yarn",
      add_handled_dependencies: nil
    )
  end
  let(:runner) do
    Class.new do
      include Dependabot::Updater::GroupUpdateCreation
    end.new(snapshot, instance_double(Dependabot::Updater::ErrorHandler), job, group)
  end

  def update_for(original, version)
    Dependabot::Dependency.new(
      name: original.name,
      version: version,
      previous_version: original.version,
      package_manager: "npm_and_yarn",
      requirements: original.requirements.map { |req| req.merge(requirement: "^#{version}") },
      previous_requirements: original.requirements
    )
  end

  def parent_change(updates)
    config = files.find { |file| file.name == ".yarnrc.yml" }.dup
    config.content = config.content.sub("is-odd: ^2.0.0", "is-odd: ^3.0.1")
    changed = [config, updated_parent_lock]
    manifest = ordinary_parent_manifest
    changed << manifest if manifest
    Dependabot::DependencyChange.new(
      job: job, updated_dependencies: updates, updated_dependency_files: changed, dependency_group: group
    )
  end

  def updated_parent_lock
    lock = files.find { |file| file.name == "yarn.lock" }.dup
    records = YAML.safe_load(lock.content)
    old_key = records.keys.find { |key| key.start_with?("is-odd@npm:") }
    record = records.delete(old_key)
    record["version"] = "3.0.1"
    record["resolution"] = "is-odd@npm:3.0.1"
    record.fetch("dependencies")["is-number"] = "npm:^6.0.0"
    records["is-odd@npm:^3.0.1"] = record
    record = records.delete("is-number@npm:^4.0.0")
    record["version"] = "6.0.0"
    record["resolution"] = "is-number@npm:6.0.0"
    records["is-number@npm:^6.0.0"] = record
    records.each_value do |entry|
      requirements = entry.fetch("dependencies", {})
      requirements["is-odd"] = "npm:^3.0.1" if requirements["is-odd"] == "npm:2.0.0"
    end
    lock.content = YAML.dump(records)
    lock
  end

  def ordinary_parent_manifest
    ordinary = parent.requirements.find { |req| req.file != ".yarnrc.yml" }
    return unless ordinary

    manifest = files.find { |file| file.name == ordinary.file }.dup
    manifest.content = manifest.content.sub('"is-odd": "2.0.0"', '"is-odd": "^3.0.1"')
    manifest
  end

  before do
    { "is-odd" => %w(2.0.0 3.0.1), "is-number" => %w(4.0.0 6.0.0 7.0.0) }.each do |name, versions|
      listing = { "name" => name, "dist-tags" => { "latest" => versions.last },
                  "versions" => versions.to_h { |version| [version, { "version" => version }] } }
      stub_request(:get, "https://registry.npmjs.org/#{name}").to_return(status: 200, body: listing.to_json)
      stub_request(:get, "https://registry.npmjs.org/#{name}/latest").to_return(status: 200, body: "{}")
      stub_request(:head, %r{https://registry.npmjs.org/#{name}/-/}).to_return(status: 200)
    end
    allow(runner).to receive_messages(
      prepare_workspace: nil,
      cleanup_workspace: nil,
      store_changes: nil,
      semver_rules_allow_grouping?: true
    )
  end

  it "reports a still-vulnerable incidental child instead of claiming its security fix" do
    allow(runner).to receive(:compile_updates_for).and_call_original
    expect(runner).to receive(:note_security_update_not_possible).with(
      have_attributes(name: "is-number"),
      anything,
      group
    )
    change = runner.compile_all_dependency_changes_for(group)
    final_files = files.map do |file|
      change.updated_dependency_files.find do |updated|
        updated.path == file.path
      end || file
    end
    final_child = Dependabot::NpmAndYarn::FileParser.new(dependency_files: final_files, source: nil).parse
                                                    .find { |dep| dep.name == "is-number" }
    expect(runner).to have_received(:compile_updates_for).with(have_attributes(name: "is-number"), anything, group)
    expect(final_child.all_versions).to eq(["6.0.0"])
    expect(change.updated_dependencies.map(&:name)).to eq(["is-odd"])
  end

  context "with an earlier parent proposal that fixes its child" do
    let(:child_advisory_range) { "< 6.0.0" }

    before do
      updates = [update_for(parent, "3.0.1")]
      allow(runner).to receive(:compile_updates_for).with(have_attributes(name: "is-odd"), anything, group)
                                                    .and_return(updates)
      allow(runner).to receive(:create_change_for).and_return(parent_change(updates))
    end

    it "verifies the incidental child and retains its contract for final group validation" do
      change = runner.compile_all_dependency_changes_for(group)
      incidental = change.updated_dependencies.find { |dep| dep.name == "is-number" }
      contract = Dependabot::NpmAndYarn::YarnCatalogSecurityValidation.contracts_for(incidental).first
      expect(incidental.previous_version).to eq("4.0.0")
      expect(contract.target).to eq("is-number")
      expect(contract.versions).to eq(["6.0.0"])
    end

    it "rejects an ignored incidental release against the original target policy" do
      allow(job).to receive(:ignore_conditions_for).with(have_attributes(name: "is-number")).and_return([">= 6.0.0"])
      expect { runner.compile_all_dependency_changes_for(group) }.to raise_error(Dependabot::AllVersionsIgnored)
    end

    it "reports removal of the vulnerable child with a verified empty resolution contract" do
      listing = { "name" => "is-number", "versions" => { "4.0.0" => { "version" => "4.0.0" } } }
      stub_request(:get, "https://registry.npmjs.org/is-number").to_return(status: 200, body: listing.to_json)
      updates = [update_for(parent, "3.0.1")]
      change = parent_change(updates)
      lock = change.updated_dependency_files.find { |file| file.name == "yarn.lock" }
      records = YAML.safe_load(lock.content)
      records.delete("is-number@npm:^6.0.0")
      records.fetch("is-odd@npm:^3.0.1").delete("dependencies")
      lock.content = YAML.dump(records)
      allow(runner).to receive(:create_change_for).and_return(change)
      result = runner.compile_all_dependency_changes_for(group)
      removed = result.updated_dependencies.find { |dep| dep.name == "is-number" }
      expect(removed).to be_removed
      expect(removed).to be_informational_only
      expect(removed.previous_version).to eq("4.0.0")
      contract = Dependabot::NpmAndYarn::YarnCatalogSecurityValidation.contracts_for(removed).first
      expect(contract.versions).to be_empty
    end

    context "when the safe direct representative stays unchanged" do
      let(:files) do
        project_dependency_files(
          "../../../../npm_and_yarn/spec/fixtures/projects/yarn_berry/catalog_multiversion_safe_direct"
        )
      end
      let(:child_advisory_range) { ">= 4.0.0 < 6.0.0" }
      let(:job) { real_job }

      it "retains the complete changed inventory and verifies its security contract" do
        expect(child.version).to eq("2.1.0")
        change = runner.compile_all_dependency_changes_for(group)
        incidental = change.updated_dependencies.find { |dep| dep.name == "is-number" }
        expect(incidental.version).to eq("2.1.0")
        expect(incidental.all_versions).to contain_exactly("2.1.0", "6.0.0")
        expect(incidental).to be_informational_only
        contract = Dependabot::NpmAndYarn::YarnCatalogSecurityValidation.contracts_for(incidental).first
        expect(contract.versions).to contain_exactly("2.1.0", "6.0.0")
        selector = Dependabot::Updater::GroupDependencySelector.new(group: group, dependency_snapshot: snapshot)
        selector.filter_to_group!(change)
        expect(change.updated_dependencies).to include(incidental)
      end
    end
  end

  context "when the child is processed before its parent" do
    let(:files) do
      project_dependency_files(
        "../../../../npm_and_yarn/spec/fixtures/projects/yarn_berry/catalog_security_multiversion"
      )
    end
    let(:child_advisory_range) { ">= 4.0.0 < 6.0.0" }
    let(:group_members) { [child, parent] }
    let(:parent_advisory_range) { ">= 2.0.0 < 3.0.0" }
    let(:job) { real_job }

    it "keeps the fixed child through change creation and group filtering, preserving its safe branch" do
      expect(child).not_to be_top_level
      expect(child.version).to eq("3.0.0")
      expect(child.all_versions).to contain_exactly("3.0.0", "4.0.0")
      change = runner.compile_all_dependency_changes_for(group)
      fixed = change.updated_dependencies.find { |dep| dep.name == "is-number" }
      expect(fixed).to be_informational_only
      expect(fixed.version).to eq(fixed.previous_version)
      expect(fixed.all_versions).to contain_exactly("3.0.0", "6.0.0")
      contract = Dependabot::NpmAndYarn::YarnCatalogSecurityValidation.contracts_for(fixed).first
      expect(contract.retained_versions).to eq(["3.0.0"])
      selector = Dependabot::Updater::GroupDependencySelector.new(group: group, dependency_snapshot: snapshot)
      selector.filter_to_group!(change)
      expect(change.updated_dependencies.map(&:name).uniq).to contain_exactly("is-number", "is-odd")
    end
  end

  context "when the representative changes but the installed version set does not" do
    let(:files) do
      project_dependency_files("../../../../npm_and_yarn/spec/fixtures/projects/yarn_berry/catalog_multiversion")
    end
    let(:child_advisory_range) { ">= 4.0.0 < 6.0.0" }

    it "checks the remaining vulnerable resolution before deducing an incidental update" do
      original = Dependabot::Dependency.new(
        name: child.name,
        version: "4.0.0",
        package_manager: child.package_manager,
        requirements: child.requirements,
        metadata: child.metadata
      )
      expect(original.all_versions.sort).to eq(child.all_versions.sort)
      expect(child.version).to eq("6.0.0")
      expect(runner.deduce_catalog_security_update(child, original, files, files, group)).to be_nil
      expect(snapshot.handled_dependencies).to be_empty
    end
  end

  context "when a target checked first is fixed by a later parent" do
    let(:job) { real_job }
    let(:group_members) { [child, parent] }
    let(:child_advisory_range) { ">= 4.0.0 < 6.0.0" }
    let(:files) do
      super().tap do |result|
        root = result.find { |file| file.name == "package.json" }
        manifest = JSON.parse(root.content)
        manifest.fetch("dependencies")["is-number"] = "catalog:math"
        root.content = JSON.generate(manifest)
        result.find { |file| file.name == ".yarnrc.yml" }.content += "    is-number: 7.0.0\n"
        lock = result.find { |file| file.name == "yarn.lock" }
        records = YAML.safe_load(lock.content)
        records.fetch("catalog-security@workspace:.").fetch("dependencies")["is-number"] = "catalog:math"
        records["is-number@npm:7.0.0"] = { "version" => "7.0.0", "resolution" => "is-number@npm:7.0.0" }
        lock.content = YAML.dump(records)
      end
    end

    before do
      updates = [update_for(parent, "3.0.1")]
      allow(runner).to receive(:compile_updates_for).and_call_original
      allow(runner).to receive(:compile_updates_for).with(have_attributes(name: "is-odd"), anything, group)
                                                    .and_return(updates)
      allow(runner).to receive(:create_change_for).and_return(parent_change(updates))
    end

    it "reconciles the fixed inventory and suppresses the earlier failure after group filtering" do
      expect(child.version).to eq("7.0.0")
      expect(child.all_versions).to contain_exactly("4.0.0", "7.0.0")
      change = runner.compile_all_dependency_changes_for(group)
      expect(runner).to have_received(:compile_updates_for).with(have_attributes(name: "is-number"), anything, group)
      expect(runner.security_update_failures.fetch("is-number").error_type).to eq("security_update_not_possible")
      target = change.updated_dependencies.find { |dependency| dependency.name == "is-number" }
      expect(target).to be_informational_only
      expect(target.version).to eq("7.0.0")
      expect(target.previous_version).to eq("7.0.0")
      expect(target.all_versions).to contain_exactly("6.0.0", "7.0.0")
      selector = Dependabot::Updater::GroupDependencySelector.new(group: group, dependency_snapshot: snapshot)
      selector.filter_to_group!(change)
      expect(change.updated_dependencies).to include(target)
      expect(runner).not_to receive(:report_security_update_failure)
      runner.report_security_update_failures(change)
    end

    context "when the later parent still leaves a vulnerable resolution" do
      let(:child_advisory_range) { ">= 4.0.0 < 7.0.0" }

      it "preserves the parent-only partial group and the child's failure" do
        change = runner.compile_all_dependency_changes_for(group)
        expect(change.updated_dependencies.map(&:name)).to eq(["is-odd"])
        expect(runner).to receive(:report_security_update_failure).with("is-number")
        runner.report_security_update_failures(change)
      end
    end

    context "when the later repair is ignored by the original target policy" do
      before do
        allow(job).to receive(:ignore_conditions_for).and_call_original
        allow(job).to receive(:ignore_conditions_for).with(have_attributes(name: "is-number")).and_return(["6.0.0"])
      end

      it "rejects the incidental repair rather than grandfathering its new version" do
        expect { runner.compile_all_dependency_changes_for(group) }
          .to raise_error(Dependabot::DependencyFileNotResolvable, /is-number.*original target policy/)
      end
    end

    it "does not recover a member already handled by another group" do
      allow(snapshot).to receive(:handled_dependencies).and_return(["is-number"])
      change = runner.compile_all_dependency_changes_for(group)
      expect(change.updated_dependencies.map(&:name)).to eq(["is-odd"])
      expect(runner).not_to have_received(:compile_updates_for)
        .with(have_attributes(name: "is-number"), anything, group)
    end

    it "does not recover a member skipped for another directory" do
      child.directory = "/elsewhere"
      change = runner.compile_all_dependency_changes_for(group)
      expect(change.updated_dependencies.map(&:name)).to eq(["is-odd"])
      expect(runner).not_to have_received(:compile_updates_for)
        .with(have_attributes(name: "is-number"), anything, group)
    end
  end

  context "when an earlier parent only fixes one vulnerable child branch" do
    let(:child_advisory_range) { "< 6.0.0" }
    let(:files) do
      super().tap do |result|
        root = result.find { |file| file.name == "package.json" }
        manifest = JSON.parse(root.content)
        manifest["dependencies"]["other-parent"] = "1.0.0"
        root.content = JSON.generate(manifest)
        lock = result.find { |file| file.name == "yarn.lock" }
        records = YAML.safe_load(lock.content)
        records.fetch("catalog-security@workspace:.").fetch("dependencies")["other-parent"] = "npm:1.0.0"
        records["other-parent@npm:1.0.0"] = {
          "version" => "1.0.0", "resolution" => "other-parent@npm:1.0.0",
          "dependencies" => { "is-number" => "npm:^4.0.0" }
        }
        lock.content = YAML.dump(records)
      end
    end
    let(:first_updates) { [update_for(parent, "3.0.1")] }
    let(:first_change) do
      parent_change(first_updates).tap do |change|
        lock = change.updated_dependency_files.find { |file| file.name == "yarn.lock" }
        records = YAML.safe_load(lock.content)
        records.fetch("is-odd@npm:^3.0.1").fetch("dependencies")["is-number"] = "npm:^6.0.0"
        records.fetch("other-parent@npm:1.0.0").fetch("dependencies")["is-number"] = "npm:^4.0.0"
        original = YAML.safe_load(files.find { |file| file.name == "yarn.lock" }.content)
        records["is-number@npm:^4.0.0"] = original.fetch("is-number@npm:^4.0.0")
        lock.content = YAML.dump(records)
      end
    end
    let(:remaining_parent) { dependencies.find { |dep| dep.name == "other-parent" } }
    let(:last_updates) do
      [Dependabot::Dependency.new(
        name: "is-number",
        version: "7.0.0",
        previous_version: "4.0.0",
        package_manager: "npm_and_yarn",
        requirements: [],
        previous_requirements: [],
        metadata: { information_only: true }
      ), update_for(remaining_parent, "2.0.0")]
    end
    let(:last_change) do
      lock = first_change.updated_dependency_files.find { |file| file.name == "yarn.lock" }.dup
      records = YAML.safe_load(lock.content)
      records.delete("is-number@npm:^4.0.0")
      records.delete("other-parent@npm:1.0.0")
      records["is-number@npm:^7.0.0"] = { "version" => "7.0.0", "resolution" => "is-number@npm:7.0.0" }
      records["other-parent@npm:^2.0.0"] = {
        "version" => "2.0.0", "resolution" => "other-parent@npm:2.0.0",
        "dependencies" => { "is-number" => "npm:^7.0.0" }
      }
      records.fetch("catalog-security@workspace:.").fetch("dependencies")["other-parent"] = "npm:^2.0.0"
      lock.content = YAML.dump(records)
      root = files.find { |file| file.name == "package.json" }.dup
      manifest = JSON.parse(root.content)
      manifest.fetch("dependencies")["other-parent"] = "^2.0.0"
      root.content = JSON.generate(manifest)
      Dependabot::DependencyChange.new(
        job: job, updated_dependencies: last_updates, updated_dependency_files: [root, lock], dependency_group: group
      )
    end

    before do
      allow(runner).to receive(:compile_updates_for).with(have_attributes(name: "is-odd"), anything, group)
                                                    .and_return(first_updates)
      allow(runner).to receive(:compile_updates_for).with(have_attributes(name: "is-number"), anything, group)
                                                    .and_return(last_updates)
      allow(runner).to receive(:create_change_for).with(have_attributes(name: "is-odd"), first_updates, anything, group)
                                                  .and_return(first_change)
      allow(runner).to receive(:create_change_for).with(
        have_attributes(name: "is-number"),
        last_updates,
        anything,
        group
      )
                                                  .and_return(last_change)
    end

    it "verifies the completed proposal against the initial child inventory" do
      change = runner.compile_all_dependency_changes_for(group)
      actual = change.updated_dependencies.find { |dep| dep.name == "other-parent" }
      contract = Dependabot::NpmAndYarn::YarnCatalogSecurityValidation.contracts_for(actual).first
      expect(contract.versions).to contain_exactly("6.0.0", "7.0.0")
      expect(contract.retained_versions).to be_empty
    end

    it "rejects an ignored release introduced before the remaining branch was fixed" do
      allow(job).to receive(:ignore_conditions_for).with(have_attributes(name: "is-number")).and_return(["6.0.0"])
      expect { runner.compile_all_dependency_changes_for(group) }
        .to raise_error(Dependabot::DependencyFileNotResolvable, /is-number.*original target policy/)
    end
  end

  context "when a later group member changes an earlier security target" do
    let(:child_advisory_range) { "< 6.0.0" }
    let(:advisory_ranges) { super().merge("other-parent" => "< 2.0.0") }
    let(:files) do
      super().tap do |result|
        root = result.find { |file| file.name == "package.json" }
        manifest = JSON.parse(root.content)
        manifest["dependencies"]["other-parent"] = "1.0.0"
        root.content = JSON.generate(manifest)
        lock = result.find { |file| file.name == "yarn.lock" }
        records = YAML.safe_load(lock.content)
        records.fetch("catalog-security@workspace:.").fetch("dependencies")["other-parent"] = "npm:1.0.0"
        records["other-parent@npm:1.0.0"] = { "version" => "1.0.0", "resolution" => "other-parent@npm:1.0.0" }
        lock.content = YAML.dump(records)
      end
    end
    let(:later_parent) { dependencies.find { |dep| dep.name == "other-parent" } }
    let(:group_members) { [child, later_parent] }

    let(:ancestor_update) do
      update_for(parent, "3.0.1").tap do |update|
        Dependabot::NpmAndYarn::YarnCatalogSecurityValidation.add_contract!(
          update,
          Dependabot::NpmAndYarn::YarnCatalogSecurityValidation::Contract.new(
            target: "is-number", versions: ["6.0.0"], retained_versions: [], retained_edges: []
          )
        )
      end
    end
    let(:informational) do
      Dependabot::Dependency.new(
        name: "is-number",
        version: "6.0.0",
        previous_version: child.version,
        package_manager: "npm_and_yarn",
        requirements: [],
        previous_requirements: [],
        metadata: { information_only: true }
      )
    end
    let(:first_updates) { [informational, ancestor_update] }
    let(:first_change) { parent_change(first_updates) }
    let(:later_updates) { [update_for(later_parent, "2.0.0")] }
    let(:later_change) do
      later_lock = first_change.updated_dependency_files.find { |file| file.name == "yarn.lock" }.dup
      records = YAML.safe_load(later_lock.content)
      records.delete("other-parent@npm:1.0.0")
      records["other-parent@npm:^2.0.0"] = {
        "version" => "2.0.0", "resolution" => "other-parent@npm:2.0.0",
        "dependencies" => { "is-number" => "npm:^7.0.0" }
      }
      records["is-number@npm:^7.0.0"] = { "version" => "7.0.0", "resolution" => "is-number@npm:7.0.0" }
      records.fetch("catalog-security@workspace:.").fetch("dependencies")["other-parent"] = "npm:^2.0.0"
      later_lock.content = YAML.dump(records)
      later_manifest = files.find { |file| file.name == "package.json" }.dup
      manifest = JSON.parse(later_manifest.content)
      manifest.fetch("dependencies")["other-parent"] = "^2.0.0"
      later_manifest.content = JSON.generate(manifest)
      Dependabot::DependencyChange.new(
        job: job,
        updated_dependencies: later_updates,
        updated_dependency_files: [later_manifest, later_lock],
        dependency_group: group
      )
    end

    before do
      listing = { "name" => "other-parent", "dist-tags" => { "latest" => "2.0.0" },
                  "versions" => %w(1.0.0 2.0.0).to_h { |version| [version, { "version" => version }] } }
      stub_request(:get, "https://registry.npmjs.org/other-parent").to_return(status: 200, body: listing.to_json)
      stub_request(:get, "https://registry.npmjs.org/other-parent/latest").to_return(status: 200, body: "{}")
      stub_request(:head, %r{https://registry.npmjs.org/other-parent/-/}).to_return(status: 200)
      allow(runner).to receive(:compile_updates_for).with(have_attributes(name: "is-number"), anything, group)
                                                    .and_return(first_updates)
      allow(runner).to receive(:compile_updates_for).with(have_attributes(name: "other-parent"), anything, group)
                                                    .and_return(later_updates)
      allow(runner).to receive(:create_change_for).with(
        have_attributes(name: "is-number"),
        first_updates,
        anything,
        group
      )
                                                  .and_return(first_change)
      allow(runner).to receive(:create_change_for).with(
        have_attributes(name: "other-parent"),
        later_updates,
        anything,
        group
      )
                                                  .and_return(later_change)
    end

    it "reverifies a later safe resolution against the initial policy and reports the final inventory" do
      change = runner.compile_all_dependency_changes_for(group)
      target = change.updated_dependencies.find { |dependency| dependency.name == "is-number" }
      expect(target.all_versions).to contain_exactly("6.0.0", "7.0.0")
      contracts = change.updated_dependencies.flat_map do |dependency|
        Dependabot::NpmAndYarn::YarnCatalogSecurityValidation.contracts_for(dependency)
      end
      expect(contracts.select { |contract| contract.target == "is-number" }.map(&:versions).uniq)
        .to eq([%w(6.0.0 7.0.0)])
    end

    it "rejects a later resolution ignored by the original target policy" do
      allow(job).to receive(:ignore_conditions_for).with(have_attributes(name: "is-number")).and_return(["7.0.0"])
      expect { runner.compile_all_dependency_changes_for(group) }
        .to raise_error(Dependabot::DependencyFileNotResolvable, /is-number.*original target policy/)
    end

    it "rejects a later resolution vulnerable under the original target advisories" do
      advisory = Dependabot::SecurityAdvisory.new(
        dependency_name: "is-number", package_manager: "npm_and_yarn", vulnerable_versions: ["< 6.0.0", ">= 7.0.0"]
      )
      allow(job).to receive(:security_advisories_for).with(have_attributes(name: "is-number")).and_return([advisory])
      expect { runner.compile_all_dependency_changes_for(group) }
        .to raise_error(Dependabot::DependencyFileNotResolvable, /is-number.*original target policy/)
    end

    it "reports a previously fixed target removed by a later group member" do
      lock = later_change.updated_dependency_files.find { |file| file.name == "yarn.lock" }
      records = YAML.safe_load(lock.content)
      records.delete("is-number@npm:^6.0.0")
      records.delete("is-number@npm:^7.0.0")
      records.fetch("is-odd@npm:^3.0.1").delete("dependencies")
      records.fetch("other-parent@npm:^2.0.0").delete("dependencies")
      lock.content = YAML.dump(records)
      change = runner.compile_all_dependency_changes_for(group)
      target = change.updated_dependencies.find { |dependency| dependency.name == "is-number" }
      expect(target).to be_removed
      expect(target).to be_informational_only
      expect(target.all_versions).to be_empty
    end

    context "when an old safe resolution is retained" do
      let(:ancestor_update) { update_for(parent, "3.0.1") }
      let(:files) do
        super().tap do |result|
          root = result.find { |file| file.name == "package.json" }
          manifest = JSON.parse(root.content)
          manifest["dependencies"]["stable-parent"] = "1.0.0"
          root.content = JSON.generate(manifest)
          lock = result.find { |file| file.name == "yarn.lock" }
          records = YAML.safe_load(lock.content)
          records.fetch("catalog-security@workspace:.").fetch("dependencies")["stable-parent"] = "npm:1.0.0"
          records["stable-parent@npm:1.0.0"] = {
            "version" => "1.0.0", "resolution" => "stable-parent@npm:1.0.0",
            "dependencies" => { "is-number" => "npm:^3.0.0" }
          }
          records["is-number@npm:^3.0.0"] = { "version" => "3.0.0", "resolution" => "is-number@npm:3.0.0" }
          lock.content = YAML.dump(records)
        end
      end
      let(:child_advisory_range) { ">= 4.0.0 < 6.0.0" }

      it "rejects a new edge to that resolution even when the final version set is unchanged" do
        lock = later_change.updated_dependency_files.find { |file| file.name == "yarn.lock" }
        records = YAML.safe_load(lock.content)
        records.delete("is-number@npm:^7.0.0")
        records.fetch("other-parent@npm:^2.0.0").fetch("dependencies")["is-number"] = "npm:^3.0.0"
        lock.content = YAML.dump(records)
        expect { runner.compile_all_dependency_changes_for(group) }
          .to raise_error(Dependabot::DependencyFileNotResolvable, /is-number.*original target policy/)
      end
    end
  end
end
