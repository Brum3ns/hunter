namespace :sitemap do
  desc "Tail MongoDB change streams and apply them to the sitemap projection"
  task stream: :environment do
    sources = {
      Sitemap::MongoSource::ALIVE   => nil,
      Sitemap::MongoSource::KATANA  => "katana",
      Sitemap::MongoSource::WAYBACK => "wayback"
    }
    threads = sources.map do |collection, source|
      Thread.new { Sitemap::StreamWorker.new(collection, source: source).run }
    end
    Rails.logger.info("sitemap:stream watching #{sources.keys.join(', ')}")
    threads.each(&:join)
  end
end
