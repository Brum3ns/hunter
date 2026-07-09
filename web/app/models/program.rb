class Program
  attr_reader :data

  def initialize(data)
    @data = data
  end

  def sid               = data["_sid"]
  def platform          = data["platform"]
  def slug              = data["slug"]
  def name              = data["name"].presence || slug.to_s.split("-").map(&:capitalize).join(" ")
  def date              = data["date"]
  def url               = data["url"].presence
  def logo              = data["logo"].presence
  def banner            = data["banner"].presence
  def url?              = url.present?
  def logo?             = logo.present?
  def banner?           = banner.present?
  def status            = data["status"].to_s
  def public?           = data["public"]
  def vdp?              = !!data["vdp"]
  def scope_count       = data["scope_count"].to_i
  def bounty?           = data["bounty"]
  def bounty_min        = data["bounty_min"].to_f
  def bounty_max        = data["bounty_max"].to_f
  def currency          = data["currency"].to_s
  def reward_avg        = data["reward_avg"].to_f
  def reward_max        = data["reward_max"].to_f
  def report_count      = data["report_count"].to_i
  def reports_24h       = data["Total_reports_last24_hours"].to_i
  def reports_7d        = data["Total_reports_last7_days"].to_i
  def reports_month     = data["Total_reports_current_month"].to_i
  def avg_response_hrs  = data["Average_first_time_response"].to_i
  def collaboration?    = data["collaboration"]
  def hall_of_fame?     = !!data["hall_of_fame"]
  def hacktivity?       = !!data["hacktivity"]
  def tags              = Array(data["tags"])
  def languages         = Array(data["languages"])
  def description       = data["description"].to_s
  def scope             = Array(data["scope"])
  def out_of_scope      = Array(data["outofscope"])

  def organization      = data["organization"].is_a?(Hash) ? data["organization"] : nil
  def organization?     = organization.present?

  def reward_grid       = data["reward_grid"].is_a?(Hash) ? data["reward_grid"] : nil
  def reward_grid?      = reward_grid.present? && reward_grid.values.any? { |v| v.to_f > 0 }

  def policy            = data["policy"].is_a?(Hash) ? data["policy"] : nil
  def policy?           = policy.present?
  def rules_html        = policy&.dig("rules_html").to_s
  def rules_html?       = rules_html.present?
  def qualifying_vulns       = Array(policy&.dig("qualifying_vulnerabilities"))
  def non_qualifying_vulns   = Array(policy&.dig("non_qualifying_vulnerabilities"))
  def account_access_html    = policy&.dig("account_access_html").to_s
  def account_access_html?   = account_access_html.present?
  def required_user_agent    = policy&.dig("user_agent").to_s
  def required_user_agent?   = required_user_agent.present?
  def restricted_ips         = Array(policy&.dig("restricted_ips"))
  def vpn_active?            = !!policy&.dig("vpn_active")
  def vpn_ips                = Array(policy&.dig("vpn_ips"))

  # Render the bounty band shown on cards / the modal hero. Handles three
  # "no real range" cases that show up across platforms: VDP programs (no
  # bounty at all), bounty-eligible programs where neither bound is published
  # (e.g. Hackerone v1, which exposes the flag but not the numbers), and
  # programs that only publish a maximum.
  def bounty_range
    return "No bounty" unless bounty?
    sym = currency_symbol
    return "Bounty paid" if bounty_min <= 0 && bounty_max <= 0
    return "Up to #{sym}#{format_money(bounty_max)}" if bounty_min <= 0
    return "#{sym}#{format_money(bounty_min)}+" if bounty_max <= 0
    return "#{sym}#{format_money(bounty_max)}" if bounty_min == bounty_max
    "#{sym}#{format_money(bounty_min)} – #{sym}#{format_money(bounty_max)}"
  end

  def currency_symbol
    case currency.upcase
    when "EUR" then "€"
    when "GBP" then "£"
    when "JPY" then "¥"
    when ""    then "$"
    else "$"
    end
  end

  def to_param = sid

  private

  def format_money(amount)
    amount.to_i.to_s.reverse.scan(/\d{1,3}/).join(",").reverse
  end
end
