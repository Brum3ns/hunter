module Assistant
  # Installs one provider profile per catalog entry whose credential actually
  # resolves, so that supplying a provider key in the environment is the whole
  # enablement step. Without this, `Activation.state` reports the Assistant active
  # (it derives from credentials alone) while the chat still cannot start a
  # conversation, because `POST /conversations` binds a turn to a profile ROW and a
  # fresh database has none.
  #
  # Supplying the key is treated as the operator's approval of that provider, which
  # is what `reviewed_at` records. A profile is therefore only ever created for a
  # credential classified `valid` — configure no key for a provider and no profile
  # appears for it.
  module ProviderProfileInstaller
    Result = Data.define(:installed, :skipped, :untouched, :failed)

    module_function

    # Idempotent, and deliberately non-destructive: an existing profile is left
    # exactly as it is. `db:seed` runs on every boot, so re-enabling a profile an
    # administrator had disabled would silently override that decision — the one
    # thing a boot-time seed must never do.
    def call(created_by:, now: Time.current)
      installed = []
      skipped = []
      untouched = []
      failed = []

      ProviderCredentials.statuses.each do |status|
        if ProviderProfile.exists?(catalog_slug: status.slug)
          untouched << status.slug
        elsif !status.available
          skipped << status.slug
        else
          begin
            create!(status.slug, created_by: created_by, now: now)
            installed << status.slug
          rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
            # Never abort the seed. Compose runs `db:seed && foreman start`, so a
            # raise here means the web server never starts at all — an unusable
            # Assistant would take the whole application down with it. A name
            # collision with a hand-made profile is enough to trigger this.
            # Matches Config.configuration_reasons: an Assistant that cannot be
            # configured is disabled with a reason, never boot-blocking.
            failed << status.slug
          end
        end
      end

      Result.new(installed: installed, skipped: skipped, untouched: untouched, failed: failed)
    end

    # Only the catalog slug, the name and the review stamp are set here: the model,
    # provider, secret_ref and both token limits are applied from the approved
    # catalog by ProviderProfile#apply_catalog_entry, so a profile can never claim
    # limits the catalog does not grant.
    def create!(slug, created_by:, now:)
      entry = ProviderCatalog.fetch!(slug)
      ProviderProfile.create!(
        name: "#{entry.provider} #{entry.model}",
        catalog_slug: slug,
        created_by: created_by,
        enabled: true,
        reviewed_at: now
      )
    end
    private_class_method :create!
  end
end
