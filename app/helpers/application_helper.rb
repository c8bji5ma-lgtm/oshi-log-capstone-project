module ApplicationHelper
  def global_navigation_current(section)
    current_section = case controller_path
    when "pages"
      action_name == "my_page" ? :my_page : :home
    when "oshis", "user_oshis"
      :oshis
    when "activities"
      :activities
    when "profiles", "oshi_data", "subscriptions", "cards", "admin/oshis", "admin/oshi_common_images"
      :my_page
    end
    return unless section == current_section

    landing_page = (controller_path == "pages" && %w[index home my_page].include?(action_name)) ||
      (%w[user_oshis activities].include?(controller_path) && action_name == "index")
    landing_page ? "page" : "location"
  end
end
