module ControlCenter
  module Ansible
    module YamlLimits
      MAX_BYTES = 256.kilobytes
      MAX_DEPTH = 30
      MAX_NODES = 10_000

      RESERVED_CONNECTION_KEYS = %w[
        ansible_password ansible_ssh_pass ansible_become_password ansible_become_pass
        ansible_private_key_file ansible_ssh_private_key_file ansible_user ansible_ssh_user
        ansible_ssh_common_args ansible_ssh_extra_args ansible_ssh_executable
        ansible_paramiko_proxy_command ansible_paramiko_host_key_auto_add
        ansible_paramiko_host_key_checking ansible_host_key_checking
        ansible_ssh_host_key_checking
      ].freeze
      VARIABLE_RESERVED_CONNECTION_KEYS = (RESERVED_CONNECTION_KEYS + %w[ansible_connection]).freeze
    end
  end
end
