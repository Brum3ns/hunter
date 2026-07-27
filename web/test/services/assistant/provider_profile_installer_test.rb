require "minitest/autorun"
require_relative "../../../config/environment"

# Standalone: no reachable Postgres here, so `test_helper` (fixtures :all) is
# unusable. The installer's decision logic never has to touch a real database if
# both ActiveRecord entry points it calls -- ProviderProfile.exists? and
# ProviderProfile.create! -- are stubbed away.
class Assistant::ProviderProfileInstallerTest < Minitest::Test
  ANTHROPIC = "ASSISTANT_ANTHROPIC_API_KEY".freeze
  OPENAI = "ASSISTANT_OPENAI_API_KEY".freeze

  def stub_methods(target, mapping)
    originals = mapping.keys.index_with { |name| target.method(name) }
    mapping.each do |name, impl|
      target.define_singleton_method(name) do |*args, **kwargs, &blk|
        impl.respond_to?(:call) ? impl.call(*args, **kwargs, &blk) : impl
      end
    end
    yield
  ensure
    originals.each { |name, method| target.define_singleton_method(name, method) }
  end

  def with_env(values)
    originals = values.keys.to_h { |key| [ key, ENV[key] ] }
    values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    originals.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  # existing: catalog slugs that already have a profile row.
  def install(existing: [], created: [])
    stub_methods(
      Assistant::ProviderProfile,
      exists?: ->(catalog_slug:) { existing.include?(catalog_slug) },
      create!: ->(attrs) { created << attrs; FakeProfile.new(1) }
    ) do
      Assistant::ProviderProfileInstaller.call(created_by: FakeUser.new, now: Time.utc(2026, 7, 27))
    end
  end

  FakeUser = Struct.new(:id)
  FakeProfile = Struct.new(:id)

  def test_a_profile_is_installed_for_each_resolvable_credential
    created = []
    with_env(ANTHROPIC => "sk-ant-real", OPENAI => "sk-openai-real") do
      result = install(created: created)
      assert_equal %w[anthropic_primary openai_primary], result.installed.sort
      assert_empty result.skipped
    end
    assert_equal 2, created.length
  end

  # Configure no key for a provider and no profile may appear for it: supplying the
  # key is what stands in for the operator approving that provider.
  def test_no_profile_is_created_for_a_provider_without_a_usable_credential
    created = []
    with_env(ANTHROPIC => "sk-ant-real", OPENAI => nil) do
      result = install(created: created)
      assert_equal [ "anthropic_primary" ], result.installed
      assert_equal [ "openai_primary" ], result.skipped
    end
    assert_equal 1, created.length
    assert_equal "anthropic_primary", created.first[:catalog_slug]
  end

  def test_a_placeholder_credential_installs_nothing
    created = []
    with_env(ANTHROPIC => "replace_with_your_key", OPENAI => "   ") do
      result = install(created: created)
      assert_empty result.installed
      assert_equal %w[anthropic_primary openai_primary], result.skipped.sort
    end
    assert_empty created
  end

  # db:seed runs on every boot, so re-enabling a profile an administrator disabled
  # would silently override that decision. An existing row is never touched.
  def test_an_existing_profile_is_left_completely_untouched
    created = []
    with_env(ANTHROPIC => "sk-ant-real", OPENAI => nil) do
      result = install(existing: [ "anthropic_primary" ], created: created)
      assert_equal [ "anthropic_primary" ], result.untouched
      assert_empty result.installed
    end
    assert_empty created, "an existing profile was rewritten"
  end

  def test_an_installed_profile_is_enabled_reviewed_and_bound_to_the_catalog
    created = []
    with_env(ANTHROPIC => "sk-ant-real", OPENAI => nil) do
      install(created: created)
    end

    attrs = created.fetch(0)
    entry = Assistant::ProviderCatalog.fetch!("anthropic_primary")
    assert_equal "anthropic_primary", attrs[:catalog_slug]
    assert_equal true, attrs[:enabled]
    assert_equal Time.utc(2026, 7, 27), attrs[:reviewed_at]
    assert_includes attrs[:name], entry.model
    # The model, provider, secret_ref and token limits are applied from the
    # approved catalog by the record itself, so the installer must not pass them.
    %i[model provider secret_ref input_limit output_limit].each do |forbidden|
      refute attrs.key?(forbidden), "installer set #{forbidden} instead of deferring to the catalog"
    end
  end

  # enabled without reviewed_at fails the model's own validation, so a profile that
  # skipped the review stamp could never be enabled.
  def test_enabled_and_reviewed_at_are_set_together
    created = []
    with_env(ANTHROPIC => "sk-ant-real", OPENAI => "sk-openai-real") do
      install(created: created)
    end

    created.each do |attrs|
      assert attrs[:enabled], "a profile was installed disabled"
      refute_nil attrs[:reviewed_at], "an enabled profile has no review stamp"
    end
  end

  # Compose runs `db:seed && foreman start`, so a raise here would stop the web
  # server booting at all. An Assistant that cannot be configured must degrade, not
  # take the application down.
  def test_a_failing_profile_is_reported_and_never_aborts_the_seed
    with_env(ANTHROPIC => "sk-ant-real", OPENAI => "sk-openai-real") do
      result = stub_methods(
        Assistant::ProviderProfile,
        exists?: ->(catalog_slug:) { false },
        create!: ->(_attrs) { raise ActiveRecord::RecordNotUnique, "duplicate name" }
      ) do
        Assistant::ProviderProfileInstaller.call(created_by: FakeUser.new)
      end

      assert_empty result.installed
      assert_equal %w[anthropic_primary openai_primary], result.failed.sort
    end
  end

  # One bad profile must not stop the other provider from being installed.
  def test_one_failing_profile_does_not_block_the_other
    calls = 0
    with_env(ANTHROPIC => "sk-ant-real", OPENAI => "sk-openai-real") do
      result = stub_methods(
        Assistant::ProviderProfile,
        exists?: ->(catalog_slug:) { false },
        create!: lambda { |_attrs|
          calls += 1
          # RecordNotUnique rather than RecordInvalid: the latter needs a real
          # record, and instantiating one would load the schema from a database
          # this test deliberately never touches.
          raise ActiveRecord::RecordNotUnique, "duplicate name" if calls == 1

          FakeProfile.new(2)
        }
      ) do
        Assistant::ProviderProfileInstaller.call(created_by: FakeUser.new)
      end

      assert_equal 1, result.failed.length
      assert_equal 1, result.installed.length
    end
  end

end
