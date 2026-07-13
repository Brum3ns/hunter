module Cves
  # Computes a CVSS v3.0/3.1 base score from the vector strings OSV stores in a
  # record's `severity` array, and buckets it into a level. Pure; unknown or
  # unparseable input yields a nil score / "unknown" level.
  module Severity
    module_function

    AV = { "N" => 0.85, "A" => 0.62, "L" => 0.55, "P" => 0.20 }.freeze
    AC = { "L" => 0.77, "H" => 0.44 }.freeze
    UI = { "N" => 0.85, "R" => 0.62 }.freeze
    CIA = { "H" => 0.56, "L" => 0.22, "N" => 0.00 }.freeze
    PR_UNCHANGED = { "N" => 0.85, "L" => 0.62, "H" => 0.27 }.freeze
    PR_CHANGED   = { "N" => 0.85, "L" => 0.68, "H" => 0.50 }.freeze

    def call(entries)
      scores = Array(entries).filter_map { |e| base_score(e.to_h["score"].to_s) }
      return { "severity_score" => nil, "severity_level" => "unknown" } if scores.empty?
      score = scores.max
      { "severity_score" => score, "severity_level" => level(score) }
    end

    def base_score(vector)
      m = parse(vector)
      return nil unless %w[AV AC PR UI S C I A].all? { |k| m.key?(k) }
      changed = m["S"] == "C"
      pr = (changed ? PR_CHANGED : PR_UNCHANGED)[m["PR"]]
      av = AV[m["AV"]]; ac = AC[m["AC"]]; ui = UI[m["UI"]]
      c = CIA[m["C"]]; i = CIA[m["I"]]; a = CIA[m["A"]]
      return nil if [pr, av, ac, ui, c, i, a].any?(&:nil?)

      iss = 1 - ((1 - c) * (1 - i) * (1 - a))
      impact = changed ? (7.52 * (iss - 0.029) - 3.25 * ((iss - 0.02)**15)) : (6.42 * iss)
      return 0.0 if impact <= 0

      exploit = 8.22 * av * ac * pr * ui
      raw = [(changed ? 1.08 : 1.0) * (impact + exploit), 10].min
      roundup(raw)
    end

    def parse(vector)
      vector.to_s.split("/").each_with_object({}) do |part, h|
        k, v = part.split(":", 2)
        h[k] = v if k && v && k != "CVSS"
      end
    end

    # CVSS "roundup": smallest one-decimal value >= input, with float tolerance.
    def roundup(value)
      int = (value * 100_000).round
      return (int / 100_000.0) if (int % 10_000).zero?
      ((int / 10_000).floor + 1) / 10.0
    end

    def level(score)
      case score
      when 9.0..Float::INFINITY then "critical"
      when 7.0...9.0 then "high"
      when 4.0...7.0 then "medium"
      when 0.1...4.0 then "low"
      else "none"
      end
    end
  end
end
