module Vulnerabilities
  # The vulnerabilities dashboard: summary stat cards on top, a dork-searchable /
  # faceted / sorted / paginated findings list below. Renders HTML by calling the
  # module's services directly (the JSON API is a separate, programmatic surface
  # that shares the same service layer).
  class OverviewController < BaseController
    def index
      @filter_params = filter_params
      parsed = Vulnerabilities::SearchParser.call(@filter_params[:q])

      # Keep the raw :q in @filter_params (so the search box shows what the user
      # typed) but hand Query the leftover free text plus the parsed dork AST.
      query_params = @filter_params.merge(q: parsed.free_text, dork_expression: parsed.expression)
      @result   = Vulnerabilities::Query.call(query_params)
      @findings = @result.findings
      @sort_key = @result.sort_key
      @sort_dir = @result.sort_dir
      @stats    = Stats.summary
    end

    private

    # Indifferent-access hash so downstream services can use symbol keys.
    def filter_params
      params.permit(
        :q, :sort, :dir, :page, :date_from, :date_to,
        severity: [], status: [], tool: [], type: [], program: []
      ).to_h.with_indifferent_access
    end
  end
end
