module Assistant
  class ExportsController < ApplicationController
    def show
      artifact = ::Assistant::ExportArtifact.find_signed(
        params[:token], purpose: :assistant_export
      )
      return head :not_found unless artifact && artifact.user_id == Current.user.id && artifact.expires_at.future?

      artifact.update_column(:downloaded_at, Time.current)
      send_data artifact.payload, filename: artifact.filename,
        type: artifact.content_type, disposition: "attachment"
    rescue ActiveSupport::MessageVerifier::InvalidSignature
      head :not_found
    end
  end
end
