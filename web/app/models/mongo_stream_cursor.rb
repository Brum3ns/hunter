# Persists the latest MongoDB change-stream resume token per collection so the
# Sitemap stream worker resumes exactly where it left off after a restart.
class MongoStreamCursor < ApplicationRecord
  def self.token_for(collection)
    rec = find_by(collection: collection.to_s)
    rec&.resume_token.presence
  end

  def self.save_token(collection, token)
    rec = find_or_initialize_by(collection: collection.to_s)
    rec.resume_token = token
    rec.save!
  end
end
