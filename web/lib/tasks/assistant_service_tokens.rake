namespace :assistant do
  namespace :service_tokens do
    desc "Mint an assistant service identity: NAME=hunter-mcp ROLE=mcp_reader [ROTATE=true]"
    task create: :environment do
      name = ENV["NAME"].to_s.strip
      role = ENV["ROLE"].to_s.strip
      rotate = ActiveModel::Type::Boolean.new.cast(ENV["ROTATE"])

      abort "NAME is required" if name.empty?
      abort "ROLE must be mcp_reader" unless role == "mcp_reader"

      identity = nil
      raw = nil
      Assistant::ServiceIdentity.transaction do
        existing = Assistant::ServiceIdentity.where(enabled: true)
          .where("lower(name) = ?", name.downcase).first
        abort "An enabled identity with this name exists; set ROTATE=true" if existing && !rotate

        existing&.update!(enabled: false, rotated_at: Time.current)
        identity, raw = Assistant::ServiceIdentity.generate!(name: name, role: role)
      end

      puts "Created assistant service identity ##{identity.id} '#{identity.name}' (role: #{identity.role})"
      puts "Service token (shown once, store it now):"
      puts raw
    end
  end
end
