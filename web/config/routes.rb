Rails.application.routes.draw do
  resource :session, only: %i[ new create destroy ]
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  root "dashboard#index"
  get "bugs", to: "bugs#index"
  get "stats", to: "stats#index"
  get "account", to: "account#show"
  get "settings", to: "settings#show"
  namespace :settings do
    resources :runners, only: %i[create destroy]
    resources :ansible_credentials, only: %i[create update destroy]
    resource :schedule, only: :update
    resource :monitor_config, only: :update
  end
  get "notifications", to: "notifications#index"
  get "assistant/exports/:token", to: "assistant/exports#show", as: :assistant_export

  # Web "departments" — one per Hunter module. Each module owns its own
  # controller + views; add a sibling line here when adding a module.
  namespace :programs do
    get "/",           to: "overview#index", as: :root
    get "/monitor",    to: "monitor#index",  as: :monitor
    get "/logs",       to: "logs#index",     as: :logs
    get "/:sid/modal", to: "overview#modal", as: :modal
    post   "/:sid/favorite", to: "favorites#create"
    delete "/:sid/favorite", to: "favorites#destroy"
    post   "/:sid/trash",    to: "trashes#create"
    delete "/:sid/trash",    to: "trashes#destroy"
    post   "/:sid/view",     to: "views#create"
  end
  namespace :vulnerabilities do
    get "/", to: "overview#index", as: :root
    # Must precede the "/:id" detail route so it isn't swallowed as an id.
    get "/statistics", to: "statistics#index", as: :statistics
    patch "/:id/status", to: "statuses#update", as: :status
    post "/:id/runs",          to: "runs#create", as: :runs
    get  "/:id/runs/:job_id",  to: "runs#show",   as: :run
    get "/:id", to: "details#show", as: :detail
  end
  # Control Center web department — Whiterabbit templates + jobs. Tabs are data
  # (ControlCenter::BaseController::TABS); adding one is a one-line change there.
  namespace :control_center do
    get "/",     to: "templates#index", as: :root
    get "/jobs", to: "jobs#index",      as: :jobs
    get "/statistics", to: "statistics#index", as: :statistics
    namespace :ansible do
      get "/", to: "playbooks#index", as: :root
      resources :playbooks, only: :index
      resources :inventories, only: :index
      resources :variable_sets, only: :index
      resources :runs, only: %i[index show]
    end
  end
  # Target web department — configurable assets plus their related Sitemap.
  # Sitemap routes must precede /targets/:id so "sitemap" is not treated as an
  # asset identifier.
  get "targets", to: "targets#index"
  get "targets/sitemap",                 to: "sitemap/origins#index", as: :targets_sitemap
  get "targets/sitemap/origins/:id/tree", to: "sitemap/origins#tree", as: :targets_sitemap_origin_tree
  get "targets/sitemap/endpoints/:id",    to: "sitemap/endpoints#show", as: :targets_sitemap_endpoint
  # Detail loaded into the docked side-panel Turbo Frame (must follow the index).
  get "targets/:id", to: "targets#show", as: :target
  # CVE web department — browse list + single-CVE detail drawer. Mirrors the
  # vulnerabilities namespace. "/:id" is a CVE id (e.g. CVE-2024-1234).
  namespace :cves do
    get "/", to: "overview#index", as: :root
    get "/:id", to: "details#show", as: :detail
  end
  # Preserve bookmarked Sitemap entry URLs, including their active filters.
  get "sitemap", to: redirect(path: "/targets/sitemap"), as: :legacy_sitemap

  get "help", to: "help#index"
  # API documentation (Swagger UI) — a utility department behind session auth.
  get "docs", to: "docs#index"

  # JSON API. Each Hunter module mounts its own resources under /api/v1/<module>.
  # Add new modules as sibling blocks here (programs, control_center, cves, ...).
  namespace :api do
    namespace :v1 do
      # Machine-readable OpenAPI document (scope-filtered per token). Canonical
      # URL /api/v1/openapi; the .json suffix also resolves.
      get "openapi", to: "openapi#show"

      namespace :assistant do
        get "bootstrap", to: "bootstrap#show"
        get "context_options", to: "context_options#index"
        post "context_previews", to: "context_previews#create"
        patch "conversations/order", to: "conversations#reorder"
        patch "conversations/:id", to: "conversations#update", as: :conversation_rename
        resources :conversations, only: %i[index show create destroy] do
          resources :turns, only: %i[create show], shallow: true do
            post :cancel, on: :member
          end
        end
        resources :drafts, only: :show
        post "drafts/:draft_id/confirmed_save", to: "confirmed_saves#create"
        resources :provider_profiles, except: %i[new edit]
        resource :settings, only: %i[show update]
        namespace :machine do
          resource :grant, only: :show, controller: "grants"
          get "capabilities", to: "capabilities#index"
          get "contexts/:resource_type/:id", to: "contexts#show"
          get "artifacts/:resource_type/:id", to: "artifacts#show"
          get "policies/:artifact_type", to: "policies#show"
          post "validations/:artifact_type", to: "validations#create"
          get "validation_results/:id", to: "validations#show"
          # Read-only module tools (Phase 2). Scope-gated in the controller.
          get "targets", to: "targets#index"
          post "targets/analyze", to: "targets#analyze"
          get "targets/:id", to: "targets#show"
          get "cves", to: "cves#index"
          get "cves/new", to: "cves#new"
          post "cves/analyze", to: "cves#analyze"
          get "cves/:id", to: "cves#show"
          get "vulnerabilities", to: "vulnerabilities#index"
          post "vulnerabilities/analyze", to: "vulnerabilities#analyze"
          post "vulnerabilities", to: "vulnerabilities#create"
          patch "vulnerabilities/:id", to: "vulnerabilities#update"
          get "vulnerabilities/:id", to: "vulnerabilities#show"
          get "sitemap/endpoints", to: "sitemap_endpoints#index"
          post "sitemap/endpoints/analyze", to: "sitemap_endpoints#analyze"
          get "sitemap/endpoints/:id", to: "sitemap_endpoints#show", constraints: { id: /\d+/ }
          get "programs", to: "programs#index"
          get "programs/changes", to: "programs#changes"
          get "programs/scope_runs", to: "programs#scope_runs"
          get "programs/scope_runs/:id", to: "programs#scope_run", constraints: { id: /\d+/ }
          post "programs/analyze", to: "programs#analyze"
          get "programs/:id", to: "programs#show"
          namespace :control_center do
            get "templates", to: "templates#index"
            post "templates/analyze", to: "templates#analyze"
            post "templates/validate", to: "templates#validate"
            post "templates/validate_yaml", to: "templates#validate_yaml"
            get "templates/:id", to: "templates#show", constraints: { id: /\d+/ }
            post "templates", to: "templates#create"
            patch "templates/:id", to: "templates#update", constraints: { id: /\d+/ }
            get "jobs", to: "jobs#index"
            post "jobs/analyze", to: "jobs#analyze"
            post "jobs/resolve_targets", to: "jobs#resolve_targets"
            post "jobs", to: "jobs#create"
            get "jobs/:id", to: "jobs#show", constraints: { id: /\d+/ }
            get "health", to: "health#show"
            get "stats", to: "stats#show"
            namespace :ansible do
              get "credentials", to: "credentials#index"
              get "credentials/:id", to: "credentials#show", constraints: { id: /\d+/ }
              get "playbooks", to: "playbooks#index"
              post "playbooks/analyze", to: "playbooks#analyze"
              post "playbooks/validate", to: "playbooks#validate"
              post "playbooks/export", to: "playbooks#export"
              get "playbooks/:id", to: "playbooks#show", constraints: { id: /\d+/ }
              post "playbooks", to: "playbooks#create"
              patch "playbooks/:id", to: "playbooks#update", constraints: { id: /\d+/ }
              get "inventories", to: "inventories#index"
              post "inventories/validate", to: "inventories#validate"
              post "inventories", to: "inventories#create"
              get "inventories/:id", to: "inventories#show", constraints: { id: /\d+/ }
              patch "inventories/:id", to: "inventories#update", constraints: { id: /\d+/ }
              post "inventories/:id/syntax_check", to: "inventories#syntax_check", constraints: { id: /\d+/ }
              post "inventories/:id/host_key_scan", to: "inventories#host_key_scan", constraints: { id: /\d+/ }
              post "inventories/:id/confirm_host_keys", to: "inventories#confirm_host_keys", constraints: { id: /\d+/ }
              post "inventories/:id/connectivity_test", to: "inventories#connectivity_test", constraints: { id: /\d+/ }
              get "inventories/:id/utility_tasks/:task_id", to: "inventories#utility_task", constraints: { id: /\d+/, task_id: /\d+/ }
              get "variable_sets", to: "variable_sets#index"
              post "variable_sets", to: "variable_sets#create"
              get "variable_sets/:id", to: "variable_sets#show", constraints: { id: /\d+/ }
              patch "variable_sets/:id", to: "variable_sets#update", constraints: { id: /\d+/ }
              post "variable_sets/:variable_set_id/variables", to: "variables#create", constraints: { variable_set_id: /\d+/ }
              patch "variable_sets/:variable_set_id/variables/:id", to: "variables#update", constraints: { variable_set_id: /\d+/, id: /\d+/ }
              get "run_groups", to: "run_groups#index"
              post "run_groups/analyze", to: "run_groups#analyze"
              post "run_groups", to: "run_groups#create"
              get "run_groups/:id", to: "run_groups#show", constraints: { id: /\d+/ }
              post "run_groups/:id/cancel", to: "run_groups#cancel", constraints: { id: /\d+/ }
              get "runs/:id", to: "runs#show", constraints: { id: /\d+/ }
              post "runs/:id/cancel", to: "runs#cancel", constraints: { id: /\d+/ }
              get "runs/:run_id/events", to: "run_events#index", constraints: { run_id: /\d+/ }
              get "run_events", to: "run_events#index"
              get "executor_health", to: "executor_health#show"
            end
          end
        end
      end

      # Programs module: Monitor change feed + Logs run feed.
      namespace :programs do
        get "changes",   to: "changes#index"
        get "runs",      to: "runs#index"
        get "runs/:id",  to: "runs#show", constraints: { id: /\d+/ }
      end

      # Vulnerability management module.
      resources :vulnerabilities, only: %i[index show create update destroy]

      # Target module: read-only list + detail over the alive collection.
      resources :targets, only: %i[index show]

      # Sitemap module: read-only endpoint list for job target selection.
      namespace :sitemap do
        resources :endpoints, only: %i[index]
      end

      # CVE tracking module: browse list, single CVE, and an LLM-facing
      # "new since" feed. `cves/new` precedes the :show route so it isn't
      # swallowed as an id.
      get "cves/new",    to: "cves#new"
      get "cves/config", to: "cves#filter_config"
      resources :cves, only: %i[index show]

      # Control Center module: Whiterabbit template CRUD + job submission.
      namespace :control_center do
        namespace :ansible do
          resources :credentials, only: %i[index show create update destroy]
          resources :playbooks, only: %i[index show create update destroy] do
            collection do
              post :validate
              post :export
            end
          end
          resources :inventories, only: %i[index show create update destroy] do
            post :validate, on: :collection
            member do
              post :syntax_check
              post :host_key_scan
              post :confirm_host_keys
              post :connectivity_test
              get "executor_tasks/:task_id", action: :executor_task, as: :executor_task
            end
          end
          resources :variable_sets, only: %i[index show create update destroy] do
            resources :variables, only: %i[create update destroy]
          end
          resources :run_groups, only: %i[index show create] do
            post :cancel, on: :member
          end
          resources :runs, only: :show do
            post :cancel, on: :member
            resources :events, only: :index, controller: "run_events"
          end
          resource :executor_health, only: :show, controller: "executor_health"
        end
        resources :templates, only: %i[index show create update destroy] do
          collection do
            post :validate
            post :validate_yaml
          end
        end
        resources :jobs, only: %i[index show create] do
          post :resolve_targets, on: :collection
        end
        resource :health, only: :show, controller: "health"
        resource :stats, only: :show, controller: "stats"
      end

      namespace :runner do
        post "jobs/claim",      to: "jobs#claim"
        post "jobs/:id/result", to: "jobs#result"
      end

      namespace :ansible_executor do
        post "tasks/claim", to: "tasks#claim"
        post "tasks/:id/heartbeat", to: "tasks#heartbeat"
        post "tasks/:id/result", to: "tasks#result"
        post "runs/claim", to: "runs#claim"
        post "runs/:id/start", to: "runs#start"
        post "runs/:id/heartbeat", to: "runs#heartbeat"
        get "runs/:id/control", to: "runs#control"
        post "runs/:id/events", to: "run_events#create"
        post "runs/:id/result", to: "runs#result"
      end
    end
  end

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Defines the root path route ("/")
  # root "posts#index"
end
