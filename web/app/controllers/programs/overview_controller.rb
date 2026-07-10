module Programs
  # The Programs catalog page: faceted/dork search over the Mongo `programs`
  # collection with card + table views, plus the standalone program-detail
  # modal fragment. Ported from Scope's flat ProgramsController, namespaced to
  # fit Hunter's department pattern.
  class OverviewController < BaseController
    def index
      fp = filter_params
      @favorited_sids = Current.user&.favorite_sids || Set.new
      @trashed_sids   = Current.user&.trash_sids   || Set.new
      @recent_views   = Current.user&.recent_views(limit: 12) || []
      @focused_program = fp[:focus].present? ? Programs::Source.find(fp[:focus]) : nil

      parsed = Programs::SearchParser.call(fp[:q])
      qp = fp.to_h.with_indifferent_access
      qp[:q] = parsed.free_text
      qp[:dork_expression] = parsed.expression
      qp[:_favorited_sids] = @favorited_sids
      qp[:_trashed_sids]   = @trashed_sids

      result = Programs::Query.call(qp)
      @programs       = result.programs
      @total          = result.total
      @platforms      = result.platforms
      @scope_types    = result.scope_types
      @bounty_ceiling = result.bounty_ceiling
      @filter_params  = fp
      @sort_key = Programs::Sort::OPTIONS.key?(fp[:sort]) ? fp[:sort] : Programs::Sort::DEFAULT_KEY
      @sort_dir = Programs::Sort.resolve_dir(@sort_key, fp[:dir])
      @page     = result.page
      @has_next = result.has_next

      render partial: "programs/cards", locals: cards_locals, layout: false if partial_request?
    end

    # GET /programs/:sid/modal — the program detail modal as a bare fragment.
    # 404s when the program is gone from Mongo (the caller shows nothing).
    def modal
      program = Programs::Source.find(params[:sid])
      return head :not_found unless program
      render partial: "programs/modal", locals: { program: program }, layout: false
    end

    private

    def partial_request?
      request.xhr? || request.headers["X-Requested-With"] == "XMLHttpRequest"
    end

    def filter_params
      params.permit(
        :q, :status, :bounty, :collaboration, :favorites_only, :trash_only,
        :scope_count_gte, :scope_count_lte, :response_lte,
        :bounty_min_gte, :bounty_max_gte,
        :reports_gte, :reports_24h_gte, :reports_7d_gte, :reports_month_gte,
        :sort, :dir, :page, :per_page, :focus,
        platforms: [], scope_types: []
      )
    end

    def cards_locals
      { programs: @programs, page: @page, has_next: @has_next,
        filter_params: @filter_params, favorited_sids: @favorited_sids,
        trashed_sids: @trashed_sids }
    end
    helper_method :cards_locals
  end
end
