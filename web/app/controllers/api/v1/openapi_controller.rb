module Api
  module V1
    # Serves the machine-readable OpenAPI document, filtered to the caller's
    # token scopes. No api_scope declaration: every authenticated caller may
    # read it (sessions and wildcard tokens get the whole document).
    class OpenapiController < Api::V1::BaseController
      def show
        render json: ApiDocs::Spec.document(scopes: Current.api_token&.scopes)
      end
    end
  end
end
