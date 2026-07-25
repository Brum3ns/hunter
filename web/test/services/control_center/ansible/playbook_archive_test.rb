require "test_helper"
require "zip"

class ControlCenter::Ansible::PlaybookArchiveTest < ActiveSupport::TestCase
  Playbook = Data.define(:name, :yaml_content)
  Subject = ControlCenter::Ansible::PlaybookArchive

  test "writes exact YAML with sanitized deterministic collision suffixes" do
    playbooks = [
      Playbook.new(name: "Baseline", yaml_content: "---\n- hosts: one\n"),
      Playbook.new(name: "../Baseline.yml", yaml_content: "---\n- hosts: two\n"),
      Playbook.new(name: "///", yaml_content: "---\n- hosts: three\n")
    ]

    travel_to Time.utc(2026, 7, 23, 12, 0, 0) do
      archive = Subject.call(playbooks)
      begin
        assert_equal "hunter-ansible-playbooks-20260723T120000Z.zip", archive.filename
        Zip::File.open(archive.path) do |zip|
          assert_equal [ "Baseline.yml", "Baseline-2.yml", "playbook.yml" ], zip.map(&:name)
          assert_equal "---\n- hosts: one\n", zip.read("Baseline.yml")
          assert_equal "---\n- hosts: two\n", zip.read("Baseline-2.yml")
          assert_equal "---\n- hosts: three\n", zip.read("playbook.yml")
          refute zip.map(&:name).any? { |name| name.include?("/") }
        end
      ensure
        path = archive.path
        archive.close!
        refute File.exist?(path)
      end
    end
  end

  test "rejects empty, oversized-count, and oversized-byte selections" do
    assert_raises(Subject::Error) { Subject.call([]) }

    too_many = Array.new(Subject::MAX_PLAYBOOKS + 1) { Playbook.new(name: "one", yaml_content: "x") }
    count_error = assert_raises(Subject::Error) { Subject.call(too_many) }
    assert_equal "select at most 100 playbooks", count_error.message

    huge = Playbook.new(name: "huge", yaml_content: "x" * (Subject::MAX_UNCOMPRESSED_BYTES + 1))
    byte_error = assert_raises(Subject::Error) { Subject.call([ huge ]) }
    assert_equal "selected YAML exceeds 10485760 bytes", byte_error.message
  end

  test "archive contains no adjacent resource or server-path data" do
    yaml = "---\n- hosts: workers\n  tasks: []\n"
    archive = Subject.call([ Playbook.new(name: "/srv/hunter secret", yaml_content: yaml) ])
    begin
      bytes = File.binread(archive.path)
      assert_includes bytes, "srv-hunter-secret.yml"
      refute_includes bytes, "/srv/hunter"
      refute_includes bytes, "credential"
      refute_includes bytes, "variable_set"
      refute_includes bytes, "run_group"
    ensure
      archive.close!
    end
  end

  test "collision suffixes cannot collide with a literal suffixed name" do
    archive = Subject.call([
      Playbook.new(name: "Baseline", yaml_content: "one"),
      Playbook.new(name: "Baseline", yaml_content: "two"),
      Playbook.new(name: "Baseline-2", yaml_content: "three")
    ])
    begin
      Zip::File.open(archive.path) do |zip|
        assert_equal [ "Baseline.yml", "Baseline-2.yml", "Baseline-2-2.yml" ], zip.map(&:name)
        assert_equal 3, zip.map(&:name).uniq.length
      end
    ensure
      archive.close!
    end
  end
end
