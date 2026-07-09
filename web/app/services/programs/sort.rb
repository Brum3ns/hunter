module Programs
  # Programs::Sort orders an in-memory list of Program PORO instances. The
  # available keys are exposed via OPTIONS so the view can render the dropdown
  # from one source of truth — adding a new sort is a single entry here.
  #
  # Direction handling: numeric/time keys sort desc by default (most interesting
  # value first); name sorts asc. The :dir param can flip either way.
  class Sort
    DEFAULT_KEY = "date".freeze
    DEFAULT_DIR = "desc".freeze

    # [param value, label, default direction, sort proc]
    OPTIONS = {
      "name" => {
        label: "Name",
        default_dir: "asc",
        proc: ->(p) { p.name.to_s.downcase }
      },
      "date" => {
        label: "Date updated",
        default_dir: "desc",
        proc: ->(p) {
          raw = p.data["updated_at"] || p.date
          case raw
          when Time, DateTime then raw.to_time
          when String         then (Time.parse(raw) rescue Time.at(0))
          else Time.at(0)
          end
        }
      },
      "bounty_max" => {
        label: "Bounty max",
        default_dir: "desc",
        proc: ->(p) { p.bounty_max }
      },
      "bounty_min" => {
        label: "Bounty min",
        default_dir: "desc",
        proc: ->(p) { p.bounty_min }
      },
      "reward_avg" => {
        label: "Avg reward",
        default_dir: "desc",
        proc: ->(p) { p.reward_avg }
      },
      "reward_max" => {
        label: "Max reward",
        default_dir: "desc",
        proc: ->(p) { p.reward_max }
      },
      "reports" => {
        label: "Reports total",
        default_dir: "desc",
        proc: ->(p) { p.report_count }
      },
      "reports_24h" => {
        label: "Reports 24h",
        default_dir: "desc",
        proc: ->(p) { p.reports_24h }
      },
      "reports_7d" => {
        label: "Reports 7d",
        default_dir: "desc",
        proc: ->(p) { p.reports_7d }
      },
      "reports_month" => {
        label: "Reports month",
        default_dir: "desc",
        proc: ->(p) { p.reports_month }
      },
      "response" => {
        label: "Response time",
        default_dir: "asc",
        proc: ->(p) { p.avg_response_hrs.zero? ? Float::INFINITY : p.avg_response_hrs }
      },
      "scope_count" => {
        label: "Scope count",
        default_dir: "desc",
        proc: ->(p) { p.scope_count }
      },
      "bounty" => {
        label: "Bounty programs",
        default_dir: "desc",
        proc: ->(p) { p.bounty? ? 1 : 0 }
      },
      "vdp" => {
        label: "VDP programs",
        default_dir: "desc",
        proc: ->(p) { p.vdp? ? 1 : 0 }
      },
      "favorites" => {
        label: "Favorites",
        default_dir: "desc",
        # Stub; real comparison happens in #call with access to the
        # favorited-sids set so we don't ship per-request state in the
        # frozen OPTIONS registry.
        proc: ->(_p) { 0 }
      }
    }.freeze

    def self.call(programs, key, dir, favorited_sids: nil)
      new(programs, key, dir, favorited_sids: favorited_sids).call
    end

    # Falls back to the option's default direction when no explicit dir given.
    def self.resolve_dir(key, dir)
      return dir if dir == "asc" || dir == "desc"
      OPTIONS.dig(key, :default_dir) || DEFAULT_DIR
    end

    def initialize(programs, key, dir, favorited_sids: nil)
      @programs = programs
      @key = OPTIONS.key?(key) ? key : DEFAULT_KEY
      @dir = self.class.resolve_dir(@key, dir)
      @favorited_sids = favorited_sids || Set.new
    end

    def call
      sorted =
        if @key == "favorites"
          @programs.sort_by { |p| @favorited_sids.include?(p.sid) ? 1 : 0 }
        else
          block = OPTIONS.fetch(@key)[:proc]
          @programs.sort_by { |p| sort_key(block, p) }
        end
      @dir == "asc" ? sorted : sorted.reverse
    end

    private

    # Wrap the value so nil/comparable mismatches don't crash sort_by — nils sort
    # to the bottom in the natural ordering before reversal.
    def sort_key(block, program)
      val = block.call(program)
      [val.nil? ? 1 : 0, val.is_a?(Array) ? val : [val]]
    end
  end
end
