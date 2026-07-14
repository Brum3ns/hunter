# Renders the interactive API documentation (Swagger UI) booted against the
# machine OpenAPI endpoint. Plain web controller behind the standard session
# auth (ApplicationController), so the page uses the operator's cookie for
# try-it-out on GET endpoints.
class DocsController < ApplicationController
  def index
  end
end
