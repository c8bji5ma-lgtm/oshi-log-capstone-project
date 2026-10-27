require Rails.root.join("lib/graduation_guest_deployment")

if GraduationGuestDeployment.enabled?(environment: Rails.env)
  Rails.application.config.session_store :cookie_store,
    **GraduationGuestDeployment.session_options(environment: Rails.env)

  if Rails.env.production?
    Rails.application.config.active_storage.service = :guest_demo
    Rails.application.config.after_initialize do
      configurations = ActiveRecord::Base.configurations.configs_for(env_name: "production").map do |configuration|
        configuration.configuration_hash.slice(:database, :username).merge(name: configuration.name)
      end
      GraduationGuestDeployment.validate!(configurations: configurations)
    end
  end
end
