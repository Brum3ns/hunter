module TargetsHelper
  # Single source of truth for the table's columns: order, label, default pixel
  # width, and whether it shows by default. The client column controller reads
  # these from the rendered header; adding a column is one entry here plus a
  # branch in target_cell_value.
  COLUMNS = [
    { key: "host",           label: "Host",         width: 240, default: true },
    { key: "port",           label: "Port",         width: 90,  default: true },
    { key: "ip",             label: "IP",           width: 150, default: true },
    { key: "technologies",   label: "Technologies", width: 170, default: true },
    { key: "status",         label: "Status",       width: 90,  default: true },
    { key: "title",          label: "Title",        width: 240, default: true },
    { key: "url",            label: "URL",          width: 260, default: false },
    { key: "scheme",         label: "Scheme",       width: 90,  default: false },
    { key: "path",           label: "Path",         width: 160, default: false },
    { key: "method",         label: "Method",       width: 90,  default: false },
    { key: "webserver",      label: "Web Server",   width: 150, default: false },
    { key: "content_type",   label: "Content-Type", width: 170, default: false },
    { key: "content_length", label: "Length",       width: 110, default: false },
    { key: "words",          label: "Words",        width: 90,  default: false },
    { key: "lines",          label: "Lines",        width: 90,  default: false },
    { key: "response_time",  label: "Resp. Time",   width: 120, default: false },
    { key: "program",        label: "Program",      width: 160, default: false },
    { key: "page_type",      label: "Page Type",    width: 140, default: false }
  ].freeze

  # Non-special columns render their plain value through this map.
  def target_cell_value(target, key)
    case key
    when "host"           then target.host
    when "port"           then target.port
    when "ip"             then target.ip
    when "status"         then target.status_code
    when "title"          then target.title
    when "url"            then target.url
    when "scheme"         then target.scheme
    when "path"           then target.path
    when "method"         then target.verb
    when "webserver"      then target.webserver
    when "content_type"   then target.content_type
    when "content_length" then target.content_length
    when "words"          then target.words
    when "lines"          then target.lines
    when "response_time"  then target.response_time
    when "program"        then target.program
    when "page_type"      then target.page_type
    end
  end

  # One technology → inline brand-colored SVG, or a neutral monogram chip when
  # Simple Icons has no match. `dim` is the Tailwind sizing class (responsive by
  # default so icons grow on larger screens where there's room for more data).
  def tech_icon_tag(name, dim: "h-4 w-4 lg:h-5 lg:w-5")
    icon = SimpleIcons.lookup(name)

    if icon
      svg = content_tag(:svg, tag.path(d: icon[:path]),
        xmlns: "http://www.w3.org/2000/svg", viewBox: "0 0 24 24",
        fill: "##{icon[:hex]}", "aria-hidden": "true", class: dim)
      content_tag(:span, svg,
        class: "inline-flex items-center justify-center rounded bg-white/5 p-1",
        title: icon[:title])
    else
      content_tag(:span, tech_monogram_text(name),
        class: "inline-flex #{dim} items-center justify-center rounded bg-white/10 " \
               "p-1 text-[9px] font-semibold uppercase leading-none text-zinc-300",
        title: name.to_s)
    end
  end

  private

  def tech_monogram_text(name)
    name.to_s.gsub(/[^A-Za-z0-9]/, "").first(2).upcase
  end
end
