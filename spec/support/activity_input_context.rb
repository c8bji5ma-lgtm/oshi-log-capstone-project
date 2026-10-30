module ActivityInputContext
  def activity_form_context(path = new_activity_path)
    get path
    field = Nokogiri::HTML(response.body).at_css("meta[name='activity-context-token']")
    raise "Activity form did not issue a context" unless field

    field["content"]
  end
end
