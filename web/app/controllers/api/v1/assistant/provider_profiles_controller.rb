module Api
  module V1
    module Assistant
      class ProviderProfilesController < BaseController
        def index
          profiles = ::Assistant::ProviderProfile.order(:name)
          render json: { provider_profiles: profiles.map { |profile| serialize_provider_profile(profile) } }
        end

        def show
          profile = ::Assistant::ProviderProfile.find_by(id: params[:id])
          return render_not_found unless profile

          render json: serialize_provider_profile(profile)
        end

        def create
          profile = ::Assistant::ProviderProfile.new(profile_params)
          profile.created_by = current_assistant_user
          if profile.save
            render json: serialize_provider_profile(profile), status: :created
          else
            render_validation_errors(profile)
          end
        end

        def update
          profile = ::Assistant::ProviderProfile.find_by(id: params[:id])
          return render_not_found unless profile

          if profile.update(profile_params)
            render json: serialize_provider_profile(profile)
          else
            render_validation_errors(profile)
          end
        end

        def destroy
          profile = ::Assistant::ProviderProfile.find_by(id: params[:id])
          return render_not_found unless profile

          if profile.destroy
            head :no_content
          else
            render_validation_errors(profile)
          end
        end

        private

        def profile_params
          params.require(:provider_profile).permit(
            :name,
            :catalog_slug,
            :enabled,
            :tool_call_limit,
            :retention_posture,
            :reviewed_at
          )
        end
      end
    end
  end
end
