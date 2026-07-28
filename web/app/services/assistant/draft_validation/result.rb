module Assistant
  module DraftValidation
    Result = Data.define(:valid, :codes, :messages, :normalized, :validation_version) do
      def valid?
        valid
      end
    end
  end
end
