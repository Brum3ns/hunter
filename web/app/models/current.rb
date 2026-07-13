class Current < ActiveSupport::CurrentAttributes
  attribute :session, :api_user, :api_token, :runner

  # Cookie auth sets `session`; bearer-token auth sets `api_user`/`api_token`.
  def user
    api_user || session&.user
  end
end
