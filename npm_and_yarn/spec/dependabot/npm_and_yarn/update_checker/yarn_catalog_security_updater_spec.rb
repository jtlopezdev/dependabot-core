# typed: false
# frozen_string_literal: true

require "spec_helper"
require "dependabot/npm_and_yarn/update_checker/yarn_catalog_security_updater"

RSpec.describe Dependabot::NpmAndYarn::UpdateChecker::YarnCatalogSecurityUpdater do
  let(:files) { project_dependency_files("yarn_berry/catalog_security") }
  let(:dependency) do
    Dependabot::Dependency.new(name: "is-number", version: "4.0.0", package_manager: "npm_and_yarn", requirements: [])
  end
  let(:finder) do
    instance_double(
      Dependabot::NpmAndYarn::UpdateChecker::PackageLatestVersionFinder,
      lowest_security_fix_version: Dependabot::NpmAndYarn::Version.new("6.0.0"),
      possible_versions: [Dependabot::NpmAndYarn::Version.new("6.0.0")]
    )
  end
  let(:selected) { [] }
  let(:preview_options) { [] }
  let(:preview_files) { [] }
  let(:ancestor_contract) { nil }
  let(:factory) do
    lambda do |parent|
      selected << parent.name
      version = parent.name == "is-odd" ? "3.0.1" : "2.0.0"
      update = Dependabot::Dependency.new(
        name: parent.name,
        version: version,
        previous_version: parent.version,
        package_manager: "npm_and_yarn",
        requirements: parent.requirements.map { |req| req.merge(requirement: "^#{version}") },
        previous_requirements: parent.requirements
      )
      if ancestor_contract && parent.name == "is-odd"
        Dependabot::NpmAndYarn::YarnCatalogSecurityValidation.add_contract!(update, ancestor_contract)
      end
      instance_double(Dependabot::UpdateCheckers::Base, can_update?: true, updated_dependencies: [update])
    end
  end
  let(:updater) do
    described_class.new(
      dependency: dependency,
      dependency_files: files,
      credentials: [],
      ancestor_checker: factory,
      latest_version_finder: finder,
      security_advisories: [Dependabot::SecurityAdvisory.new(
        dependency_name: "is-number",
        package_manager: "npm_and_yarn",
        vulnerable_versions: ["< 6.0.0"]
      )]
    )
  end
  let(:keep_vulnerable) { false }
  let(:remove_target) { false }
  let(:existing_safe_version) { nil }
  let(:replacement_version) { "6.0.0" }

  def native_lock_content(data)
    data.map do |key, value|
      "#{key.to_json}:\n" + value.to_yaml.delete_prefix("---\n").lines.map { |line| "  #{line}" }.join
    end.join("\n")
  end

  before do
    root = files.find { |file| file.name == "package.json" }
    manifest = JSON.parse(root.content)
    manifest["dependencies"]["other-parent"] = "catalog:math"
    config = files.find { |file| file.name == ".yarnrc.yml" }
    config.content += "    other-parent: ^1.0.0\n"
    lock = files.find { |file| file.name == "yarn.lock" }
    current = YAML.safe_load(lock.content)
    root_record = current.values.find { |record| record["resolution"] == "catalog-security@workspace:." }
    root_record ||= current.values.find { |record| record["resolution"]&.end_with?("@workspace:.") }
    root_record.fetch("dependencies")["other-parent"] = "catalog:math"
    current["other-parent@npm:^1.0.0"] = {
      "version" => "1.0.0", "resolution" => "other-parent@npm:1.0.0", "dependencies" => { "is-number" => "npm:^4.0.0" }
    }
    if existing_safe_version
      manifest["dependencies"]["stable-parent"] = "1.0.0"
      root_record.fetch("dependencies")["stable-parent"] = "npm:1.0.0"
      current["stable-parent@npm:1.0.0"] = {
        "version" => "1.0.0", "resolution" => "stable-parent@npm:1.0.0",
        "dependencies" => { "is-number" => "npm:^#{existing_safe_version}" }
      }
      current["is-number@npm:^#{existing_safe_version}"] = {
        "version" => existing_safe_version, "resolution" => "is-number@npm:#{existing_safe_version}"
      }
    end
    root.content = JSON.generate(manifest)
    lock.content = native_lock_content(current)

    future = Marshal.load(Marshal.dump(current))
    %w(is-odd other-parent).each do |name|
      old_key = future.keys.find { |key| key.start_with?("#{name}@npm:") }
      value = future.delete(old_key)
      version = name == "is-odd" ? "3.0.1" : "2.0.0"
      value["version"] = version
      value["resolution"] = "#{name}@npm:#{version}"
      value["dependencies"] = remove_target ? {} : { "is-number" => "npm:^#{replacement_version}" }
      future["#{name}@npm:^#{version}"] = value
    end
    future.delete("is-number@npm:^4.0.0") unless keep_vulnerable
    unless remove_target
      future["is-number@npm:^#{replacement_version}"] =
        { "version" => replacement_version, "resolution" => "is-number@npm:#{replacement_version}" }
    end
    changed_config = config.dup
    changed_config.content = config.content.sub("is-odd: ^2.0.0", "is-odd: ^3.0.1").sub(
      "other-parent: ^1.0.0",
      "other-parent: ^2.0.0"
    )
    changed_lock = lock.dup
    changed_lock.content = native_lock_content(future)
    preview_files.push(changed_config, changed_lock)
    allow(Dependabot::NpmAndYarn::FileUpdater).to receive(:new) do |**options|
      preview_options << options
      instance_double(Dependabot::NpmAndYarn::FileUpdater, updated_dependency_files: [changed_config, changed_lock])
    end
  end

  it "selects both blocking ancestors and verifies their joint proposal once" do
    updates = updater.updates
    expect(selected).to contain_exactly("is-odd", "other-parent")
    expect(preview_options.size).to eq(1)
    expect(preview_options.first.fetch(:dependencies).map(&:name)).to contain_exactly("is-odd", "other-parent")
    expect(preview_options.first.fetch(:options)).to include(security_updates_only: true)
    expect(updates.map(&:name)).to eq(%w(is-number is-odd other-parent))
    expect(
      updates.drop(1).map do |dep|
        Dependabot::NpmAndYarn::YarnCatalogSecurityValidation.contracts_for(dep).first.versions
      end
    ).to eq([["6.0.0"], ["6.0.0"]])
  end

  context "when one blocking ancestor cannot be updated" do
    let(:blocked_checker) { instance_double(Dependabot::UpdateCheckers::Base) }
    let(:factory) do
      permitted_factory = super()
      lambda do |parent|
        next permitted_factory.call(parent) unless parent.name == "other-parent"

        selected << parent.name
        blocked_checker
      end
    end

    it "declines the joint proposal without previewing only the available ancestor" do
      allow(blocked_checker).to receive(:can_update?).and_return(false)
      expect(blocked_checker).not_to receive(:updated_dependencies)
      expect(Dependabot::NpmAndYarn::FileUpdater).not_to receive(:new)

      expect(updater.updates).to be_nil
      expect(blocked_checker).to have_received(:can_update?).with(requirements_to_unlock: :own)
      expect(selected).to contain_exactly("is-odd", "other-parent")
    end

    it "declines the joint proposal without a preview when an ancestor's releases are all ignored" do
      allow(blocked_checker).to receive(:can_update?).and_raise(Dependabot::AllVersionsIgnored)
      expect(blocked_checker).not_to receive(:updated_dependencies)
      expect(Dependabot::NpmAndYarn::FileUpdater).not_to receive(:new)

      expect(updater.updates).to be_nil
      expect(blocked_checker).to have_received(:can_update?).with(requirements_to_unlock: :own)
      expect(selected).to contain_exactly("is-odd", "other-parent")
    end
  end

  context "when an ancestor already carries its own security contract" do
    let(:ancestor_contract) do
      Dependabot::NpmAndYarn::YarnCatalogSecurityValidation::Contract.new(
        target: "is-odd", versions: ["3.0.1"], retained_versions: [], retained_edges: []
      )
    end

    it "preserves both contracts and rejects drift affecting only the ancestor" do
      updates = updater.updates
      parent = updates.find { |update| update.name == "is-odd" }
      contracts = Dependabot::NpmAndYarn::YarnCatalogSecurityValidation.contracts_for(parent)
      expect(contracts.map(&:target)).to contain_exactly("is-odd", "is-number")
      files_after = files.map { |file| preview_files.find { |updated| updated.path == file.path } || file }
      lock = files_after.find { |file| file.name == "yarn.lock" }
      lock.content += <<~YAML

        "is-odd@npm:3.0.0":
          version: 3.0.0
          resolution: "is-odd@npm:3.0.0"
          dependencies:
            is-number: "npm:^6.0.0"
      YAML
      expect do
        Dependabot::NpmAndYarn::YarnCatalogSecurityValidation.validate!(
          dependency_files: files_after, dependencies: updates.drop(1), credentials: []
        )
      end.to raise_error(Dependabot::DependencyFileNotResolvable, /is-odd.*after verification/)
    end
  end

  context "when a vulnerable resolution remains beside a safe version" do
    let(:keep_vulnerable) { true }

    it "declines the proposal rather than validating only the safe representative" do
      expect(updater.updates).to be_nil
    end
  end

  context "when the ancestor updates remove the target entirely" do
    let(:remove_target) { true }

    it "reports a removed informational dependency after complete parsing" do
      expect(updater.updates.first).to be_removed
      expect(updater.updates.first.metadata[:information_only]).to be true
    end
  end

  context "when ancestors replace the target with a vulnerable npm alias" do
    before do
      lock = preview_files.find { |file| file.name == "yarn.lock" }
      records = YAML.safe_load(lock.content)
      records.delete("is-number@npm:^6.0.0")
      records["number-alias@npm:is-number@^5.0.0"] = {
        "version" => "5.0.0", "resolution" => "is-number@npm:5.0.0"
      }
      %w(is-odd@npm:^3.0.1 other-parent@npm:^2.0.0).each do |key|
        records.fetch(key)["dependencies"] = { "number-alias" => "npm:is-number@^5.0.0" }
      end
      lock.content = native_lock_content(records)
    end

    it "rejects the preview instead of reporting that the target was removed" do
      expect { updater.updates }
        .to raise_error(Dependabot::ToolFeatureNotSupported, /is-number.*security verification of npm aliases/)
    end

    it "rejects an alias-only inventory during group resolution verification" do
      after = files.map { |file| preview_files.find { |updated| updated.path == file.path } || file }
      complete = Dependabot::NpmAndYarn::FileParser.new(
        dependency_files: after, source: nil, options: { dealias_packages: true }
      ).parse.find { |dep| dep.name == "is-number" }
      expect(complete.all_versions).to eq(["5.0.0"])
      expect { updater.verified_resolution_contract(after) }
        .to raise_error(Dependabot::ToolFeatureNotSupported, /is-number.*security verification of npm aliases/)
    end
  end

  context "with an existing safe release older than the permitted fix" do
    let(:existing_safe_version) { "2.1.0" }
    let(:factory) do
      inherited = super()
      lambda do |parent|
        next inherited.call(parent) unless parent.name == "stable-parent"

        selected << parent.name
        instance_double(Dependabot::UpdateCheckers::Base, can_update?: false)
      end
    end
    let(:updater) do
      described_class.new(
        dependency: dependency,
        dependency_files: files,
        credentials: [],
        ancestor_checker: factory,
        latest_version_finder: finder,
        security_advisories: [Dependabot::SecurityAdvisory.new(
          dependency_name: "is-number",
          package_manager: "npm_and_yarn",
          vulnerable_versions: [">= 4.0.0, < 6.0.0"]
        )]
      )
    end

    it "preserves the existing safe branch alongside the newly selected permitted fix" do
      expect(updater.updates).not_to be_nil
      expect(selected).to contain_exactly("is-odd", "other-parent")
      expect(updater.updates.first.all_versions).to contain_exactly("2.1.0", "6.0.0")
    end

    context "when the representative version is safe" do
      let(:dependency) do
        Dependabot::Dependency.new(
          name: "is-number",
          version: "2.1.0",
          package_manager: "npm_and_yarn",
          requirements: []
        )
      end

      it "finds blockers of the vulnerable resolution while preserving the safe branch" do
        expect(updater.updates).not_to be_nil
        expect(selected).to contain_exactly("is-odd", "other-parent")
        expect(updater.updates.first.all_versions).to contain_exactly("2.1.0", "6.0.0")
      end
    end

    context "when updated ancestors newly select that older release" do
      let(:replacement_version) { "2.1.0" }

      it "declines a downgrade even though that release was already present elsewhere" do
        expect(updater.updates).to be_nil
      end
    end
  end

  describe ".for_resolution_check" do
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
        lock.content = native_lock_content(records)
      end
    end
    let(:dependency) do
      Dependabot::NpmAndYarn::FileParser.new(dependency_files: files, source: nil).parse
                                        .find { |dep| dep.name == "is-number" }
    end
    let(:ignored_versions) { [] }
    let(:checker) do
      Dependabot::NpmAndYarn::UpdateChecker.new(
        dependency: dependency,
        dependency_files: files,
        credentials: [],
        ignored_versions: ignored_versions,
        security_advisories: [Dependabot::SecurityAdvisory.new(
          dependency_name: "is-number", package_manager: "npm_and_yarn", vulnerable_versions: [">= 4.0.0 < 6.0.0"]
        )],
        raise_on_ignored: true
      )
    end
    let(:files_after) { files.map { |file| preview_files.find { |updated| updated.path == file.path } || file } }

    before do
      listing = {
        "name" => "is-number", "dist-tags" => { "latest" => "7.0.0" },
        "versions" => %w(4.0.0 5.0.0 6.0.0 7.0.0).to_h { |version| [version, { "version" => version }] }
      }
      stub_request(:get, "https://registry.npmjs.org/is-number").to_return(status: 200, body: listing.to_json)
      stub_request(:head, %r{https://registry.npmjs.org/is-number/-/}).to_return(status: 200)
    end

    it "accepts an incidental fix below an unchanged higher safe direct representative" do
      expect(dependency.version).to eq("7.0.0")
      expect(dependency.all_versions).to contain_exactly("4.0.0", "7.0.0")
      contract = described_class.for_resolution_check(checker: checker).verified_resolution_contract(files_after)
      expect(contract.versions).to contain_exactly("6.0.0", "7.0.0")
    end

    context "when the incidental fix is ignored" do
      let(:ignored_versions) { ["6.0.0"] }

      it "rejects it using the vulnerable branch's original policy" do
        service = described_class.for_resolution_check(checker: checker)
        expect(service.verified_resolution_contract(files_after)).to be_nil
      end
    end
  end
end
