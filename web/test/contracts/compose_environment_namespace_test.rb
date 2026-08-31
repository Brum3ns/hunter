require "minitest/autorun"
require "pathname"
require "yaml"

class ComposeEnvironmentNamespaceTest < Minitest::Test
  ROOT = Pathname.new(__dir__).join("../../..").expand_path.freeze
  COMPOSE_FILES = %w[docker-compose.yaml docker-compose.prod.yaml].freeze
  ENV_FILES = %w[.env .env.example].freeze
  SOURCE_NAME = /\$\{([A-Za-z_][A-Za-z0-9_]*)/

  def test_project_env_files_only_declare_namespaced_source_variables
    ENV_FILES.each do |filename|
      variable_names(filename).each do |name|
        assert name.start_with?("HUNTER_"),
          "#{filename}: #{name} can collide with an exported host variable"
        refute name.start_with?("HUNTER_HUNTER_"),
          "#{filename}: #{name} has the project namespace twice"
      end
    end
  end

  def test_compose_only_interpolates_namespaced_source_variables
    COMPOSE_FILES.each do |filename|
      compose_strings(filename).flat_map { |value| value.scan(SOURCE_NAME).flatten }.each do |name|
        assert name.start_with?("HUNTER_"),
          "#{filename}: ${#{name}} can be overridden by an unrelated host variable"
        refute name.start_with?("HUNTER_HUNTER_"),
          "#{filename}: ${#{name}} has the project namespace twice"
      end
    end
  end

  def test_namespaced_sources_map_to_the_runtime_names_expected_by_services
    COMPOSE_FILES.each do |filename|
      services = YAML.safe_load_file(ROOT.join(filename), aliases: true).fetch("services")
      web_environment = services.fetch("web").fetch("environment")

      assert_match(/\A\$\{HUNTER_RABBITMQ_HOST(?::-|\})/, web_environment.fetch("RABBITMQ_HOST"))
      assert_match(/\A\$\{HUNTER_DB_USERNAME(?::-|\})/, web_environment.fetch("DB_USERNAME"))
      assert_match(/\A\$\{HUNTER_ASSISTANT_MCP_HUNTER_TOKEN(?::-|\})/,
        web_environment.fetch("ASSISTANT_MCP_HUNTER_TOKEN"))
      assert_equal(
        "${HUNTER_ASSISTANT_MCP_BIND_IP:-127.0.0.1}:${HUNTER_ASSISTANT_MCP_PORT:-8080}:8080",
        services.fetch("hunter-mcp").fetch("ports").sole
      )
    end
  end

  private

  def variable_names(filename)
    ROOT.join(filename).each_line.filter_map do |line|
      line[/\A([A-Za-z_][A-Za-z0-9_]*)=/, 1]
    end
  end

  def compose_strings(filename)
    strings_in(YAML.safe_load_file(ROOT.join(filename), aliases: true))
  end

  def strings_in(value)
    case value
    when Hash
      value.flat_map { |key, child| [ key.to_s, *strings_in(child) ] }
    when Array
      value.flat_map { |child| strings_in(child) }
    when String
      [ value ]
    else
      []
    end
  end
end
