require "base64"
require "digest"
require "net/ssh"

module ControlCenter
  module Ansible
    module CredentialFingerprint
      Result = Data.define(:fingerprint, :error)
      module_function

      def call(private_key:, passphrase: nil)
        key = Net::SSH::KeyFactory.load_data_private_key(
          private_key.to_s, passphrase.presence, false, "Hunter Ansible credential"
        )
        digest = Base64.strict_encode64(Digest::SHA256.digest(key.to_blob)).delete_suffix("=")
        Result.new(fingerprint: "SHA256:#{digest}", error: nil)
      rescue Net::SSH::Exception, OpenSSL::PKey::PKeyError, ArgumentError
        Result.new(fingerprint: nil, error: "is invalid or its passphrase is incorrect")
      end
    end
  end
end
