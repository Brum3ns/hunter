module NavigationHelper
  def nav_active?(*controller_names)
    controller_names.flatten.include?(controller_name)
  end
end
