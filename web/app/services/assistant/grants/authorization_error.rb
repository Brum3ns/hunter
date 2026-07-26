module Assistant
  module Grants
    class AuthorizationError < StandardError
      attr_reader :code

      def initialize(code)
        @code = code
        super(code)
      end
    end
  end
end
