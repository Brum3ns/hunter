# Hunter Target and Sitemap Tabs Design

**Date:** 2026-07-21
**Status:** Approved

## Goal

Make Sitemap a subsection of the Target web department, matching the existing
Vulnerabilities/Statistics tab pattern.

## User experience

- The Target department has two tabs: **Target** and **Sitemap**.
- `/targets` remains the Target table and `/targets/sitemap` becomes the
  canonical Sitemap page.
- `/sitemap` redirects to `/targets/sitemap` and preserves its query string.
- The standalone Sitemap sidebar entry is removed. The Target entry is active
  for both the Target and Sitemap controllers.
- Sitemap tree and endpoint Turbo-frame URLs live below
  `/targets/sitemap/...`.

## Architecture

Add `Targets::BaseController < ApplicationController`, include `Department`,
and declare the two shared tabs there. The existing top-level
`TargetsController` and `Sitemap::BaseController` inherit from this base. This
shares only web-department navigation; Sitemap controllers, models, services,
filters, and persistence remain in the `Sitemap` namespace.

Both full index pages render the existing `layouts/department_tabs` partial.
Target XHR row fragments and Sitemap Turbo-frame responses do not render tabs.

## Routing and compatibility

Canonical route helpers are:

- `targets_path` → `/targets`
- `targets_sitemap_path` → `/targets/sitemap`
- `targets_sitemap_origin_tree_path` → `/targets/sitemap/origins/:id/tree`
- `targets_sitemap_endpoint_path` → `/targets/sitemap/endpoints/:id`

The Sitemap routes must precede `/targets/:id` so `sitemap` cannot be treated as
a Target identifier. The legacy `/sitemap` route redirects while retaining
search/filter parameters.

## Testing

Integration tests cover both tabs and their active states, the single active
Target sidebar entry, canonical form/Turbo-frame URLs, route ordering, and the
legacy redirect. Existing Sitemap origin, tree, and endpoint tests move to the
canonical helpers.

## Non-goals

- No changes to Sitemap search, filters, counts, or endpoint behavior.
- No merging of Target Mongo data with Sitemap PostgreSQL data.
- No JSON API changes.
