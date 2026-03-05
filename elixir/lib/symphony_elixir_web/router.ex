defmodule SymphonyElixirWeb.Router do
  use SymphonyElixirWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {SymphonyElixirWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", SymphonyElixirWeb do
    pipe_through :browser

    live "/", DashboardLive
  end

  scope "/api/v1", SymphonyElixirWeb do
    pipe_through :api

    get "/state", StateController, :index
    post "/refresh", StateController, :refresh
    get "/:issue_identifier", StateController, :show
  end
end
