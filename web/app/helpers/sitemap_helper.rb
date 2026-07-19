module SitemapHelper
  METHOD_CLASSES = {
    "POST"   => "bg-amber-100 text-amber-800 dark:bg-amber-900/40 dark:text-amber-300",
    "PUT"    => "bg-sky-100 text-sky-800 dark:bg-sky-900/40 dark:text-sky-300",
    "PATCH"  => "bg-sky-100 text-sky-800 dark:bg-sky-900/40 dark:text-sky-300",
    "DELETE" => "bg-red-100 text-red-800 dark:bg-red-900/40 dark:text-red-300"
  }.freeze

  def sitemap_method_class(method)
    METHOD_CLASSES[method.to_s.upcase] || "bg-zinc-200 text-zinc-700 dark:bg-zinc-700 dark:text-zinc-300"
  end
end
