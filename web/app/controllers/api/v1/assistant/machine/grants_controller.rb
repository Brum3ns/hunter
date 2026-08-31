module Api
  module V1
    module Assistant
      module Machine
        class GrantsController < BaseController
          require_turn_grant_authorization!

          def show
            set_grant_budget_headers
            render json: grant_scope_payload
          end
        end
      end
    end
  end
end
