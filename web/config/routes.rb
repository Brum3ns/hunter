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
  end
  get "notifications", to: "notifications#index"

  # Web "departments" — one per Hunter module. Each module owns its own
  # controller + views; add a sibling line here when adding a module.
  get "programs", to: "programs#index"
  namespace :vulnerabilities do
    get "/", to: "overview#index", as: :root
    patch "/:id/status", to: "statuses#update", as: :status
    post "/:id/runs",          to: "runs#create", as: :runs
    get  "/:id/runs/:job_id",  to: "runs#show",   as: :run
    get "/:id", to: "details#show", as: :detail
  end
  get "control_center", to: "control_center#index"
  get "cves", to: "cves#index"

  get "help", to: "help#index"

  # JSON API. Each Hunter module mounts its own resources under /api/v1/<module>.
  # Add new modules as sibling blocks here (programs, control_center, cves, ...).
  namespace :api do
    namespace :v1 do
      # Vulnerability management module.
      resources :vulnerabilities, only: %i[index show create update destroy]

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
