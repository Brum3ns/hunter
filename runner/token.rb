# Canonicalizes an env-sourced runner token. The web side (Runner.normalize_token)
# applies the identical rule, so a value quoted in .env digests to the same token
# on both sides regardless of how the container runtime delivered it: trim
# whitespace, then one layer of matching surrounding quotes, then whitespace again.
module RunnerToken
  def self.normalize(raw)
    value = raw.to_s.strip
    if value.length >= 2 &&
       ((value.start_with?('"') && value.end_with?('"')) ||
        (value.start_with?("'") && value.end_with?("'")))
      value = value[1..-2].strip
    end
    value
  end
end
