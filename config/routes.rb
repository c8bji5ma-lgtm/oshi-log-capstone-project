Rails.application.routes.draw do
  devise_for :users, skip: :registrations
  devise_scope :user do
    get "users/sign_up", to: "devise/registrations#new", as: :new_user_registration
    post "users", to: "devise/registrations#create", as: :user_registration
  end
  root "pages#index"
  get "home", to: "pages#home", as: :home
  get "my_page", to: "pages#my_page", as: :my_page

  get "oshis", to: "user_oshis#index", as: :oshis
  resources :oshis, only: [ :new, :create ]
  resources :user_oshis, only: [ :create, :show, :edit, :update ] do
    resources :images, only: [ :create, :update, :destroy ], controller: "user_oshi_images"
  end
  namespace :admin do
    resources :oshis, only: :index do
      collection do
        get :new_merge
        post :merge
      end
      member do
        patch :approve
        patch :reject
      end
    end
  end
  resources :activities
  get "images/:id", to: "images#show", as: :protected_image
  resources :subscriptions, only: [ :index, :new, :create, :edit, :update, :destroy ]
  get "data", to: "oshi_data#show", as: :oshi_data
  resource :profile, only: [ :edit, :update ]
  resource :card, only: [ :new, :create ] do
    get :memories
    get :memory_materials
    get :statistics
    post :download
  end
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Defines the root path route ("/")
  # root "posts#index"
end
