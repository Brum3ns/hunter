# web/app/controllers/programs/trashes_controller.rb
module Programs
  class TrashesController < BaseController
    def create
      rec = Current.user.trashes.find_or_create_by(program_sid: params[:sid])
      render json: { trashed: rec.persisted? }
    end

    def destroy
      Current.user.trashes.where(program_sid: params[:sid]).delete_all
      render json: { trashed: false }
    end
  end
end
