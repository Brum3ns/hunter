module Cves
  # Maps OSV package ecosystems to programming languages. Pure. Ecosystems with
  # no known language are dropped. Match is case-insensitive on the ecosystem
  # base name (the part before any ":" suffix OSV appends, e.g. "Alpine:v3.16").
  module Languages
    module_function

    MAP = {
      "npm" => "JavaScript", "pypi" => "Python", "maven" => "Java",
      "go" => "Go", "crates.io" => "Rust", "rubygems" => "Ruby",
      "nuget" => "C#", "packagist" => "PHP", "pub" => "Dart",
      "hex" => "Elixir", "hackage" => "Haskell", "pub.dev" => "Dart"
    }.freeze

    def call(ecosystems)
      Array(ecosystems).filter_map do |eco|
        MAP[eco.to_s.split(":").first.to_s.downcase.strip]
      end.uniq
    end
  end
end
