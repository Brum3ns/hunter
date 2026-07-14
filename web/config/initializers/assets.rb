# Be sure to restart your server when you modify this file.

# Version of your assets, change this if you want to expire all your assets.
Rails.application.config.assets.version = "1.0"

# Add additional assets to the asset load path.
# Rails.application.config.assets.paths << Emoji.images_path

# Serve vendored Swagger UI (dist files, pinned — see vendor/swagger-ui/VERSION)
# through Propshaft. Referenced only by the /docs page.
Rails.application.config.assets.paths << Rails.root.join("vendor", "swagger-ui")
