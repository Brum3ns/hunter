# Geometry for the inline-SVG charts on the Statistics tab. Kept separate from
# the vulnerability vocab/colors (VulnerabilitiesHelper) so the math is generic
# and reusable by any future module's charts. Pure functions — no data access.
module ChartsHelper
  # Turns [{ label:, count:, color: }] into donut arc segments. Uses the
  # r=15.915 trick (circumference == 100) so a segment's stroke-dasharray is
  # simply its percentage; segments abut clockwise from 12 o'clock. Zero-count
  # entries are dropped. Returns [] when the total is zero, so the caller can
  # render an empty state instead of an invisible ring.
  def donut_segments(data)
    segments = Array(data).select { |d| d[:count].to_i.positive? }
    total = segments.sum { |d| d[:count] }
    return [] if total.zero?

    start = 0.0
    segments.map do |segment|
      percent = segment[:count].to_f / total * 100
      arc = {
        label: segment[:label],
        count: segment[:count],
        color: segment[:color],
        percent: percent,
        dasharray: "#{round3(percent)} #{round3(100 - percent)}",
        # 25 puts the seam at 12 o'clock; subtracting the running total makes
        # each following segment start where the previous one ended.
        dashoffset: round3((125 - start) % 100)
      }
      start += percent
      arc
    end
  end

  private

  def round3(number) = number.round(3)
end
