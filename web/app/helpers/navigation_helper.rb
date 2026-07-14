module NavigationHelper
  def nav_active?(*controller_names)
    names = controller_names.flatten
    return true if names.include?(controller_name)

    # Namespaced departments (e.g. "vulnerabilities/overview") match on their
    # first path segment so every controller in the module lights up its entry.
    names.include?(controller_path.to_s.split("/").first)
  end

  # Primary sidebar navigation, grouped. Each inner array renders as a block
  # separated by a divider. The second group is the Hunter modules — adding a
  # module's "department" to the sidebar is a one-line edit here.
  def primary_nav_groups
    [
      [
        { label: "Dashboard", path: root_path, controllers: %w[dashboard], icon: "home" }
      ],
      [
        { label: "Programs", path: programs_root_path, controllers: %w[programs], icon: "clipboard-document-list" },
        { label: "Vulnerabilities", path: vulnerabilities_root_path, controllers: %w[vulnerabilities], icon: "shield-exclamation" },
        { label: "Control Center", path: control_center_root_path, controllers: %w[control_center], icon: "viewfinder-circle" },
        { label: "CVEs", path: cves_path, controllers: %w[cves], icon: "bug-ant" }
      ]
    ]
  end

  # App-level utilities pinned to the bottom of the sidebar.
  def utility_nav_items
    [
      { label: "API Docs", path: docs_path, controllers: %w[docs], icon: "code-bracket" },
      { label: "Settings", path: settings_path, controllers: %w[settings], icon: "cog" },
      { label: "Help", path: help_path, controllers: %w[help], icon: "question-mark-circle" }
    ]
  end
end
