module Api
  # Base controller for the JSON API. Inherits from ActionController::Base (not
  # ::API) so we keep the full forgery-protection stack and the Authentication
  # concern's cookie handling. Two consumers: the in-browser web UI (signed
  # session cookie + CSRF) and external clients (Authorization: Bearer token).
  class BaseController < ActionController::Base
    include Authentication

    # The concern installs a redirect-on-failure before_action; the API wants a
    # 401 instead, driven by our own bearer-or-cookie check.
    skip_before_action :require_authentication

    # Flat top-level JSON bodies — no wrapping under a resource key.
    wrap_parameters false

    protect_from_forgery with: :exception

    before_action :force_json
    before_action :authenticate_api!
    before_action :authorize_scope!

    rescue_from ActionController::InvalidAuthenticityToken, with: :render_csrf_failure
    rescue_from ActionController::ParameterMissing,         with: :render_bad_request
    rescue_from ActionController::UnpermittedParameters,    with: :render_bad_request
    rescue_from Mongo::Error,                               with: :render_upstream_unavailable

    # Declares the module scope a bearer token must carry to use this controller.
    def self.api_scope(slug)
      @api_scope = slug.to_s
    end

    def self.required_api_scope
      @api_scope
    end

    private

    def force_json
      request.format = :json
    end

    def authenticate_api!
      authenticate_bearer || resume_session || request_authentication
    end

    # Bearer tokens carry no cookie, so there is no forgery risk — treat them as
    # verified and let CSRF apply only to cookie-authenticated requests.
    def verified_request?
      bearer_token.present? || super
    end

    def authenticate_bearer
      token = bearer_token
      return false if token.blank?
      api_token = ApiToken.authenticate(token)
      return false unless api_token
      Current.api_token = api_token
      Current.api_user = api_token.user
      true
    end

    # Scopes constrain bearer tokens only. Cookie/session requests (no
    # Current.api_token) and controllers with no declared scope pass through.
    def authorize_scope!
      return if Current.api_token.nil?
      slug = self.class.required_api_scope
      return if slug.nil?
      return if Current.api_token.allows_scope?(slug)
      render json: { error: "insufficient_scope" }, status: :forbidden
    end

    def bearer_token
      header = request.authorization.to_s
      header.start_with?("Bearer ") ? header.delete_prefix("Bearer ").strip.presence : nil
    end

    # Override the concern's redirect with a JSON 401.
    def request_authentication
      render json: { error: "unauthorized" }, status: :unauthorized
    end

    def render_csrf_failure
      render json: { error: "invalid_csrf_token" }, status: :forbidden
    end

    def render_bad_request(exception)
      render json: { error: "bad_request", detail: exception.message }, status: :bad_request
    end

    def render_upstream_unavailable
      render json: { error: "upstream_unavailable" }, status: :bad_gateway
    end
  end
end
