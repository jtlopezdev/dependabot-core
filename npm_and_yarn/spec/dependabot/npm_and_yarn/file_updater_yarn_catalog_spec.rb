# typed: false
# frozen_string_literal: true

require "spec_helper"
require "dependabot/npm_and_yarn/file_parser"
require "dependabot/npm_and_yarn/file_updater"

RSpec.describe Dependabot::NpmAndYarn::FileUpdater do
  let(:files) { project_dependency_files("yarn_berry/catalog_workspace") }
  let(:original_dependency) do
    Dependabot::NpmAndYarn::FileParser.new(dependency_files: files, source: nil).parse.find { |dep| dep.name == "prettier" }
  end
  let(:new_requirement) { "^2.8.6" }
  let(:dependency) do
    Dependabot::Dependency.new(
      name: "prettier",
      version: "2.8.6",
      previous_version: "2.8.0",
      package_manager: "npm_and_yarn",
      requirements: original_dependency.requirements.map { |req| req.merge(requirement: new_requirement) },
      previous_requirements: original_dependency.requirements
    )
  end
  let(:updater) { described_class.new(dependency_files: files, dependencies: [dependency], credentials: []) }

  before do
    files.find { |file| file.name == ".yarnrc.yml" }.support_file = true
  end

  def expect_immutable_install(updated)
    Dependabot::SharedHelpers.in_a_temporary_directory do
      files.each do |file|
        FileUtils.mkdir_p(File.dirname(file.name))
        File.write(file.name, (updated.find { |changed| changed.name == file.name } || file).content)
      end
      expect { Dependabot::NpmAndYarn::Helpers.run_yarn_command("install --immutable --mode=skip-build") }
        .not_to raise_error
    end
  end

  it "returns a source-preserving configuration edit and the exact target lockfile with catalog references" do
    updated = updater.updated_dependency_files
    expect(updated.map(&:name)).to contain_exactly(".yarnrc.yml", "yarn.lock")
    config = updated.find { |file| file.name == ".yarnrc.yml" }
    expect(config.support_file?).to be false
    expect(config.content).to eq(files.find { |file| file.name == ".yarnrc.yml" }.content.sub('"2.8.0"', '"^2.8.6"'))
    lock = YAML.safe_load(updated.find { |file| file.name == "yarn.lock" }.content)
    expect(lock.fetch("prettier@npm:^2.8.6").fetch("version")).to eq("2.8.6")
    expect(lock.fetch("catalog-child@workspace:packages/child").dig("dependencies", "prettier")).to eq("catalog:")

    expect_immutable_install(updated)
  end

  context "when only the lockfile changes" do
    let(:new_requirement) { "^2.8.0" }

    before do
      config = files.find { |file| file.name == ".yarnrc.yml" }
      config.content = config.content.sub('"2.8.0"', '"^2.8.0"')
      lock = files.find { |file| file.name == "yarn.lock" }
      lock.content = lock.content.sub("prettier@npm:2.8.0", "prettier@npm:^2.8.0")
    end

    it "preserves the range while selecting the approved locked version" do
      updated = updater.updated_dependency_files
      expect(updated.map(&:name)).to eq(["yarn.lock"])
      lock = YAML.safe_load(updated.first.content)
      expect(lock.fetch("prettier@npm:^2.8.0").fetch("version")).to eq("2.8.6")
      expect(lock.fetch("catalog-workspace@workspace:.").dig("dependencies", "prettier")).to eq("catalog:")
      expect(lock.fetch("catalog-child@workspace:packages/child").dig("dependencies", "prettier")).to eq("catalog:")
      expect_immutable_install(updated)
    end
  end

  context "with a checkout reused by subsequent checks" do
    let(:repo_contents_path) { build_tmp_repo("yarn_berry/catalog_workspace", path: "projects") }
    let(:updater) do
      described_class.new(
        dependency_files: files,
        dependencies: [dependency],
        credentials: [],
        repo_contents_path: repo_contents_path
      )
    end

    it "restores source inputs after returning the successful update" do
      expect(updater.updated_dependency_files.map(&:name)).to contain_exactly(".yarnrc.yml", "yarn.lock")
      files.each { |file| expect(File.read(File.join(repo_contents_path, file.name))).to eq(file.content) }
    end

    it "restores source inputs after an install failure" do
      helpers = Dependabot::NpmAndYarn::Helpers
      allow(helpers).to receive(:run_yarn_command).and_wrap_original do |original, command, **options|
        next original.call(command, **options) unless command.start_with?("install")

        File.write(".yarnrc.yml", "broken")
        File.write("package.json", "broken")
        raise Dependabot::SharedHelpers::HelperSubprocessFailed.new(
          message: "forced catalog install failure",
          error_context: {}
        )
      end
      expect { updater.updated_dependency_files }.to raise_error(StandardError, /forced catalog install failure/)
      files.each { |file| expect(File.read(File.join(repo_contents_path, file.name))).to eq(file.content) }
    end
  end

  context "with current Yarn with a project rooted in a repository subdirectory" do
    let(:files) do
      project_dependency_files("yarn_berry/catalog_workspace").map do |file|
        Dependabot::DependencyFile.new(name: file.name, content: file.content, directory: "/frontend")
      end
    end

    before do
      files.find { |file| file.name == "package.json" }.content =
        files.find { |file| file.name == "package.json" }.content.sub("yarn@4.10.1", "yarn@4.18.1")
    end

    it "preserves the original config despite runtime rewrites and returns an immutable install" do
      updated = updater.updated_dependency_files
      expect(updated.find { |file| file.name == ".yarnrc.yml" }.content)
        .to eq(files.find { |file| file.name == ".yarnrc.yml" }.content.sub('"2.8.0"', '"^2.8.6"'))
      expect(updated.map(&:directory).uniq).to eq(["/frontend"])
      expect_immutable_install(updated)
    end
  end

  context "with a runtime predating native catalogs" do
    before do
      root = files.find { |file| file.name == "package.json" }
      root.content = root.content.sub("yarn@4.10.1", "yarn@4.1.0")
    end

    it "reports the unsupported feature before running an install" do
      expect(Dependabot::NpmAndYarn::Helpers).not_to receive(:run_yarn_command)
        .with(a_string_starting_with("install"), any_args)
      expect { updater.updated_dependency_files }.to raise_error(Dependabot::ToolFeatureNotSupported, /native catalogs/)
    end
  end

  context "when the catalog resolves to a local workspace" do
    let(:files) { project_dependency_files("yarn_berry/catalog_transparent_workspace") }
    let(:dependency) do
      Dependabot::Dependency.new(
        name: "is-number",
        version: "7.0.0",
        previous_version: "0.0.0-use.local",
        package_manager: "npm_and_yarn",
        requirements: [{
          requirement: "^7.0.0", file: ".yarnrc.yml", groups: ["dependencies"], source: nil,
          metadata: { yarn_catalog_reference: "catalog:", yarn_catalog_package: "is-number" }
        }]
      )
    end

    it "rejects replacing the local workspace with a registry package before installation" do
      expect(Dependabot::NpmAndYarn::Helpers).not_to receive(:run_yarn_command)
      expect { updater.updated_dependency_files }
        .to raise_error(Dependabot::ToolFeatureNotSupported, /local workspace/)
    end
  end

  %w(catalog ordinary).each do |second_kind|
    context "with a grouped #{second_kind} dependency of a different name" do
      let(:second_dependency) do
        original = Dependabot::NpmAndYarn::FileParser.new(dependency_files: files, source: nil).parse
                                                     .find { |dep| dep.name == "is-odd" }
        Dependabot::Dependency.new(
          name: original.name,
          version: "3.0.1",
          previous_version: original.version,
          package_manager: "npm_and_yarn",
          requirements: original.requirements.map { |req| req.merge(requirement: "^3.0.1") },
          previous_requirements: original.requirements
        )
      end
      let(:updater) do
        described_class.new(dependency_files: files, dependencies: [dependency, second_dependency], credentials: [])
      end

      before do
        root = files.find { |file| file.name == "package.json" }
        manifest = JSON.parse(root.content)
        manifest["dependencies"] = { "is-odd" => second_kind == "catalog" ? "catalog:math" : "^2.0.0" }
        root.content = JSON.pretty_generate(manifest) + "\n"
        if second_kind == "catalog"
          files.find { |file| file.name == ".yarnrc.yml" }.content += "  math:\n    is-odd: ^2.0.0\n"
        end
        security_lock = project_dependency_files("yarn_berry/catalog_security").find do |file|
          file.name == "yarn.lock"
        end.content
        lock = files.find { |file| file.name == "yarn.lock" }
        root_dependencies = "  resolution: \"catalog-workspace@workspace:.\"\n  dependencies:\n"
        is_odd_requirement = second_kind == "catalog" ? "catalog:math" : "npm:^2.0.0"
        is_odd_edge = "    is-odd: #{is_odd_requirement.to_json}\n"
        lock.content = lock.content.sub(root_dependencies, root_dependencies + is_odd_edge)
        lock.content += "\n" + security_lock[security_lock.index('"is-number@')..]
      end

      it "composes the changes without losing catalog references or the approved target" do
        updated = updater.updated_dependency_files
        lock = YAML.safe_load(updated.find { |file| file.name == "yarn.lock" }.content)
        expect(lock.fetch("prettier@npm:^2.8.6").fetch("version")).to eq("2.8.6")
        expect(lock.fetch("is-odd@npm:^3.0.1").fetch("version")).to eq("3.0.1")
        expect(lock.fetch("catalog-workspace@workspace:.").dig("dependencies", "prettier")).to eq("catalog:")
        expect(lock.fetch("catalog-child@workspace:packages/child").dig("dependencies", "prettier")).to eq("catalog:")
        expect(updated.find { |file| file.name == ".yarnrc.yml" }.content).to include('"^2.8.6"')
        if second_kind == "catalog"
          expect(updated.map(&:name)).to contain_exactly(".yarnrc.yml", "yarn.lock")
          expect(updated.find { |file| file.name == ".yarnrc.yml" }.content).to include("is-odd: ^3.0.1")
          expect(lock.fetch("catalog-workspace@workspace:.").dig("dependencies", "is-odd")).to eq("catalog:math")
        else
          expect(updated.map(&:name)).to contain_exactly(".yarnrc.yml", "package.json", "yarn.lock")
          root = JSON.parse(files.find { |file| file.name == "package.json" }.content)
          expect(JSON.parse(updated.find { |file| file.name == "package.json" }.content))
            .to eq(root.merge("dependencies" => { "is-odd" => "^3.0.1" }))
          expect(lock.fetch("catalog-workspace@workspace:.").dig("dependencies", "is-odd")).to eq("npm:^3.0.1")
        end
      end
    end
  end
  context "with multiple ordinary resolutions in a mixed group" do
    let(:files) { project_dependency_files("yarn_berry/catalog_mixed_ordinary") }
    let(:parsed) { Dependabot::NpmAndYarn::FileParser.new(dependency_files: files, source: nil).parse }
    let(:updates) do
      %w(is-odd prettier).map do |name|
        original = parsed.find { |dep| dep.name == name }
        version = name == "is-odd" ? "3.0.1" : "2.8.6"
        Dependabot::Dependency.new(
          name: name,
          version: version,
          previous_version: original.version,
          package_manager: "npm_and_yarn",
          requirements: original.requirements.map do |req|
            req.merge(requirement: req.requirement_string == "2.8.6" ? "2.8.6" : "^#{version}")
          end,
          previous_requirements: original.requirements
        )
      end
    end

    it "pins an ordinary direct descriptor even when another consumer already has the approved version" do
      root = files.find { |file| file.name == "package.json" }
      updated = described_class.new(
        dependencies: updates,
        dependency_files: files,
        credentials: []
      ).updated_dependency_files
      lock = YAML.safe_load(updated.find { |file| file.name == "yarn.lock" }.content)
      handler = Dependabot::NpmAndYarn::FileUpdater::BerryLockfileHandler
      expect(handler.descriptor_version(lock, "prettier@npm:^2.8.6")).to eq("2.8.6")
      expect(handler.descriptor_version(lock, "prettier@npm:2.8.6")).to eq("2.8.6")
      expect(handler.descriptor_version(lock, "is-odd@npm:^3.0.1")).to eq("3.0.1")
      expect(updated.map(&:name)).to contain_exactly(".yarnrc.yml", "package.json", "yarn.lock")
      expect(JSON.parse(updated.find { |file| file.name == "package.json" }.content))
        .to eq(JSON.parse(root.content).merge("devDependencies" => { "prettier" => "^2.8.6" }))
      config = files.find { |file| file.name == ".yarnrc.yml" }
      expect(updated.find { |file| file.name == ".yarnrc.yml" }.content)
        .to eq(config.content.sub("is-odd: ^2.0.0", "is-odd: ^3.0.1"))
      expect(lock.fetch("catalog-security@workspace:.").fetch("dependencies"))
        .to eq("is-odd" => "catalog:math", "prettier" => "npm:^2.8.6")
      expect(lock.fetch("catalog-security-child@workspace:packages/child").fetch("dependencies"))
        .to eq("is-odd" => "catalog:math", "prettier" => "npm:2.8.6")
      expect_immutable_install(updated)
    end
  end
end
