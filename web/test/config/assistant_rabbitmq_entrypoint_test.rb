require "minitest/autorun"
require "open3"
require "pathname"
require "tmpdir"

# The broker entrypoint supervises a backgrounded RabbitMQ server. It must tolerate
# the window between launching the server and the `rabbit` node registering with
# epmd: `rabbitmqctl` exits 69 (EX_UNAVAILABLE) in that window instead of waiting,
# and an unguarded failure there kills a healthy, still-booting broker.
#
# These tests drive the real script against stub `rabbitmqctl`/server binaries.
# Only the absolute helper and scratch paths are rewritten so the script can run
# outside the image; the supervision logic under test is untouched.
class AssistantRabbitmqEntrypointTest < Minitest::Test
  ROOT = Pathname.new(__dir__).join("../../..").expand_path.freeze
  ENTRYPOINT = ROOT.join("ops/assistant/rabbitmq/entrypoint.sh").freeze

  # Seconds the stub server stays unreachable before registering its node.
  NODE_REGISTRATION_DELAY = 3

  def test_entrypoint_waits_out_the_epmd_registration_window
    Dir.mktmpdir("hunter-rabbitmq-entrypoint") do |dir|
      harness = build_harness(dir)

      stdout, stderr, status = run_entrypoint(harness)
      output = "#{stdout}\n#{stderr}"

      assert status.success?,
        "entrypoint exited #{status.exitstatus} while the broker was still booting:\n#{output}"
      assert_path_exists harness[:ready_file],
        "entrypoint never published its readiness marker:\n#{output}"
      refute_path_exists harness[:sigterm_log],
        "entrypoint sent SIGTERM to a healthy booting broker:\n#{output}"
    end
  end

  def test_entrypoint_fails_when_the_server_process_dies_during_startup
    Dir.mktmpdir("hunter-rabbitmq-entrypoint") do |dir|
      harness = build_harness(dir, server_exits_immediately: true)

      _stdout, stderr, status = run_entrypoint(harness)

      refute status.success?, "entrypoint reported success after the broker died"
      refute_path_exists harness[:ready_file],
        "entrypoint published readiness after the broker died"
      assert_match(/exited during startup/i, stderr,
        "entrypoint did not explain that the broker process died")
    end
  end

  private

  def run_entrypoint(harness)
    Open3.capture3(
      { "PATH" => "#{harness[:bin]}:#{ENV['PATH']}",
        "RABBITMQ_PROVISION_PASSWORD_FILE" => harness[:secret].to_s },
      "sh", harness[:script].to_s, "rabbitmq-server"
    )
  end

  # Copies the entrypoint into a sandbox, redirecting only the absolute
  # `/usr/local/bin` helpers and `/tmp` scratch paths at the stubs.
  def build_harness(dir, server_exits_immediately: false)
    base = Pathname.new(dir)
    bin = base.join("bin")
    bin.mkpath

    script = base.join("entrypoint.sh")
    script.write(
      ENTRYPOINT.read
        .gsub("/usr/local/bin/", "#{bin}/")
        .gsub("/tmp/hunter-assistant-", "#{base}/hunter-assistant-")
    )

    # An empty credential keeps the provisioning branch out of this test.
    secret = base.join("provision_password")
    secret.write("")

    node_marker = base.join("node-registered")
    sigterm_log = base.join("server-sigterm")

    write_stub(bin.join("docker-entrypoint.sh"),
      server_exits_immediately ? dead_server_stub : server_stub(node_marker, sigterm_log))
    write_stub(bin.join("rabbitmqctl"), rabbitmqctl_stub(node_marker))
    write_stub(bin.join("hunter-assistant-rabbitmq-hash-password"), "#!/bin/sh\nprintf 'stub-hash'\n")

    { script: script, bin: bin, secret: secret, sigterm_log: sigterm_log,
      ready_file: base.join("hunter-assistant-rabbitmq-ready") }
  end

  def write_stub(path, body)
    path.write(body)
    path.chmod(0o755)
  end

  def server_stub(node_marker, sigterm_log)
    <<~SH
      #!/bin/sh
      trap 'printf "SIGTERM received - shutting down\\n" > "#{sigterm_log}"; exit 143' TERM
      # Mimic prelaunch: the node is not in epmd yet.
      (sleep #{NODE_REGISTRATION_DELAY}; : > "#{node_marker}") &
      i=0
      while [ "$i" -lt 12 ]; do
        sleep 1
        i=$((i + 1))
      done
      exit 0
    SH
  end

  def dead_server_stub
    <<~SH
      #!/bin/sh
      printf 'BOOT FAILED\\n' >&2
      exit 69
    SH
  end

  # Reproduces the CLI contract that breaks the entrypoint: while the node is
  # absent from epmd, every subcommand exits 69 regardless of --timeout.
  def rabbitmqctl_stub(node_marker)
    <<~SH
      #!/bin/sh
      if [ ! -f "#{node_marker}" ]; then
        printf 'Error: unable to perform an operation on node.\\n' >&2
        printf "  * epmd reports: node 'rabbit' not running at all\\n" >&2
        exit 69
      fi
      for arg in "$@"; do
        case "$arg" in
          await_startup) exit 0 ;;
          list_vhosts) printf '[]'; exit 0 ;;
        esac
      done
      exit 0
    SH
  end
end
