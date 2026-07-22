# Target department: a column-configurable table of "alive" assets. Renders HTML
# by calling Targets::MongoSource directly (the JSON API is a separate surface
# sharing the same service layer).
class TargetsController < Targets::BaseController
  DEFAULT_LIMIT = 50

  def index
    parsed   = Targets::SearchParser.call(params[:q])
    @filters = { "program" => params[:program].presence, "status" => params[:status].presence }.compact
    @search  = params[:q].presence                 # raw text, echoed in the search box
    free     = parsed.free_text.presence
    expr     = parsed.expression
    @sort    = params[:sort].presence || Targets::MongoSource::DEFAULT_SORT
    @dir     = params[:dir] == "asc" ? "asc" : "desc"
    @page    = [params[:page].to_i, 1].max

    docs = Targets::MongoSource.all(
      filters: @filters, search: free, expression: expr, sort: @sort, dir: @dir,
      page: @page, limit: DEFAULT_LIMIT
    )
    @targets = docs.map { |doc| Target.new(doc) }
    @total   = Targets::MongoSource.count(filters: @filters, search: free, expression: expr)
    @next_page_url = (@page * DEFAULT_LIMIT < @total) ?
      targets_path(request.query_parameters.merge("page" => @page + 1)) : nil

    # Infinite scroll fetches append just the next page of rows (+ a next-url
    # marker); the full page renders index.html.erb.
    render partial: "targets/rows_page" if request.xhr?
  end

  # Full detail for one asset, rendered into the "target_panel" Turbo Frame the
  # list docks on the right. A direct visit still renders inside the app layout.
  def show
    doc = Targets::MongoSource.find(params[:id])
    return head :not_found unless doc

    @target = Target.new(doc)
  end
end
