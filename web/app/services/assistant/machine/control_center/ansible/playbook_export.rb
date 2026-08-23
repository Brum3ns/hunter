module Assistant
  module Machine
    module ControlCenter
      module Ansible
        module PlaybookExport
          module_function

          def call(user:, playbooks:)
            archive = ::ControlCenter::Ansible::PlaybookArchive.call(playbooks)
            payload = archive.read
            raise ::ControlCenter::Ansible::PlaybookArchive::Error, "archive is too large" if
              payload.bytesize > ::Assistant::ExportArtifact::MAX_BYTES

            ::Assistant::ExportArtifact.create!(
              user: user, kind: "ansible_playbooks", filename: archive.filename,
              content_type: "application/zip", payload: payload,
              byte_count: payload.bytesize, expires_at: ::Assistant::ExportArtifact::TTL.from_now
            )
          ensure
            archive&.close!
          end
        end
      end
    end
  end
end
