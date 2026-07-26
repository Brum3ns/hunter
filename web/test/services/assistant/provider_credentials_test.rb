require "test_helper"
require "tmpdir"

class Assistant::ProviderCredentialsTest < ActiveSupport::TestCase
  def test_a_populated_key_file_is_valid
    with_secret("sk-live-value", mode: 0o400) do |dir|
      assert_equal "valid", status(dir).reason
      assert_predicate status(dir), :available
    end
  end

  def test_an_empty_file_is_disabled_without_being_an_error
    with_secret("", mode: 0o400) do |dir|
      assert_equal "empty", status(dir).reason
      refute_predicate status(dir), :available
    end
  end

  def test_a_whitespace_only_file_is_treated_as_empty
    with_secret("   \n", mode: 0o400) do |dir|
      assert_equal "empty", status(dir).reason
    end
  end

  def test_the_checked_in_placeholder_is_rejected
    with_secret("replace_with_openai_api_key", mode: 0o400) do |dir|
      assert_equal "placeholder", status(dir).reason
    end
  end

  def test_a_missing_file_is_absent
    Dir.mktmpdir { |dir| assert_equal "absent", status(dir).reason }
  end

  def test_a_world_readable_file_is_rejected
    with_secret("sk-live-value", mode: 0o644) do |dir|
      assert_equal "bad_mode", status(dir).reason
    end
  end

  def test_a_symlinked_secret_is_rejected
    Dir.mktmpdir do |dir|
      real = Pathname.new(dir).join("real")
      real.write("sk-live-value")
      real.chmod(0o400)
      File.symlink(real.to_s, Pathname.new(dir).join("assistant_openai_api_key").to_s)

      assert_equal "symlink", status(dir).reason
    end
  end

  def test_an_oversize_file_is_rejected
    with_secret("x" * 8_193, mode: 0o400) do |dir|
      assert_equal "oversize", status(dir).reason
    end
  end

  def test_no_reason_code_leaks_the_secret_value
    with_secret("sk-live-canary", mode: 0o400) do |dir|
      refute_includes status(dir).inspect, "sk-live-canary"
    end
  end

  private

  def entry
    Assistant::ProviderCatalog.fetch!("openai_primary")
  end

  def status(dir)
    Assistant::ProviderCredentials.status(entry, directory: dir)
  end

  def with_secret(body, mode:)
    Dir.mktmpdir do |dir|
      path = Pathname.new(dir).join("assistant_openai_api_key")
      path.write(body)
      path.chmod(mode)
      yield dir
    end
  end
end
