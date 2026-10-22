require "rails_helper"
require_relative "../support/image_attachments"

RSpec.describe "Admin common oshi images", type: :request do
  include ImageAttachments
  let(:admin) { create(:user, :admin) }
  let(:user) { create(:user) }
  let(:oshi) { create(:oshi, :approved, name: "共通画像の推し") }

  def login(account)
    post user_session_path, params: { user: { email: account.email, password: "password123" } }
  end

  def upload
    Rack::Test::UploadedFile.new(Rails.root.join("spec/fixtures/files/image.png"), "image/png")
  end
  let(:attributes) do
    { oshi_id: oshi.id, source_url: "https://example.test/source", creator_name: "作者",
      license_name: "利用許諾", attribution_text: "画像：作者", rights_confirmed_at: Time.current,
      image: upload }
  end

  it "forbids regular users" do
    login user
    get admin_oshi_common_images_path
    expect(response).to have_http_status(:forbidden)
    expect { post admin_oshi_common_images_path, params: { oshi_common_image: attributes } }
      .not_to change(OshiCommonImage, :count)
    expect(response).to have_http_status(:forbidden)
  end

  it "lets an administrator create, disable and delete a rights-recorded image" do
    login admin
    expect { post admin_oshi_common_images_path, params: { oshi_common_image: attributes } }
      .to change(OshiCommonImage, :count).by(1)
    record = OshiCommonImage.last
    expect(record.image).to be_attached
    patch admin_oshi_common_image_path(record), params: {
      oshi_common_image: attributes.except(:image, :oshi_id).merge(active: "0", lock_version: record.lock_version)
    }
    expect(record.reload).not_to be_active
    expect do
      delete admin_oshi_common_image_path(record), params: { oshi_common_image: { lock_version: record.lock_version } }
    end.to change(OshiCommonImage, :count).by(-1)
  end

  it "rejects stale updates and stale deletes without changing the newer record" do
    record = create(:oshi_common_image, oshi: oshi)
    stale_version = record.lock_version
    record.update!(attribution_text: "新しい帰属")
    login admin

    patch admin_oshi_common_image_path(record), params: {
      oshi_common_image: attributes.except(:image, :oshi_id).merge(
        attribution_text: "古い更新", lock_version: stale_version
      )
    }
    expect(response).to have_http_status(:unprocessable_content)
    expect(record.reload.attribution_text).to eq("新しい帰属")

    expect do
      delete admin_oshi_common_image_path(record), params: { oshi_common_image: { lock_version: stale_version } }
    end.not_to change(OshiCommonImage, :count)
    expect(response).to redirect_to(admin_oshi_common_images_path(q: oshi.name))
    expect(record.reload.attribution_text).to eq("新しい帰属")
  end

  it "does not fetch a source URL" do
    login admin
    expect(Net::HTTP).not_to receive(:get)
    post admin_oshi_common_images_path, params: { oshi_common_image: attributes }
    expect(response).to redirect_to(admin_oshi_common_images_path(q: oshi.name))
  end
end
