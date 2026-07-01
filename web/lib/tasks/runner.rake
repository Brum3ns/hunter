# Namespaced `runners:` (not `runner:`) to avoid confusion with the built-in
# `bin/rails runner` command.
namespace :runners do
  desc "Mint a runner identity: NAME=curl-runner KINDS=curl[,nuclei]"
  task create: :environment do
    name = ENV["NAME"].to_s.strip
    kinds = ENV["KINDS"].to_s.split(",").map(&:strip).reject(&:empty?)
    abort "NAME is required" if name.empty?
    abort "KINDS is required (comma-separated)" if kinds.empty?

    runner, raw = Runner.generate(name: name, kinds: kinds)
    puts "Created runner ##{runner.id} '#{runner.name}' (kinds: #{runner.kinds.join(', ')})"
    puts "Runner token (shown once, store it now):"
    puts raw
  end

  desc "Fail runner jobs stuck running past the TTL"
  task reap: :environment do
    n = RunnerJob.reap_stale!
    puts "Reaped #{n} stale job(s)."
  end
end
