require "resque/server"

Shipit::Application.routes.draw do
  root to: 'stacks#index'

  mount UserRequiredMiddleware.new(Resque::Server.new), at: "/resque"
  mount UserRequiredMiddleware.new(Pubsubstub::StreamAction.new), at: "/events", as: :events

  get '/status/version' => 'status#version', as: :version

  scope '/auth/:provider', as: :authentication, controller: :authentication do
    get '/', action: :mock
    post :callback
    get :callback
    get :logout
  end

  # Robots
  resources :stacks, only: %i(new create index) do
    resource :webhooks, only: [] do
      post :push, :state
    end
  end

  # Humans
  scope '/*id', id: %r{[^/]+/[^/]+/[^/]+}, as: :stack do
    get '/' => 'stacks#show'
    patch '/' => 'stacks#update'
    delete '/' => 'stacks#destroy'
    get :settings, controller: :stacks
    post :refresh, controller: :stacks
    get :refresh, controller: :stacks # For easier design, sorry :/
    post :sync_webhooks, controller: :stacks
    post :clear_git_cache, controller: :stacks
  end

  scope '/*stack_id', stack_id: %r{[^/]+/[^/]+/[^/]+}, as: :stack do
    resources :rollbacks, only: %i(create)
    resources :tasks, only: %i(show) do
      collection do
        get ':definition_id/new' => 'tasks#new', as: :new
        post ':definition_id' => 'tasks#create', as: ''
      end

      resources :chunks, only:  %i(index), defaults: {format: :json} do
        collection do
          get :tail
        end
      end
    end

    resources :deploys, only: %i(new show create) do
      member do
        get :rollback
        post :abort
      end
    end
  end
end
