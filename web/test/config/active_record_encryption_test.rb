require "test_helper"
require "open3"

class ActiveRecordEncryptionTest < ActiveSupport::TestCase
  test "test has an explicit complete key set" do
    config = ActiveRecord::Encryption.config
    assert config.primary_key.present?
    assert config.deterministic_key.present?
    assert config.key_derivation_salt.present?
  end

  test "unencrypted fallback is disabled" do
    assert_equal false, ActiveRecord::Encryption.config.support_unencrypted_data
  end

  test "all Ansible secret aliases are filtered" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    values = %w[
      private_key ssh_password private_key_passphrase become_password
      serialized_value execution_payload
    ].index_with { "do-not-log" }

    assert values.keys.all? { |key| filter.filter(values).fetch(key) == "[FILTERED]" }
  end

  test "production boot reports every missing encryption environment variable" do
    env = {
      "RAILS_ENV" => "production",
      "SECRET_KEY_BASE" => "0" * 64,
      "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY" => nil,
      "ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY" => nil,
      "ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT" => nil
    }
    _stdout, stderr, status = Open3.capture3(
      env, Rails.root.join("bin/rails").to_s, "runner", "puts :booted", chdir: Rails.root
    )

    refute status.success?
    assert_includes stderr, "Missing Active Record encryption secrets"
    assert_includes stderr, "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY"
    assert_includes stderr, "ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY"
    assert_includes stderr, "ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT"
  end
end
