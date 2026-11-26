require "rails_helper"

RSpec.describe "Image format guidance", type: :request do
  it "describes unsupported iPhone formats before selection without widening the accepted formats" do
    user = create(:user)
    record = create(:user_oshi, user: user)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }

    [
      [ new_activity_path, "#activity_images" ],
      [ new_oshi_path, "input[type=file][name='user_oshi[library_images][]']" ],
      [ edit_user_oshi_path(record), "input[type=file]" ],
      [ edit_profile_path, "input[type=file]" ]
    ].each do |path, selector|
      get path
      expect(response).to have_http_status(:ok)

      document = Nokogiri::HTML(response.body)
      inputs = document.css(selector)
      expect(inputs).not_to be_empty
      inputs.each do |input|
        expect(input["accept"]).to eq("image/jpeg,image/png,image/webp")
        help_id = input["aria-describedby"].split.first
        expect(document.at_css("##{help_id}").text).to include("HEIC／HEIF", "すでに撮った写真", "今後の撮影", "互換性優先")
      end
    end
  end
end
