ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require_relative "test_helpers/session_test_helper"

# Minitest 6 dropped the bundled Mock/stub support, so provide a minimal
# singleton-method swapper for stubbing service objects in tests.
module StubHelper
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
end

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    include StubHelper
  end
end
