module Assistant
  module Context
    module Resolver
      TYPES = Assistant::Context::Catalog::SERIALIZERS.keys.freeze

      module_function

      def find(type:, id:, user:)
        require_user!(user)
        case type.to_s
        when "program" then Programs::Source.find(id)
        when "target" then wrap(Target, Targets::MongoSource.find(id))
        when "cve" then wrap(Cve, Cves::MongoSource.find(id))
        when "vulnerability" then wrap(Vulnerability, Vulnerabilities::MongoSource.find(id))
        when "whiterabbit_template" then ControlCenter::Template.find_by(id: id)
        when "ansible_playbook" then ControlCenter::Ansible::Playbook.find_by(id: id)
        else raise KeyError, "unsupported context type"
        end
      end

      def options(type:, query:, user:, limit: 20)
        require_user!(user)
        limit = [ [ Integer(limit), 1 ].max, 20 ].min
        records = option_records(type.to_s, query.to_s.first(200), limit)
        records.first(limit).map { |record| option_for(type.to_s, record) }
      end

      def option_records(type, query, limit)
        case type
        when "program"
          Programs::Source.all.select { |record| matches?(record.name, query) }
        when "target"
          Targets::MongoSource.all(search: query.presence, page: 1, limit: limit).map { |doc| Target.new(doc) }
        when "cve"
          Cves::MongoSource.all(search: query.presence, page: 1, limit: limit).map { |doc| Cve.new(doc) }
        when "vulnerability"
          Vulnerabilities::MongoSource.all(search: query.presence, page: 1, limit: limit).map do |doc|
            Vulnerability.new(doc)
          end
        when "whiterabbit_template"
          name_query(ControlCenter::Template, query, limit)
        when "ansible_playbook"
          name_query(ControlCenter::Ansible::Playbook, query, limit)
        else raise KeyError, "unsupported context type"
        end
      end
      private_class_method :option_records

      def option_for(type, record)
        id = type == "program" ? record.sid : record.id
        label = case type
        when "target" then record.host.presence || record.url.presence || id
        when "cve" then [ record.id, record.summary ].compact.join(" — ")
        when "vulnerability" then record.finding["name"].presence || record.id
        else record.name
        end
        { type: type, id: id.to_s, label: label.to_s.first(255) }
      end
      private_class_method :option_for

      def name_query(model, query, limit)
        scope = model.order(:name)
        if query.present?
          escaped = ActiveRecord::Base.sanitize_sql_like(query)
          scope = scope.where("name ILIKE ?", "%#{escaped}%")
        end
        scope.limit(limit).to_a
      end
      private_class_method :name_query

      def matches?(value, query)
        query.blank? || value.to_s.downcase.include?(query.downcase)
      end
      private_class_method :matches?

      def wrap(model, document)
        document && model.new(document)
      end
      private_class_method :wrap

      def require_user!(user)
        raise ArgumentError, "user is required" unless user
      end
      private_class_method :require_user!
    end
  end
end
