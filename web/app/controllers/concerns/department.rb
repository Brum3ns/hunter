# Shared conventions for a Hunter web "department" (one per module). Keeps the
# per-module web wiring in one place so a new module's department stays a thin,
# predictable shell. A department controller declares a `TABS` constant; this
# concern exposes it to views for the module's sub-navigation.
module Department
  extend ActiveSupport::Concern

  included do
    helper_method :department_tabs
  end

  # Tabs for the current department, or [] when none are declared. Each tab is
  # { name:, path: <route-helper symbol> }.
  def department_tabs
    self.class.const_defined?(:TABS) ? self.class::TABS : []
  end
end
