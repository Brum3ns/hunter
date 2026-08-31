module Assistant
  module AdminPolicy
    module_function

    def allowed?(user)
      expected = configured_username
      expected.present? && user.present? && normalize(user.username) == expected
    end

    def configured_username
      normalize(ENV.fetch("ADMIN_USERNAME", "admin"))
    end

    def configured_user
      username = configured_username
      User.find_by(username: username) if username.present?
    end

    def normalize(username)
      username.to_s.strip.downcase
    end
    private_class_method :normalize
  end
end
