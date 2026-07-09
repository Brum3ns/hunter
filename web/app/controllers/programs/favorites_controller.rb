# web/app/controllers/programs/favorites_controller.rb
module Programs
  class FavoritesController < BaseController
    def create
      fav = Current.user.favorites.find_or_create_by(program_sid: params[:sid])
      render json: { favorited: fav.persisted? }
    end

    def destroy
      Current.user.favorites.where(program_sid: params[:sid]).delete_all
      render json: { favorited: false }
    end
  end
end
