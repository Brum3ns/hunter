# Canonical list of bug-bounty platforms the Scope tooling fetches from. One
# source of truth shared by the Programs department, the Monitor/Logs filters,
# and the fetch-schedule / monitor-config settings.
module ScopePlatforms
  ALL = %w[hackerone bugcrowd intigriti yeswehack bugbountych].freeze
end
