module Assistant
  module Machine
    module ControlCenter
      module Ansible
        module ResourceProjections
          module_function

          def credential(record)
            {
              "id" => record.id, "name" => safe(record.name), "auth_type" => record.auth_type,
              "username" => safe(record.username),
              "public_key_fingerprint" => safe(record.public_key_fingerprint),
              "private_key_configured" => record.private_key_configured?,
              "ssh_password_configured" => record.ssh_password_configured?,
              "private_key_passphrase_configured" => record.private_key_passphrase_configured?,
              "become_password_configured" => record.become_password_configured?,
              "last_used_at" => record.last_used_at, "created_at" => record.created_at,
              "updated_at" => record.updated_at
            }
          end

          def inventory(record, full:)
            body = {
              "id" => record.id, "name" => safe(record.name), "description" => safe(record.description),
              "checksum" => record.checksum, "lock_version" => record.lock_version,
              "default_credential_id" => record.default_credential_id,
              "known_hosts_configured" => record.known_hosts.present?,
              "host_key_fingerprints" => safe_fingerprints(record.host_key_fingerprints),
              "updated_at" => record.updated_at
            }
            body.merge!(
              "yaml_content" => safe(record.yaml_content, max: 256.kilobytes),
              "variable_set_ids" => record.variable_set_ids,
              "created_by" => safe(record.created_by.username), "created_at" => record.created_at
            ) if full
            body
          end

          def variable_set(record, full:)
            body = {
              "id" => record.id, "name" => safe(record.name), "description" => safe(record.description),
              "lock_version" => record.lock_version, "updated_at" => record.updated_at
            }
            body.merge!(
              "created_by" => safe(record.created_by.username), "created_at" => record.created_at,
              "variables" => record.variables.map { |variable| variable(variable) }
            ) if full
            body
          end

          def variable(record)
            {
              "id" => record.id, "name" => safe(record.name), "value_type" => record.value_type,
              "secret" => record.secret?, "configured" => record.serialized_value.present?,
              "value" => record.secret? ? nil : record.typed_value,
              "position" => record.position, "lock_version" => record.lock_version
            }
          end

          def utility_task(record)
            sanitized = ::Assistant::Machine::SensitiveData.payload(record.result)
            {
              "id" => record.id, "inventory_id" => record.inventory_id,
              "playbook_id" => record.playbook_id, "kind" => record.kind, "status" => record.status,
              "result" => sanitized.value || {}, "result_redacted" => sanitized.redacted,
              "error_code" => safe(record.error_code),
              "error_detail" => safe(record.error_detail),
              "started_at" => record.started_at, "completed_at" => record.completed_at,
              "created_at" => record.created_at, "updated_at" => record.updated_at
            }
          end

          def safe_fingerprints(value)
            value.to_h.first(1_000).to_h do |host, fingerprint|
              [ safe(host, max: 512), safe(fingerprint, max: 512) ]
            end
          end
          private_class_method :safe_fingerprints

          def safe(value, max: 16_384)
            return nil if value.nil?

            ::Assistant::Machine::SensitiveData.text(value.to_s, max_bytes: max).value
          end
          private_class_method :safe
        end
      end
    end
  end
end
