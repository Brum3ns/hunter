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
    resource :schedule, only: :update
    resource :monitor_config, only: :update
  end
  get "notifications", to: "notifications#index"

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
  end
  # Target web department — configurable table of "alive" assets (MongoDB).
  get "targets", to: "targets#index"
  # Detail loaded into the docked side-panel Turbo Frame (must follow the index).
  get "targets/:id", to: "targets#show", as: :target
  get "cves", to: "cves#index"

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

      # CVE tracking module: browse list, single CVE, and an LLM-facing
      # "new since" feed. `cves/new` precedes the :show route so it isn't
      # swallowed as an id.
      get "cves/new",    to: "cves#new"
      get "cves/config", to: "cves#filter_config"
      resources :cves, only: %i[index show]

      # Control Center module: Whiterabbit template CRUD + job submission.
      namespace :control_center do
        resources :templates, only: %i[index show create update destroy] do
          collection do
            post :validate
            post :validate_yaml
          end
        end
        resources :jobs, only: %i[index show create]
        resource :health, only: :show, controller: "health"
        resource :stats, only: :show, controller: "stats"
      end

      namespace :runner do
        post "jobs/claim",      to: "jobs#claim"
        post "jobs/:id/result", to: "jobs#result"
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
