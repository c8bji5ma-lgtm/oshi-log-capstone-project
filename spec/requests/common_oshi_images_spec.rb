require "rails_helper"
require_relative "../support/image_attachments"

RSpec.describe "Common oshi image delivery", type: :request do
  include ImageAttachments
  let(:user) { create(:user) }

  def login(account)
    post user_session_path, params: { user: { email: account.email, password: "password123" } }
  end

  def common_image(oshi:, active: true)
    record = create(:oshi_common_image, oshi: oshi, active: active)
    record
  end

  it "requires login and sends private security headers" do
    record = common_image(oshi: create(:oshi, :approved))
    get common_oshi_image_path(record.image.attachment)
    expect(response).to have_http_status(:unauthorized)
    login user
    get common_oshi_image_path(record.image.attachment)
    expect(response).to have_http_status(:ok)
    expect(response.headers["Cache-Control"]).to include("private", "no-store")
    expect(response.headers["X-Content-Type-Options"]).to eq("nosniff")
  end

  it "enforces active state and the existing oshi visibility" do
    approved = common_image(oshi: create(:oshi, :approved))
    own = common_image(oshi: create(:oshi, :pending, created_by_user: user))
    foreign = common_image(oshi: create(:oshi, :pending, created_by_user: create(:user)))
    rejected = common_image(oshi: create(:oshi, :rejected, created_by_user: user))
    inactive = common_image(oshi: create(:oshi, :approved), active: false)
    login user
    [ approved, own ].each { |record| get(common_oshi_image_path(record.image.attachment)); expect(response).to have_http_status(:ok) }
    [ foreign, rejected, inactive ].each { |record| get(common_oshi_image_path(record.image.attachment)); expect(response).to have_http_status(:not_found) }
  end

  it "never serves a personal attachment through the common route" do
    personal = create(:user_oshi, user: user)
    personal.representative_image.attach(image_upload)
    login user
    get common_oshi_image_path(personal.representative_image.attachment.id)
    expect(response).to have_http_status(:not_found)
  end
end
