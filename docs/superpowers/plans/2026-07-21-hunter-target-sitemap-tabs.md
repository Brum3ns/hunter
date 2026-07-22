# Hunter Target and Sitemap Tabs Implementation Plan

**Goal:** Move Sitemap into the Target web department as its second tab while
preserving the old entry URL.

**Architecture:** A shared `Targets::BaseController` owns the department tabs.
Target and Sitemap retain their existing controllers and data layers, while
canonical Sitemap web routes move below `/targets/sitemap`.

**Tech stack:** Rails 8, ERB/Tailwind, Turbo, Minitest.

## Constraints

- Preserve unrelated dirty-worktree changes.
- Do not commit unless requested.
- Follow the approved design spec exactly.

### Task 1: Specify navigation and routes with failing tests

**Files:**

- Modify `web/test/integration/targets/index_test.rb`
- Modify `web/test/integration/sitemap/origins_test.rb`
- Modify `web/test/integration/sitemap/tree_test.rb`
- Modify `web/test/integration/sitemap/endpoints_test.rb`

- [ ] Assert both pages render Target/Sitemap tabs with the correct active tab.
- [ ] Assert Sitemap has one active Target sidebar link and no Sitemap sidebar link.
- [ ] Assert canonical Sitemap form, tree, and endpoint URLs.
- [ ] Assert `/sitemap` redirects to `/targets/sitemap` with query parameters.
- [ ] Run focused tests and confirm they fail for the missing behavior.

### Task 2: Add the shared department and canonical routes

**Files:**

- Create `web/app/controllers/targets/base_controller.rb`
- Modify `web/app/controllers/targets_controller.rb`
- Modify `web/app/controllers/sitemap/base_controller.rb`
- Modify `web/config/routes.rb`
- Modify `web/app/helpers/navigation_helper.rb`

- [ ] Declare Target and Sitemap tabs in `Targets::BaseController`.
- [ ] Inherit both web controller branches from the shared base.
- [ ] Add canonical routes before the Target detail route and add the legacy redirect.
- [ ] Collapse the sidebar to one Target entry active for both controller branches.

### Task 3: Render tabs and use canonical URLs

**Files:**

- Modify `web/app/views/targets/index.html.erb`
- Modify `web/app/views/sitemap/origins/index.html.erb`
- Modify `web/app/views/sitemap/origins/_filters.html.erb`
- Modify `web/app/views/sitemap/origins/_origin.html.erb`
- Modify `web/app/views/sitemap/origins/_node.html.erb`

- [ ] Render the shared tab bar on both full pages.
- [ ] Point forms, clear links, lazy trees, and endpoint detail links at canonical helpers.
- [ ] Keep the Sitemap split pane within the available viewport below its new tabs.

### Task 4: Verify

- [ ] Run focused Target and Sitemap integration tests.
- [ ] Run routing/navigation tests and the full Rails suite.
- [ ] Review the final diff for unrelated changes and stale Sitemap route helpers.
