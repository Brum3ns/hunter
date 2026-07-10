module Vulnerabilities
  # Summary counts for the vulnerabilities dashboard cards. Reads never raise to
  # the view — a transient Mongo outage yields zeros, not a crash (mirrors
  # MongoSource's read behavior). Status vocab lives in constants so the mapping
  # from a report's status string to a card is a one-place edit.
  module Stats
    module_function

    REPORTED_STATUSES = %w[reported].freeze
    FALSE_POSITIVE_STATUSES = %w[false_positive fp].freeze

    def summary
      {
        created: count({}),
        reported: count("report.status" => { "$in" => REPORTED_STATUSES }),
        false_positives: count("report.status" => { "$in" => FALSE_POSITIVE_STATUSES })
      }
    rescue Mongo::Error => e
      Rails.logger.warn("Vulnerabilities::Stats#summary failed (#{e.class}: #{e.message})")
      { created: 0, reported: 0, false_positives: 0 }
    end

    def count(filter)
      collection.count_documents(filter)
    end

    def collection
      HunterMongo.collection(MongoSource::COLLECTION)
    end
  end
end
