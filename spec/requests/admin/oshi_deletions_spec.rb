require "rails_helper"
require_relative "../../support/image_attachments"
require_relative "../../support/activity_input_context"

RSpec.describe "Administrator unused oshi deletion", type: :request do
  include ImageAttachments
  include ActivityInputContext

  let(:admin) { create(:user, :admin) }
  let(:record) { create(:oshi, :approved, name: "登録済みの推し") }

  def login(account)
    post user_session_path, params: { user: { email: account.email, password: "password123" } }
  end

  def document
    Nokogiri::HTML(response.body)
  end

  def confirmation_for(item)
    get confirm_destroy_admin_oshi_path(item)
    document.at_css("input[name='oshi_delete_confirmation']")&.[]("value")
  end

  def submit(item, token = Oshis::Delete.confirmation(item))
    delete admin_oshi_path(item), params: { oshi_delete_confirmation: token }
  end

  it "requires login before listing, confirming or deleting" do
    record
    [ manage_admin_oshis_path, confirm_destroy_admin_oshi_path(record) ].each do |path|
      get path
      expect(response).to redirect_to(new_user_session_path)
    end
    submit(record)
    expect(response).to redirect_to(new_user_session_path)
    expect(record.reload).to be_persisted
  end

  it "forbids regular users, including the creator, without exposing the target" do
    user = create(:user)
    record.update!(created_by_user: user)
    login(user)
    [ manage_admin_oshis_path, confirm_destroy_admin_oshi_path(record) ].each do |path|
      get path
      expect(response).to have_http_status(:forbidden)
      expect(response.body).not_to include(record.name)
    end
    submit(record)
    expect(response).to have_http_status(:forbidden)
    expect(record.reload).to be_persisted
  end

  context "as an administrator" do
    before { login(admin) }

    it "lists all statuses separately from moderation and finds aliases" do
      records = %i[pending approved rejected].map { |status| create(:oshi, status) }
      get manage_admin_oshis_path
      expect(document.css("main h2").map(&:text)).to include(*records.map(&:name))
      create(:oshi_alias, oshi: records.last, alias_name: "管理検索用別名")
      get manage_admin_oshis_path, params: { q: "管理検索用別名" }
      expect(document.css("main h2").map(&:text)).to eq([ records.last.name ])
      get admin_oshis_path
      expect(document.at_css("a[href='#{manage_admin_oshis_path}']").text).to eq("推しマスタを管理")
      expect(document.css("main h2").map(&:text)).to eq([ records.first.name ])
    end

    it "limits results and reports an empty search" do
      create_list(:oshi, 51)
      get manage_admin_oshis_path
      expect(document.css("main section.card").size).to eq(50)
      expect(response.body).to include("最大50件")
      get manage_admin_oshis_path, params: { q: "一致しない検索語" }
      expect(response.body).to include("表示できる推しマスタはありません")
    end

    it "only reads on GET and escapes the target name and confirmation attribute" do
      record.update!(name: '<script>window.oshiDeleteXss=1</script>"&')
      expect { get confirm_destroy_admin_oshi_path(record), params: { delete: true } }.not_to change(Oshi, :count)
      expect(document.at_css("#oshi-deletion-target").text).to include(record.name)
      expect(document.css("main script")).to be_empty
      expect(document.at_css("a[href='#{manage_admin_oshis_path(q: "")}']").text).to include("キャンセル")
      expect(document.at_css("form[data-turbo-confirm]")["data-turbo-confirm"]).to include(record.name)
    end

    it "refuses direct DELETE without confirmation" do
      submit(record, nil)
      expect(response).to redirect_to(confirm_destroy_admin_oshi_path(record, q: ""))
      expect(record.reload).to be_persisted
      follow_redirect!
      expect(response.body).to include("確認の有効期限")
    end

    it "deletes only the confirmed unused target and safely rejects a repeated submission" do
      other = create(:oshi)
      token = confirmation_for(record)
      expect(token).to be_present
      expect { submit(record, token) }.to change(Oshi, :count).by(-1)
      expect(response).to redirect_to(manage_admin_oshis_path(q: ""))
      follow_redirect!
      expect(document.at_css("[role='status']").text).to include(record.name, "削除しました")
      submit(record, token)
      expect(response).to have_http_status(:not_found)
      expect(other.reload).to be_persisted
    end

    it "rejects malformed IDs and a token belonging to another target" do
      other = create(:oshi)
      delete "/admin/oshis/#{record.id}abc", params: { oshi_delete_confirmation: Oshis::Delete.confirmation(record) }
      expect(response).to have_http_status(:not_found)
      submit(record, Oshis::Delete.confirmation(other))
      expect(record.reload).to be_persisted
      expect(other.reload).to be_persisted
    end

    it "refuses newly added use after the confirmation page" do
      token = confirmation_for(record)
      personal = create(:user_oshi, oshi: record)
      personal.representative_image.attach(image_upload)
      bytes = personal.representative_image.download
      counts = [ Oshi.count, UserOshi.count, ActiveStorage::Blob.count, ActiveStorage::Attachment.count ]
      submit(record, token)
      expect(response).to redirect_to(confirm_destroy_admin_oshi_path(record, q: ""))
      follow_redirect!
      expect(response.body).to include("個人の登録・個人写真", "削除できません")
      expect(document.css("main form[action='#{admin_oshi_path(record, q: "")}']")).to be_empty
      expect([ Oshi.count, UserOshi.count, ActiveStorage::Blob.count, ActiveStorage::Attachment.count ]).to eq(counts)
      expect(personal.reload.representative_image.download).to eq(bytes)
    end

    it "does not expose exception details and retains the master on a transactional error" do
      record
      allow_any_instance_of(Oshi).to receive(:destroy!).and_wrap_original do |method|
        method.call
        raise IOError, "internal-only-deletion-diagnostic"
      end
      expect { submit(record) }.not_to change(Oshi, :count)
      expect(response).to redirect_to(manage_admin_oshis_path(q: ""))
      follow_redirect!
      expect(response.body).to include("推しマスタを削除できませんでした")
      expect(response.body).not_to include("internal-only-deletion-diagnostic", "IOError")
    end

    it "turns foreign-key and lock conflicts into a safe retry with no deletion" do
      record
      [ ActiveRecord::InvalidForeignKey, ActiveRecord::LockWaitTimeout ].each do |error|
        allow(Oshis::Delete).to receive(:call).and_raise(error)
        expect { submit(record) }.not_to change(Oshi, :count)
        expect(response).to redirect_to(confirm_destroy_admin_oshi_path(record, q: ""))
      end
    end
  end

  %i[html json].each do |format|
    it "returns #{format} 404 when deletion wins during personal registration, without orphan uploads" do
      user = create(:user)
      target = create(:oshi, :approved)
      token = Oshis::Delete.confirmation(target)
      login(user)
      if format == :json
        create(:user_oshi, user: user, oshi: create(:oshi, :approved))
        context = activity_form_context
      end
      before = [ UserOshi.count, ActiveStorage::Blob.count, ActiveStorage::Attachment.count ]
      actual_fk_conflict = false
      expect(UserOshis::Save).to receive(:call).and_wrap_original do |method, **arguments|
        Oshis::Delete.call(id: target.id, confirmation: token)
        begin
          method.call(**arguments)
        rescue ActiveRecord::InvalidForeignKey
          actual_fk_conflict = true
          raise
        end
      end
      if format == :json
        post user_oshis_path, params: { oshi_id: target.id, activity_panel: "1",
          activity_context_token: context }, as: :json
        expect(JSON.parse(response.body)).to include("error" => "unavailable")
        expect(response.headers["Cache-Control"]).to include("no-store")
      else
        post user_oshis_path, params: { oshi_id: target.id, user_oshi: {
          library_images: [ Rack::Test::UploadedFile.new(Rails.root.join("spec/fixtures/files/image.png"), "image/png") ]
        } }
        expect(response.body).to include("ページが見つかりません")
      end
      expect(response).to have_http_status(:not_found)
      expect(actual_fk_conflict).to be(true)
      expect(Oshi.exists?(target.id)).to be(false)
      expect(UserOshi.where(oshi_id: target.id)).not_to exist
      expect([ UserOshi.count, ActiveStorage::Blob.count, ActiveStorage::Attachment.count ]).to eq(before)
      files = Dir.glob(File.join(ActiveStorage::Blob.service.root, "**", "*")).select { |path| File.file?(path) }
      expect(files).to be_empty
    end
  end

  it "keeps the administrator guest read-only for the new direct DELETE" do
    %w[demo multi light empty].each { |name| create(:user, email: "#{name}@example.com") }
    create(:user, :admin, email: "admin@example.com")
    record.update!(created_by_user: User.find_by!(email: "demo@example.com"))
    previous = ENV["OSHI_GUEST_SANDBOX"]
    ENV["OSHI_GUEST_SANDBOX"] = "isolated"
    expect(GraduationGuestSandbox.ready?).to be(true)
    post guest_session_path(role: "admin")
    expect(response).to redirect_to(root_path)
    get confirm_destroy_admin_oshi_path(record)
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("ゲストは閲覧専用")
    expect(document.css("main form")).to be_empty
    submit(record)
    expect(response).to have_http_status(:forbidden)
    expect(record.reload).to be_persisted
  ensure
    previous.nil? ? ENV.delete("OSHI_GUEST_SANDBOX") : ENV["OSHI_GUEST_SANDBOX"] = previous
  end
end
