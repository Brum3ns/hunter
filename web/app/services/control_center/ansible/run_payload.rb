module ControlCenter
  module Ansible
    module RunPayload
      SCHEMA_VERSION = 1
      module_function

      def call(playbook:, inventory:, credential:, resolution:, host_limit:, check_mode:, timeout_seconds:)
        {
          "schema_version" => SCHEMA_VERSION,
          "playbook_yaml" => playbook.yaml_content,
          "inventory_yaml" => inventory.yaml_content,
          "known_hosts" => inventory.known_hosts,
          "targets" => ExecutorTaskBuilder.targets_for(inventory),
          "variables" => resolution.values,
          "secrets" => {
            "username" => credential.username,
            "private_key" => credential.private_key,
            "ssh_password" => credential.ssh_password,
            "private_key_passphrase" => credential.private_key_passphrase,
            "become_password" => credential.become_password
          },
          "options" => {
            "host_limit" => host_limit,
            "check_mode" => check_mode,
            "timeout_seconds" => timeout_seconds
          }
        }
      end
    end
  end
end
