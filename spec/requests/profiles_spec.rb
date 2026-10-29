require "rails_helper"
require_relative "../support/image_attachments"

RSpec.describe "Editing a personal profile", type: :request do
  include ImageAttachments

  let(:user) { create(:user) }

  def document
    # Match the browser's handling of the initial newline in a textarea.
    Nokogiri::HTML5(response.body)
  end

  def update_profile(attributes)
    patch profile_path, params: { profile: attributes }
  end

  def uploaded_image(filename = "image.png", content_type = "image/png")
    Rack::Test::UploadedFile.new(Rails.root.join("spec/fixtures/files", filename), content_type)
  end

  context "when signed out" do
    it "requires login for editing and does not create a profile on update" do
      get edit_profile_path
      expect(response).to redirect_to(new_user_session_path)

      expect { update_profile(display_name: "未ログイン") }.not_to change(Profile, :count)
      expect(response).to redirect_to(new_user_session_path)
    end

    it "does not update an existing profile or image" do
      profile = create(:profile)
      original = profile.attributes
      expect { update_profile(display_name: "改ざん", user_id: profile.user_id, profile_image: uploaded_image) }
        .not_to change(ActiveStorage::Attachment, :count)
      expect(response).to redirect_to(new_user_session_path)
      expect(profile.reload.attributes).to eq(original)
    end
  end

  context "when signed in" do
    before { post user_session_path, params: { user: { email: user.email, password: "password123" } } }

    it "shows the saved values, shared navigation and placeholder" do
      profile = create(:profile, user: user)
      get edit_profile_path

      expect(response).to have_http_status(:ok)
      expect(document.at_css("title").text).to eq("プロフィール編集 | OshiLog")
      expect(document.at_css("main h1").text).to eq("プロフィール編集")
      expect(document.at_css("input[name='profile[display_name]']")["value"]).to eq(profile.display_name)
      expect(document.at_css("textarea[name='profile[introduction]']").text).to eq(profile.introduction)
      expect(document.at_css("main img")["src"]).to include("image_placeholder")
      expect(document.css("nav a").map(&:text)).to eq(%w[トップ 推し一覧 活動記録一覧 マイページ])
      expect(document.at_css("main a[href='#{my_page_path}']").text).to eq("マイページへ戻る")
      form = document.at_css("main form")
      expect(form["action"]).to eq(profile_path)
      expect(form["enctype"]).to eq("multipart/form-data")
      expect(form.at_css("input[name='_method']")["value"]).to eq("patch")
      expect(form.at_css("input[type='file']")["accept"]).to eq("image/jpeg,image/png,image/webp")
      expect(form.css("input[name='profile[user_id]'], input[name='profile[id]']")).to be_empty
    end

    it "shows an empty editor without persisting a profile" do
      expect { get edit_profile_path }.not_to change(Profile, :count)
      expect(response).to have_http_status(:ok)
      expect(document.at_css("input[name='profile[display_name]']")["value"]).to be_nil
      expect(document.at_css("main img")["src"]).to include("image_placeholder")
    end

    it "updates display name and introduction and shows a success message on my page" do
      profile = create(:profile, user: user)
      expect { update_profile(display_name: "新しい表示名", introduction: "ライブの思い出\n次の予定") }
        .not_to change(Profile, :count)

      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to(my_page_path)
      expect(profile.reload).to have_attributes(display_name: "新しい表示名", introduction: "ライブの思い出\n次の予定")
      follow_redirect!
      expect(document.at_css("[role='status']").text).to eq("プロフィールを更新しました。")
      get edit_profile_path
      expect(document.at_css("input[name='profile[display_name]']")["value"]).to eq("新しい表示名")
      expect(document.at_css("textarea[name='profile[introduction]']").text).to eq("ライブの思い出\n次の予定")
    end

    it "creates the current user's first profile, including an image" do
      foreign = create(:profile)
      original = foreign.attributes
      expect do
        update_profile(display_name: "はじめて", introduction: "自己紹介", profile_image: uploaded_image,
          id: foreign.id, user_id: foreign.user_id)
      end.to change(Profile, :count).by(1)

      expect(response).to redirect_to(my_page_path)
      expect(user.reload.profile).to have_attributes(user_id: user.id, display_name: "はじめて", introduction: "自己紹介")
      expect(user.profile.profile_image).to be_attached
      expect(foreign.reload.attributes).to eq(original)
      expect { update_profile(display_name: "二回目") }.not_to change(Profile, :count)
      expect(user.reload.profile.display_name).to eq("二回目")
    end

    it "accepts 50 characters and an empty optional introduction" do
      profile = create(:profile, user: user)
      update_profile(display_name: "あ" * 50, introduction: "")
      expect(response).to redirect_to(my_page_path)
      expect(profile.reload).to have_attributes(display_name: "あ" * 50, introduction: "")
    end

    [ "", " ", "あ" * 51 ].each do |name|
      it "rejects invalid display name #{name.inspect} and retains the input and saved data" do
        profile = create(:profile, user: user)
        original = profile.attributes
        update_profile(display_name: name, introduction: "保存前の自己紹介")

        expect(response).to have_http_status(:unprocessable_content)
        expect(profile.reload.attributes).to eq(original)
        field = document.at_css("input[name='profile[display_name]']")
        expect(field["value"]).to eq(name)
        expect(field["aria-invalid"]).to eq("true")
        expect(document.at_css("textarea[name='profile[introduction]']").text).to eq("保存前の自己紹介")
        expected = build(:profile, display_name: name)
        expected.valid?
        expect(document.at_css(".validation-errors[role='alert']").text).to include(*expected.errors.full_messages)
        expect(document.at_css(".validation-errors[role='alert']").text).not_to include("Display name")
        expect(document.at_css(".validation-errors[role='alert']").text).to include("表示名を入力してください") if name.blank?
      end
    end

    it "keeps a whitespace-only first profile unsaved until its Japanese validation is corrected" do
      submitted = "  初回の自己紹介\n次の行  "
      expect { update_profile(display_name: " ", introduction: submitted) }.not_to change(Profile, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(user.reload.profile).to be_nil
      expect(document.at_css(".validation-errors[role='alert']").text).to include("表示名を入力してください")
      expect(document.at_css(".validation-errors[role='alert']").text).not_to include("Display name")
      expect(document.at_css("input[name='profile[display_name]']")["value"]).to eq(" ")
      expect(document.at_css("textarea[name='profile[introduction]']").text).to eq(submitted)

      expect { update_profile(display_name: "訂正した表示名", introduction: submitted) }.to change(Profile, :count).by(1)
      expect(response).to redirect_to(my_page_path)
      expect(user.reload.profile).to have_attributes(display_name: "訂正した表示名", introduction: submitted)
    end

    it "does not persist a new profile, blob or attachment when first-save validation fails" do
      counts = [ Profile.count, ActiveStorage::Blob.count, ActiveStorage::Attachment.count ]
      update_profile(display_name: "", introduction: "初回の入力", profile_image: uploaded_image)

      expect(response).to have_http_status(:unprocessable_content)
      expect([ Profile.count, ActiveStorage::Blob.count, ActiveStorage::Attachment.count ]).to eq(counts)
      expect(user.reload.profile).to be_nil
      expect(document.at_css("textarea[name='profile[introduction]']").text).to eq("初回の入力")
      expect(document.at_css("main img")["src"]).to include("image_placeholder")
    end

    { "image.jpg" => "image/jpeg", "image.png" => "image/png", "image.webp" => "image/webp" }.each do |filename, content_type|
      it "uploads #{filename} and displays the original through the protected image route" do
        profile = create(:profile, user: user)
        update_profile(profile_image: uploaded_image(filename, content_type))
        expect(response).to redirect_to(my_page_path)
        attachment = profile.reload.profile_image.attachment
        get edit_profile_path
        source = document.at_css("main img")["src"]
        expect(source).to eq(protected_image_path(attachment))
        expect(response.body).not_to include("/rails/active_storage/", attachment.blob.signed_id)

        get source
        expect(response).to have_http_status(:ok)
        expect(response.media_type).to eq(content_type)
        expect(response.body.b).to eq(File.binread(Rails.root.join("spec/fixtures/files", filename)))
        expect(response.headers["Cache-Control"]).to include("private", "no-store")
      end
    end

    it "replaces the image and revokes the previous protected image URL" do
      profile = create(:profile, user: user)
      profile.profile_image.attach(image_upload)
      previous_path = protected_image_path(profile.profile_image.attachment)
      previous_blob_id = profile.profile_image.blob.id
      update_profile(profile_image: uploaded_image("image.webp", "image/webp"))

      expect(response).to redirect_to(my_page_path)
      expect(profile.reload.profile_image.blob.id).not_to eq(previous_blob_id)
      expect(profile.profile_image.download).to eq(File.binread(Rails.root.join("spec/fixtures/files/image.webp")))
      get previous_path
      expect(response).to have_http_status(:not_found)
    end

    [ {}, { profile_image: "" }, { profile_image: nil } ].each do |image_input|
      it "preserves the image when no file is selected: #{image_input.inspect}" do
        profile = create(:profile, user: user)
        profile.profile_image.attach(image_upload)
        original_blob_id = profile.profile_image.blob.id
        original_path = protected_image_path(profile.profile_image.attachment)
        update_profile({ display_name: "画像を維持" }.merge(image_input))

        expect(response).to redirect_to(my_page_path)
        expect(profile.reload.profile_image.blob.id).to eq(original_blob_id)
        get edit_profile_path
        expect(document.at_css("main img")["src"]).to eq(original_path)
      end
    end

    it "preserves the saved image and text when a replacement has an invalid format" do
      profile = create(:profile, user: user)
      profile.profile_image.attach(image_upload)
      original = profile.attributes
      original_blob_id = profile.profile_image.blob.id
      original_path = protected_image_path(profile.profile_image.attachment)
      counts = [ ActiveStorage::Blob.count, ActiveStorage::Attachment.count ]
      update_profile(display_name: "未保存の表示名", introduction: "未保存の自己紹介", profile_image: uploaded_image("invalid.txt", "text/plain"))

      expect(response).to have_http_status(:unprocessable_content)
      expect(profile.reload.attributes).to eq(original)
      expect(profile.profile_image.blob.id).to eq(original_blob_id)
      expect([ ActiveStorage::Blob.count, ActiveStorage::Attachment.count ]).to eq(counts)
      expect(document.at_css("main img")["src"]).to eq(original_path)
      expect(document.at_css("input[name='profile[display_name]']")["value"]).to eq("未保存の表示名")
      expect(document.at_css("textarea[name='profile[introduction]']").text).to eq("未保存の自己紹介")
      expect(document.at_css(".validation-errors").text).to include("JPEG・PNG・WebP")
      expect(document.at_css("input[type='file']")["aria-invalid"]).to eq("true")
    end

    it "preserves the original image when text validation fails with a valid replacement" do
      profile = create(:profile, user: user)
      profile.profile_image.attach(image_upload)
      original_blob_id = profile.profile_image.blob.id
      original_path = protected_image_path(profile.profile_image.attachment)
      update_profile(display_name: "", profile_image: uploaded_image("image.jpg", "image/jpeg"))

      expect(response).to have_http_status(:unprocessable_content)
      expect(profile.reload.profile_image.blob.id).to eq(original_blob_id)
      expect(document.at_css("main img")["src"]).to eq(original_path)
    end

    [ 10 * 1024 * 1024, 10 * 1024 * 1024 + 1 ].each do |size|
      it "enforces the 10 MiB limit for an uploaded file of #{size} bytes" do
        profile = create(:profile, user: user)
        profile.profile_image.attach(image_upload)
        original = profile.attributes
        original_blob_id = profile.profile_image.blob.id
        original_path = protected_image_path(profile.profile_image.attachment)
        counts = [ ActiveStorage::Blob.count, ActiveStorage::Attachment.count ]
        upload = Rack::Test::UploadedFile.new(image_upload(size: size).fetch(:io), "image/png", true, original_filename: "image.png")
        update_profile(display_name: "容量確認", profile_image: upload)

        if size == 10 * 1024 * 1024
          expect(response).to redirect_to(my_page_path)
          expect(profile.reload.profile_image.blob.byte_size).to eq(size)
        else
          expect(response).to have_http_status(:unprocessable_content)
          expect(profile.reload.attributes).to eq(original)
          expect(profile.profile_image.blob.id).to eq(original_blob_id)
          expect([ ActiveStorage::Blob.count, ActiveStorage::Attachment.count ]).to eq(counts)
          expect(document.at_css(".validation-errors").text).to include("10 MiB以下")
          expect(document.at_css("main img")["src"]).to eq(original_path)
        end
      end
    end

    it "ignores foreign profile IDs and owner fields on edit and update" do
      own = create(:profile, user: user)
      foreign = create(:profile)
      foreign.profile_image.attach(image_upload)
      original = foreign.attributes
      image_id = foreign.profile_image.blob.id
      get edit_profile_path, params: { id: foreign.id, profile_id: foreign.id, user_id: foreign.user_id }
      expect(document.at_css("input[name='profile[display_name]']")["value"]).to eq(own.display_name)
      expect(response.body).not_to include(protected_image_path(foreign.profile_image.attachment))

      patch profile_path, params: { id: foreign.id, profile_id: foreign.id, user_id: foreign.user_id,
        profile: { id: foreign.id, user_id: foreign.user_id, display_name: "本人だけ更新", introduction: "本人の自己紹介" } }
      expect(response).to redirect_to(my_page_path)
      expect(own.reload).to have_attributes(user_id: user.id, display_name: "本人だけ更新", introduction: "本人の自己紹介")
      expect(foreign.reload.attributes).to eq(original)
      expect(foreign.profile_image.blob.id).to eq(image_id)
      get protected_image_path(foreign.profile_image.attachment)
      expect(response).to have_http_status(:not_found)
    end

    it "rejects another user's signed blob ID without persisting any changes" do
      own = create(:profile, user: user)
      own.profile_image.attach(image_upload)
      foreign = create(:profile)
      foreign.profile_image.attach(image_upload("image.jpg"))
      original = own.attributes
      own_blob_id = own.profile_image.blob.id
      foreign_blob_id = foreign.profile_image.blob.id
      counts = [ ActiveStorage::Blob.count, ActiveStorage::Attachment.count ]
      update_profile(display_name: "保存しない", introduction: "入力は維持", profile_image: foreign.profile_image.blob.signed_id)

      expect(response).to have_http_status(:unprocessable_content)
      expect(own.reload.attributes).to eq(original)
      expect(own.profile_image.blob.id).to eq(own_blob_id)
      expect(foreign.reload.profile_image.blob.id).to eq(foreign_blob_id)
      expect([ ActiveStorage::Blob.count, ActiveStorage::Attachment.count ]).to eq(counts)
      expect(document.at_css(".validation-errors").text).to include("ファイルとして選択してください")
      expect(document.at_css("input[name='profile[display_name]']")["value"]).to eq("保存しない")
      expect(document.at_css("textarea[name='profile[introduction]']").text).to eq("入力は維持")
      expect(document.at_css("main img")["src"]).to eq(protected_image_path(own.profile_image.attachment))
      get protected_image_path(foreign.profile_image.attachment)
      expect(response).to have_http_status(:not_found)
    end

    it "rejects signed blob reuse on a first save" do
      foreign = create(:profile)
      foreign.profile_image.attach(image_upload)
      expect { update_profile(display_name: "初回", profile_image: foreign.profile_image.blob.signed_id) }
        .not_to change(Profile, :count)
      expect(response).to have_http_status(:unprocessable_content)
      expect(user.reload.profile).to be_nil
      expect(document.at_css("main img")["src"]).to include("image_placeholder")
    end

    [ [ "signed-id" ], { signed_id: "signed-id" } ].each do |image|
      it "rejects non-file image input #{image.inspect}" do
        profile = create(:profile, user: user)
        original = profile.attributes
        update_profile(display_name: "未保存", profile_image: image)
        expect(response).to have_http_status(:unprocessable_content)
        expect(document.at_css(".validation-errors").text).to include("ファイルとして選択してください")
        expect(profile.reload.attributes).to eq(original)
      end
    end

    [ nil, "invalid", [ "invalid" ] ].each do |input|
      it "returns 400 for malformed profile parameters #{input.inspect}" do
        expect { patch profile_path, params: { profile: input } }.not_to change(Profile, :count)
        expect(response).to have_http_status(:bad_request)
      end
    end
  end
end
