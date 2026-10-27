# This file is used by Rack-based servers to start the application.

require_relative "config/environment"

run GraduationGuestDeployment.rack_app(Rails.application, environment: Rails.env)
Rails.application.load_server
