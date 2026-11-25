# typed: true
# frozen_string_literal: true

require "spec_helper"
require "dependabot/npm_and_yarn/dependency_grapher"
require "dependabot/npm_and_yarn/dependency_grapher/yarn_relationship_resolver"

RSpec.describe Dependabot::NpmAndYarn::DependencyGrapher::YarnRelationshipResolver do
  subject(:relationships) { described_class.new(lockfile).relationships }

  let(:lockfile) { Dependabot::DependencyFile.new(name: "yarn.lock", content: "unused helper input") }
  let(:result) do
    {
      "__metadata" => { "version" => 8 },
      "parent@^1" => {
        "version" => "1.0.0",
        "dependencies" => { "exact" => "^1", "grouped" => "^2", "sole" => "^9", "ambiguous" => "^9" }
      },
      "exact@^1" => { "version" => "1.1.0" },
      "exact@^2" => { "version" => "2.0.0" },
      "grouped@^1, grouped@^2" => { "version" => "2.1.0" },
      "sole@^1" => { "version" => "1.2.0" },
      "ambiguous@^1" => { "version" => "1.0.0" },
      "ambiguous@^2" => { "version" => "2.0.0" }
    }
  end

  before do
    allow(Dependabot::SharedHelpers).to receive(:run_helper_subprocess)
      .with(hash_including(function: "yarn:parseLockfile")).and_return(result)
  end

  it "preserves exact, grouped, and sole-name resolution order" do
    expect(relationships).to eq("parent@1.0.0" => %w(exact@1.1.0 grouped@2.1.0 sole@1.2.0))
  end

  context "with workspace parents" do
    let(:result) do
      super().merge("local@workspace:." => { "version" => "0.0.0-use.local", "dependencies" => { "exact" => "^1" } })
    end

    it "retains workspace relationship data" do
      expect(relationships.fetch("local@0.0.0-use.local")).to eq(["exact@1.1.0"])
    end
  end

  context "with duplicate parents" do
    let(:result) do
      super().merge(
        "parent@~1.0.0" => { "version" => "1.0.0", "dependencies" => { "exact" => "^1", "grouped" => "^1" } }
      )
    end

    it "merges and deduplicates their resolved children" do
      expect(relationships.fetch("parent@1.0.0")).to eq(%w(exact@1.1.0 grouped@2.1.0 sole@1.2.0))
    end
  end

  describe "#independent_of_catalogs?" do
    let(:resolver) { described_class.new(lockfile, catalogs: { "catalog:" => { "a" => "^1" } }) }
    let(:result) do
      {
        "a@npm:1.0.0, a@npm:^1" => {
          "version" => "1.0.0", "resolution" => "a@npm:1.0.0", "dependencies" => { "b" => "npm:^1" }
        },
        "b@npm:^1" => {
          "version" => "1.0.0", "resolution" => "b@npm:1.0.0", "optionalDependencies" => { "a" => "npm:^1" }
        },
        "a@npm:^2" => {
          "version" => "2.0.0", "resolution" => "a@npm:2.0.0", "dependencies" => { "elsewhere" => "npm:^1" }
        }
      }
    end

    it "follows exact grouped descriptors and optional edges through cycles without visiting the other version" do
      expect(resolver.independent_of_catalogs?("elsewhere") { false }).to be(true)
      expect(resolver.independent_of_catalogs?("b") { false }).to be(false)
    end

    it "requires every catalog descendant to have a matching record even if the name has only one candidate" do
      result.fetch("a@npm:1.0.0, a@npm:^1")["dependencies"] = { "b" => "npm:^2" }
      expect(resolver.independent_of_catalogs?("elsewhere") { false }).to be(false)
    end

    it "requires a mapping for installed catalog edges even outside the discovered workspaces" do
      result["nested@workspace:packages/tools/child"] = {
        "version" => "0.0.0-use.local", "dependencies" => { "b" => "catalog:unseen" }
      }
      expect(resolver.independent_of_catalogs?("elsewhere") { false }).to be(false)
    end

    it "keeps a potential resolution override on a catalog descendant out of the ordinary path" do
      expect(resolver.independent_of_catalogs?("elsewhere") { |name| name == "b" }).to be(false)
    end
  end

  context "with null child data" do
    let(:result) { { "parent@^1" => { "version" => "1.0.0", "dependencies" => nil } } }

    it "preserves the empty-child skip" do
      expect(relationships).to be_empty
    end
  end

  context "with catalog edges" do
    let(:result) do
      {
        "workspace@workspace:packages/app" => {
          "version" => "0.0.0-use.local", "dependencies" => { "@scope/pkg" => "catalog:default" }
        },
        "@scope/pkg@npm:^2.0.0, @scope/pkg@npm:~2.1.0" => { "version" => "2.1.0" },
        "@scope/pkg@npm:^1.0.0" => { "version" => "1.9.0" }
      }
    end

    it "resolves the exact effective descriptor instead of another version of the same package" do
      resolver = described_class.new(lockfile, catalogs: { "catalog:default" => { "@scope/pkg" => "^2.0.0" } })
      expect(resolver.relationships).to eq("workspace@0.0.0-use.local" => ["@scope/pkg@2.1.0"])
    end

    it "reports missing catalog mappings instead of silently dropping the edge" do
      expect { relationships }.to raise_error(Dependabot::DependencyFileNotResolvable, /catalog:default/)
    end

    it "includes optional catalog edges in the graph" do
      result["workspace@workspace:packages/app"]["optionalDependencies"] =
        result["workspace@workspace:packages/app"].delete("dependencies")
      resolver = described_class.new(lockfile, catalogs: { "catalog:default" => { "@scope/pkg" => "^2.0.0" } })
      expect(resolver.relationships).to eq("workspace@0.0.0-use.local" => ["@scope/pkg@2.1.0"])
    end
  end
end
