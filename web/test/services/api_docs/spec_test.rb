require "test_helper"

class ApiDocs::SpecTest < ActiveSupport::TestCase
  # Hermetic fixture dir: base.yaml + two tiny fragments, so these tests do not
  # depend on the real per-module fragments (which other tasks flesh out).
  def with_fixture_dir
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "base.yaml"), <<~YAML)
        openapi: "3.1.0"
        info: { title: "T", version: "1.0.0" }
        components: { schemas: { Error: { type: object } } }
        paths: {}
      YAML
      File.write(File.join(dir, "cves.yaml"), <<~YAML)
        paths:
          /api/v1/cves: { get: { summary: "list cves", tags: ["CVEs"] } }
        components:
          schemas: { Cve: { type: object } }
      YAML
      File.write(File.join(dir, "programs.yaml"), <<~YAML)
        paths:
          /api/v1/programs/changes: { get: { summary: "changes", tags: ["Programs"] } }
        components:
          schemas: { ProgramChange: { type: object } }
      YAML
      yield dir
    end
  end

  test "nil scopes merges every fragment into base" do
    with_fixture_dir do |dir|
      doc = ApiDocs::Spec.document(scopes: nil, dir: dir)
      assert_equal "3.1.0", doc["openapi"]
      assert doc["paths"].key?("/api/v1/cves")
      assert doc["paths"].key?("/api/v1/programs/changes")
      assert doc["components"]["schemas"].key?("Error")
      assert doc["components"]["schemas"].key?("Cve")
      assert doc["components"]["schemas"].key?("ProgramChange")
    end
  end

  test "wildcard scope merges every fragment" do
    with_fixture_dir do |dir|
      doc = ApiDocs::Spec.document(scopes: ["*"], dir: dir)
      assert doc["paths"].key?("/api/v1/cves")
      assert doc["paths"].key?("/api/v1/programs/changes")
    end
  end

  test "a named scope includes only that fragment plus base" do
    with_fixture_dir do |dir|
      doc = ApiDocs::Spec.document(scopes: ["cves"], dir: dir)
      assert doc["paths"].key?("/api/v1/cves")
      refute doc["paths"].key?("/api/v1/programs/changes")
      assert doc["components"]["schemas"].key?("Cve")
      refute doc["components"]["schemas"].key?("ProgramChange")
      assert doc["components"]["schemas"].key?("Error"), "base schemas always present"
    end
  end

  test "duplicate path keys across fragments raise" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "base.yaml"), "openapi: \"3.1.0\"\npaths: {}\n")
      File.write(File.join(dir, "a.yaml"), "paths:\n  /x: { get: { summary: s } }\n")
      File.write(File.join(dir, "b.yaml"), "paths:\n  /x: { post: { summary: s } }\n")
      assert_raises(ApiDocs::Spec::DuplicateKeyError) do
        ApiDocs::Spec.document(scopes: nil, dir: dir)
      end
    end
  end
end
