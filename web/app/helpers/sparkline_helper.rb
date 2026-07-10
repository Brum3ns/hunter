module SparklineHelper
  # Renders a compact inline-SVG sparkline for a numeric series, or nil when the
  # series is empty (the caller then omits the sparkline entirely — real finding
  # data often has no dates, so there is nothing to chart). Monochrome:
  # inherits currentColor so it adapts to light/dark like the rest of the UI.
  def sparkline(series, width: 96, height: 24)
    values = Array(series).map(&:to_f)
    return if values.empty?

    max = values.max
    min = values.min
    span = (max - min).nonzero? || 1.0
    step = values.length > 1 ? width.to_f / (values.length - 1) : 0.0

    points = values.each_with_index.map do |value, i|
      x = (i * step).round(2)
      y = (height - ((value - min) / span * height)).round(2)
      "#{x},#{y}"
    end.join(" ")

    content_tag(:svg, class: "text-zinc-900 dark:text-zinc-100",
                width: width, height: height, viewBox: "0 0 #{width} #{height}",
                fill: "none", "aria-hidden": "true") do
      tag.polyline(points: points, stroke: "currentColor", "stroke-width": "1.5",
                   "stroke-linecap": "round", "stroke-linejoin": "round")
    end
  end
end
