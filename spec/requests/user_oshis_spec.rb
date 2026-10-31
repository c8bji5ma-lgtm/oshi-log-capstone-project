require "rails_helper"
require_relative "../support/image_attachments"

RSpec.describe "Managing personal oshis", type: :request do
  include ImageAttachments
  let(:user) { create(:user) }

  def document
    Nokogiri::HTML(response.body)
  end

  def add_oshi(oshi, attributes = {}, continuation: nil, **keyword_attributes)
    attributes = attributes.merge(keyword_attributes)
    post user_oshis_path, params: { oshi_id: oshi.id,
      user_oshi: { started_period: "2023/05" }.merge(attributes), continue: continuation }
  end

  def update_oshi(record, attributes)
    patch user_oshi_path(record), params: { user_oshi: attributes }
  end

  context "when signed out" do
    it "requires login for every personal oshi action" do
      record = create(:user_oshi)
      [ oshis_path, user_oshi_path(record), edit_user_oshi_path(record) ].each do |path|
        get path
        expect(response).to redirect_to(new_user_session_path)
      end
      expect { add_oshi(record.oshi) }.not_to change(UserOshi, :count)
      expect(response).to redirect_to(new_user_session_path)
      update_oshi(record, started_period: "2020")
      expect(response).to redirect_to(new_user_session_path)
      expect(record.reload.started_period).to eq("2023")
    end
  end

  context "when signed in" do
    before { post user_session_path, params: { user: { email: user.email, password: "password123" } } }

    it "lists only owned records including already rejected oshis" do
      own = create(:user_oshi, user: user, started_period: "2023/05")
      rejected = create(:user_oshi, user: user, oshi: create(:oshi, :rejected, name: "却下済み本人推し"))
      foreign = create(:user_oshi, oshi: create(:oshi, name: "他人専用推し"))
      get oshis_path
      expect(response).to have_http_status(:ok)
      expect(document.at_css("main").text).to include(own.oshi.name, rejected.oshi.name, "2023/05")
      expect(document.at_css("main").text).not_to include(foreign.oshi.name, "準備中", "rejected")
      expect(document.at_css("main a[href='#{new_oshi_path}']").text).to eq("推しを登録")
      expect(document.at_css("main a[href='#{user_oshi_path(own)}']")).to be_present
      expect(document.at_css("main a[href='#{edit_user_oshi_path(own)}']")).to be_present
    end

    [ :approved, :pending ].each do |status|
      it "adds a permitted #{status} oshi and ignores ownership and unrelated fields" do
        oshi = create(:oshi, status, created_by_user: user)
        other = create(:user)
        expect { add_oshi(oshi, user_id: other.id, oshi_id: create(:oshi).id, ended_period: "2024") }
          .to change(UserOshi, :count).by(1)
        expect(user.user_oshis.last).to have_attributes(oshi_id: oshi.id, started_period: "2023/05", ended_period: nil)
        expect(response).to redirect_to(oshis_path)
      end
    end

    it "adds approved oshis without a creator" do
      oshi = create(:oshi, :approved, created_by_user: nil)
      expect { add_oshi(oshi, started_period: "2023") }.to change(user.user_oshis, :count).by(1)
    end

    it "continues an existing visible oshi to a preselected first activity" do
      oshi = create(:oshi, :approved)
      add_oshi(oshi, {}, continuation: ApplicationController::FIRST_ACTIVITY_CONTINUATION)
      expect(response).to redirect_to(new_activity_path(initial_oshi_id: oshi.id))
    end

    it "keeps an invalid existing-oshi form in the allowlisted continuation" do
      oshi = create(:oshi, :approved)
      add_oshi(oshi, { started_period: "2023/13" }, continuation: ApplicationController::FIRST_ACTIVITY_CONTINUATION)
      expect(response).to have_http_status(:unprocessable_content)
      expect(document.at_css("input#existing_continue")["value"]).to eq(ApplicationController::FIRST_ACTIVITY_CONTINUATION)
      expect(document.at_css("input[name='user_oshi[started_period]']")["value"]).to eq("2023/13")
    end

    it "rejects direct POSTs of unavailable oshis" do
      unavailable = [
        create(:oshi, :pending, created_by_user: create(:user)),
        create(:oshi, :pending, created_by_user: nil),
        create(:oshi, :rejected, created_by_user: user),
        create(:oshi, :rejected, created_by_user: create(:user))
      ]
      unavailable.each do |oshi|
        expect { add_oshi(oshi) }.not_to change(UserOshi, :count)
        expect(response).to have_http_status(:not_found)
      end
    end

    it "rechecks visibility after a candidate was shown" do
      oshi = create(:oshi, :approved)
      get new_oshi_path, params: { q: oshi.name }
      expect(document.at_css("input[type='radio'][value='#{oshi.id}']")).to be_present
      oshi.update!(status: :rejected)
      expect { add_oshi(oshi) }.not_to change(UserOshi, :count)
      expect(response).to have_http_status(:not_found)
    end

    it "requires a separate oshi_id parameter" do
      expect { post user_oshis_path, params: { user_oshi: { started_period: "2023" } } }.not_to change(UserOshi, :count)
      expect(response).to have_http_status(:bad_request)
    end

    it "redisplays the selected candidate and invalid period on addition failure" do
      oshi = create(:oshi, :approved)
      expect { add_oshi(oshi, started_period: "2023/13") }.not_to change(UserOshi, :count)
      expect(response).to have_http_status(:unprocessable_content)
      expect(document.at_css("main h1").text).to eq("推し登録")
      expect(document.at_css("input[type='radio'][checked]")["value"]).to eq(oshi.id.to_s)
      expect(document.at_css("input[name='user_oshi[started_period]']")["value"]).to eq("2023/13")
      expect(document.css(".validation-errors[role='alert']")).not_to be_empty
    end

    it "reports duplicate addition without changing the existing ended record" do
      record = create(:user_oshi, user: user, oshi: create(:oshi, :approved), ended_period: "2024")
      expect { add_oshi(record.oshi, started_period: "2020") }.not_to change(UserOshi, :count)
      expect(response).to redirect_to(oshis_path)
      expect(record.reload).to have_attributes(started_period: "2023", ended_period: "2024")
      follow_redirect!
      expect(document.at_css("[role='alert']").text).to eq("この推しはすでに登録されています。")
    end

    it "handles a concurrent unique-index failure as duplicate addition" do
      oshi = create(:oshi, :approved)
      allow_any_instance_of(UserOshi).to receive(:save).and_raise(ActiveRecord::RecordNotUnique)
      add_oshi(oshi)
      expect(response).to redirect_to(oshis_path)
      follow_redirect!
      expect(document.at_css("[role='alert']").text).to eq("この推しはすでに登録されています。")
    end

    it "shows the common and personal fields with an image placeholder" do
      record = create(:user_oshi, user: user, started_period: "2023/05", ended_period: "2024",
        oshi: create(:oshi, affiliation: "所属表示"))
      get user_oshi_path(record)
      expect(response).to have_http_status(:ok)
      expect(document.at_css("main").text).to include(record.oshi.name, "アイドル", "所属表示", "2023/05", "2024")
      expect(document.at_css("main img")["src"]).to include("image_placeholder")
      expect(document.at_css("main img")["alt"]).to include(record.oshi.name)
      expect(document.at_css("a[href='#{new_card_path(user_oshi_id: record.id)}']").text).to eq("この推しでカードを作る")
      expect(document.at_css("main").text).not_to include("pending", "メモ", "説明")
    end

    it "displays the original image on detail and edit" do
      record = create(:user_oshi, user: user)
      record.representative_image.attach(image_upload)
      [ user_oshi_path(record), edit_user_oshi_path(record) ].each do |path|
        get path
        expect(response).to have_http_status(:ok)
        expect(document.at_css("main img")["src"]).to eq(protected_image_path(record.representative_image.attachment))
        expect(document.at_css("main img")["src"]).not_to include("representations")
      end
    end

    it "allows existing rejected personal records to be viewed and edited" do
      record = create(:user_oshi, user: user, oshi: create(:oshi, :rejected, created_by_user: user))
      [ user_oshi_path(record), edit_user_oshi_path(record) ].each do |path|
        get path
        expect(response).to have_http_status(:ok)
      end
      update_oshi(record, started_period: "2020", ended_period: "2024/05",
        representative_image: Rack::Test::UploadedFile.new(Rails.root.join("spec/fixtures/files/image.png"), "image/png"))
      expect(response).to redirect_to(oshis_path)
      expect(record.reload).to have_attributes(started_period: "2020", ended_period: "2024/05")
      expect(record.representative_image).to be_attached
      expect(record.oshi.reload).to be_rejected
    end

    it "returns 404 for another user's show, edit and update" do
      foreign = create(:user_oshi)
      [ user_oshi_path(foreign), edit_user_oshi_path(foreign) ].each do |path|
        get path
        expect(response).to have_http_status(:not_found)
      end
      update_oshi(foreign, started_period: "2020")
      expect(response).to have_http_status(:not_found)
      expect(foreign.reload.started_period).to eq("2023")
    end

    it "updates only permitted personal fields and returns to the list" do
      record = create(:user_oshi, user: user, ended_period: "2024")
      original_oshi = record.oshi.attributes
      update_oshi(record, started_period: "2021/02", ended_period: "", user_id: create(:user).id,
        oshi_id: create(:oshi).id, status: "approved", created_by_user_id: create(:user).id,
        name: "改ざん", oshi_type: "その他", affiliation: "改ざん", representative_image: "")
      expect(response).to redirect_to(oshis_path)
      expect(record.reload).to have_attributes(user_id: user.id, oshi_id: original_oshi["id"], started_period: "2021/02", ended_period: nil)
      expect(record.oshi.reload.attributes).to eq(original_oshi)
      follow_redirect!
      expect(document.at_css("[role='status']").text).to include("推し情報を更新しました")
    end

    it "preserves all saved data and the displayed image after an invalid replacement" do
      record = create(:user_oshi, user: user)
      record.representative_image.attach(image_upload)
      original_id = record.representative_image.blob.id
      original_image_path = protected_image_path(record.representative_image.attachment)
      update_oshi(record, started_period: "2020",
        representative_image: Rack::Test::UploadedFile.new(Rails.root.join("spec/fixtures/files/invalid.txt"), "text/plain"))
      expect(response).to have_http_status(:unprocessable_content)
      expect(document.at_css("main h1").text).to eq("推し編集")
      expect(document.css(".validation-errors[role='alert']").text).to include("JPEG")
      expect(document.at_css("main img")["src"]).to eq(original_image_path)
      expect(record.reload.started_period).to eq("2023")
      expect(record.representative_image.blob.id).to eq(original_id)
    end

    it "preserves periods and the existing image for an invalid period" do
      record = create(:user_oshi, user: user)
      record.representative_image.attach(image_upload)
      original_id = record.representative_image.blob.id
      update_oshi(record, started_period: "2023/13", ended_period: "2024")
      expect(response).to have_http_status(:unprocessable_content)
      expect(document.at_css("input[name='user_oshi[started_period]']")["aria-invalid"]).to eq("true")
      expect(record.reload).to have_attributes(started_period: "2023", ended_period: nil)
      expect(record.representative_image.blob.id).to eq(original_id)
    end

    it "keeps the image when no replacement file is chosen" do
      record = create(:user_oshi, user: user)
      record.representative_image.attach(image_upload)
      original_id = record.representative_image.blob.id
      update_oshi(record, started_period: "2022", representative_image: "")
      expect(response).to redirect_to(oshis_path)
      expect(record.reload.representative_image.blob.id).to eq(original_id)
    end

    it "retains a selected catalog candidate outside the first twelve after a failed explicit submission" do
      candidates = 14.times.map { |index| create(:oshi, :approved, name: format("カード候補%02d", index)) }
      selected = candidates.last
      count = UserOshi.count
      add_oshi(selected, started_period: "2023/13")
      expect(response).to have_http_status(:unprocessable_content)
      expect(UserOshi.count).to eq(count)
      expect(document.css("#oshi-search-results input[type='radio'][checked]").map { |input| input["value"] }).to eq([ selected.id.to_s ])
      expect(document.at_css("#oshi-search-results .oshi-catalog-card").text).to include(selected.name, "未追加")
      expect(document.at_css("input[name='user_oshi[started_period]']")["value"]).to eq("2023/13")
      snapshot = Nokogiri::HTML(JSON.parse(document.at_css("[data-oshi-registration-target='catalogSnapshot']").text))
      expect(snapshot.css("input[name='oshi_id']").size).to eq(12)
      expect(snapshot.css("input[checked]")).to be_empty
    end
  end
end
