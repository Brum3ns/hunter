# web/app/controllers/programs/views_controller.rb
module Programs
  class ViewsController < BaseController
    def create
      rec = Current.user.program_views.find_or_initialize_by(program_sid: params[:sid])
      rec.viewed_at = Time.current
      rec.save
      render json: { tracked: rec.persisted?, viewed_at: rec.viewed_at }
    end
  end
end
