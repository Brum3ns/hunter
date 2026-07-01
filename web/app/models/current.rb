class Current < ActiveSupport::CurrentAttributes
  attribute :session, :api_user, :runner

  # Cookie auth sets `session`; bearer-token auth sets `api_user` directly.
  def user
    api_user || session&.user
  end
end
