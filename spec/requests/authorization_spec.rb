require "rails_helper"
require_relative "../support/image_attachments"
require_relative "../support/activity_input_context"

RSpec.describe "Authorization and user data isolation", type: :request do
  include ImageAttachments
  include ActivityInputContext

  let(:user) { create(:user) }
  let(:other_user) { create(:user) }

  def login(account = user)
    post user_session_path, params: { user: { email: account.email, password: "password123" } }
  end

  def data_snapshot
    [ Oshi, OshiAlias, Profile, UserOshi, Activity, ActivityOshi, Subscription, SubscriptionOshi,
      ActiveStorage::Attachment, ActiveStorage::Blob ].to_h do |model|
      [ model.name, model.order(:id).map(&:attributes) ]
    end
  end

  def request_with_format(method, path, format, params: {}, headers: {})
    accept = { html: "text/html", json: "application/json", turbo_stream: "text/vnd.turbo-stream.html" }.fetch(format)
    # Accept selects the response format; JSON preserves typed card parameters.
    public_send(method, path, params: params, as: :json, headers: headers.merge("Accept" => accept))
  end

  def expect_login_response(format)
    if format == :json
      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body).to eq("error" => I18n.t("devise.failure.unauthenticated"))
      expect(response.headers["Location"]).to be_nil
    else
      expect(response).to have_http_status(:found)
      expect(response).to redirect_to(new_user_session_path)
      expect(flash[:alert]).to eq(I18n.t("devise.failure.unauthenticated"))
      expect(flash[:alert]).to eq("続けるにはログインしてください。")
    end
  end

  def expect_not_found_page(format)
    return if format == :json

    expect(response.media_type).to eq("text/html")
    document = Nokogiri::HTML(response.body)
    expect(document.at_css("title").text).to eq("ページが見つかりません | OshiLog")
    expect(document.at_css("main h1").text).to eq("ページが見つかりません")
    expect(document.at_css("main").text).to include("URLを確認するか、ホームから目的の画面を開いてください。")
    expect(document.at_css("main a[href='#{home_path}']").text).to eq("ホームへ戻る")
    expect(response.body).not_to include("ActiveRecord::", "Couldn't find", "他人", "所有者")
  end

  [ :html, :json, :turbo_stream ].each do |format|
    context "with #{format} requests" do
      context "when signed out" do
        let!(:activity) { create(:activity, user: other_user, title: "非公開の活動") }
        let!(:user_oshi) { create(:user_oshi, user: other_user) }
        let!(:profile) { create(:profile, user: other_user) }

        [ [ :get, :index ], [ :get, :new ], [ :get, :show ], [ :get, :edit ],
          [ :post, :create ], [ :patch, :update ], [ :put, :update ], [ :delete, :destroy ] ].each do |method, action|
          it "requires login for Activity #{action} via #{method} without changing data" do
            activity.images.attach(image_upload)
            paths = { index: activities_path, new: new_activity_path, show: activity_path(activity),
              edit: edit_activity_path(activity), create: activities_path, update: activity_path(activity), destroy: activity_path(activity) }
            original = data_snapshot

            request_with_format(method, paths.fetch(action), format, params: { activity: {
              title: "改ざん", occurred_on: "2026-10-01", activity_type: Activity::ACTIVITY_TYPES.first,
              oshi_ids: activity.oshi_ids.map(&:to_s), user_id: other_user.id
            } })

            expect_login_response(format)
            expect(response.body).not_to include(activity.title)
            expect(data_snapshot).to eq(original)
          end
        end

        it "requires login for UserOshi PUT without changing periods or its image" do
          user_oshi.representative_image.attach(image_upload)
          original = data_snapshot
          request_with_format(:put, user_oshi_path(user_oshi), format,
            params: { user_oshi: { started_period: "2020", ended_period: "2025", user_id: other_user.id } })
          expect_login_response(format)
          expect(data_snapshot).to eq(original)
        end

        it "requires login for Profile PUT without changing text or its image" do
          profile.profile_image.attach(image_upload)
          original = data_snapshot
          request_with_format(:put, profile_path, format,
            params: { profile: { id: profile.id, user_id: other_user.id, display_name: "改ざん", introduction: "改ざん" } })
          expect_login_response(format)
          expect(data_snapshot).to eq(original)
        end
      end

      context "when accessing another user's records" do
        before { login }

        let!(:activity) { create(:activity, user: other_user, title: "非公開の活動", memo: "非公開メモ") }
        let!(:user_oshi) { create(:user_oshi, user: other_user) }
        let!(:subscription) { create(:subscription, user: other_user, name: "非公開の固定費", oshis: [ user_oshi.oshi ]) }

        [ [ :get, :show ], [ :get, :edit ], [ :patch, :update ], [ :put, :update ], [ :delete, :destroy ] ].each do |method, action|
          it "returns 404 for foreign Activity #{action} via #{method} and preserves all data" do
            activity.images.attach(image_upload)
            original = data_snapshot
            path = action == :edit ? edit_activity_path(activity) : activity_path(activity)
            request_with_format(method, path, format, params: { activity: {
              title: "改ざん", memo: "改ざん", user_id: user.id, oshi_ids: [ user_oshi.oshi_id.to_s ]
            } })
            expect(response).to have_http_status(:not_found)
            expect_not_found_page(format)
            expect(response.headers["Location"]).to be_nil
            expect(response.body).not_to include(activity.title, activity.memo)
            expect(data_snapshot).to eq(original)
          end
        end

        [ [ :get, :edit ], [ :patch, :update ], [ :put, :update ], [ :delete, :destroy ] ].each do |method, action|
          it "returns 404 for foreign Subscription #{action} via #{method} and preserves all data" do
            original = data_snapshot
            path = action == :edit ? edit_subscription_path(subscription) : subscription_path(subscription)
            request_with_format(method, path, format, params: { subscription: {
              name: "改ざん", amount: 0, billing_cycle: "yearly", user_id: user.id, oshi_ids: []
            } })
            expect(response).to have_http_status(:not_found)
            expect_not_found_page(format)
            expect(response.headers["Location"]).to be_nil
            expect(response.body).not_to include(subscription.name)
            expect(data_snapshot).to eq(original)
          end
        end

        [ [ :get, :show ], [ :get, :edit ], [ :patch, :update ], [ :put, :update ] ].each do |method, action|
          it "returns 404 for foreign UserOshi #{action} via #{method} and preserves all data" do
            user_oshi.representative_image.attach(image_upload)
            original = data_snapshot
            path = action == :edit ? edit_user_oshi_path(user_oshi) : user_oshi_path(user_oshi)
            request_with_format(method, path, format,
              params: { user_oshi: { started_period: "2020", ended_period: "2025", user_id: user.id } })
            expect(response).to have_http_status(:not_found)
            expect_not_found_page(format)
            expect(response.headers["Location"]).to be_nil
            expect(response.body).not_to include(user_oshi.oshi.name, protected_image_path(user_oshi.representative_image.attachment))
            expect(data_snapshot).to eq(original)
          end
        end
      end

      if format != :json
        context "with missing records" do
          before { login }

          [ :activity, :subscription, :user_oshi ].each do |kind|
            it "shows the same 404 content for foreign and nonexistent #{kind} IDs" do
              foreign = create(kind, user: other_user)
              paths = case kind
              when :activity
                [ activity_path(foreign), activity_path(id: Activity.maximum(:id) + 1) ]
              when :subscription
                [ edit_subscription_path(foreign), edit_subscription_path(id: Subscription.maximum(:id) + 1) ]
              when :user_oshi
                [ user_oshi_path(foreign), user_oshi_path(id: UserOshi.maximum(:id) + 1) ]
              end
              original = data_snapshot
              contents = paths.map do |path|
                request_with_format(:get, path, format)
                expect(response).to have_http_status(:not_found)
                expect_not_found_page(format)
                expect(data_snapshot).to eq(original)
                Nokogiri::HTML(response.body).at_css("main").to_html
              end
              expect(contents.first).to eq(contents.last)
            end
          end

          it "uses the same 404 page when adding an unavailable or nonexistent Oshi" do
            foreign = create(:oshi, :pending, created_by_user: other_user, name: "非公開の候補")
            original = data_snapshot
            [ foreign.id, Oshi.maximum(:id) + 1 ].each do |id|
              request_with_format(:post, user_oshis_path, format,
                params: { oshi_id: id.to_s, user_oshi: { started_period: "2020" } })
              expect(response).to have_http_status(:not_found)
              expect_not_found_page(format)
              expect(response.body).not_to include(foreign.name)
              expect(data_snapshot).to eq(original)
            end
          end
        end

        it "displays the Japanese login notice after redirecting to the login page" do
          request_with_format(:get, activities_path, format)
          expect_login_response(format)
          follow_redirect!
          expect(response).to have_http_status(:ok)
          document = Nokogiri::HTML(response.body)
          expect(document.at_css("[role='alert']").text).to eq("続けるにはログインしてください。")
          expect(document.css("[role='alert']").size).to eq(1)
          expect(document.at_css("form[action='#{user_session_path}']")).to be_present
        end

        it "does not turn an unexpected persistence failure into a user-data 404 page" do
          oshi = create(:oshi, :approved)
          create(:user_oshi, user: user, oshi: oshi)
          login
          context_token = activity_form_context
          original = data_snapshot
          allow(Activities::Save).to receive(:call).and_raise(RuntimeError, "unexpected persistence failure")
          expect do
            request_with_format(:post, activities_path, format, params: { activity: {
              occurred_on: "2026-10-01", activity_type: Activity::ACTIVITY_TYPES.first,
              title: "本人の活動", oshi_ids: [ oshi.id.to_s ], context_token: context_token
            } })
          end.to raise_error(RuntimeError, "unexpected persistence failure")
          expect(data_snapshot).to eq(original)
        end
      end

      context "when updating owned records via PUT" do
        before { login }

        it "updates only the owned Activity and ignores a forged owner" do
          oshi = create(:oshi, :approved)
          create(:user_oshi, user: user, oshi: oshi)
          own = create(:activity, user: user)
          foreign = create(:activity, user: other_user)
          context_token = activity_form_context(edit_activity_path(own))
          original = foreign.attributes
          request_with_format(:put, activity_path(own), format,
            params: { activity: { title: "本人の更新", user_id: other_user.id, oshi_ids: [ oshi.id.to_s ],
              lock_version: own.lock_version.to_s, context_token: context_token } })
          expect(response).to have_http_status(:see_other)
          expect(response).to redirect_to(activity_path(own))
          expect(own.reload).to have_attributes(title: "本人の更新", user_id: user.id)
          expect(own.oshi_ids).to eq([ oshi.id ])
          expect(foreign.reload.attributes).to eq(original)
        end

        it "updates only the owned UserOshi and ignores a forged owner and oshi" do
          own = create(:user_oshi, user: user)
          foreign = create(:user_oshi, user: other_user)
          original = foreign.attributes
          oshi_id = own.oshi_id
          request_with_format(:put, user_oshi_path(own), format, params: { user_oshi: {
            started_period: "2020/01", ended_period: "2025", user_id: other_user.id, oshi_id: foreign.oshi_id
          } })
          expect(response).to have_http_status(:see_other)
          expect(response).to redirect_to(oshis_path)
          expect(own.reload).to have_attributes(started_period: "2020/01", ended_period: "2025", user_id: user.id, oshi_id: oshi_id)
          expect(foreign.reload.attributes).to eq(original)
        end

        it "ignores foreign Profile IDs and updates only the current user's profile" do
          own = create(:profile, user: user)
          foreign = create(:profile, user: other_user)
          foreign.profile_image.attach(image_upload)
          original = foreign.attributes
          attachment = foreign.profile_image.attachment.attributes
          blob = foreign.profile_image.blob.attributes
          request_with_format(:put, profile_path, format, params: {
            id: foreign.id, profile_id: foreign.id, user_id: other_user.id,
            profile: { id: foreign.id, user_id: other_user.id, display_name: "本人の更新", introduction: "本人の自己紹介" }
          })
          expect(response).to have_http_status(:see_other)
          expect(response).to redirect_to(my_page_path)
          expect(own.reload).to have_attributes(display_name: "本人の更新", introduction: "本人の自己紹介", user_id: user.id)
          expect(foreign.reload.attributes).to eq(original)
          expect(foreign.profile_image.attachment.attributes).to eq(attachment)
          expect(foreign.profile_image.blob.attributes).to eq(blob)
        end
      end

      context "with admin endpoints" do
        let!(:source) { create(:oshi, :pending, created_by_user: other_user, name: "非公開の申請") }
        let!(:target) { create(:oshi, :approved) }
        let!(:user_oshi) { create(:user_oshi, user: other_user, oshi: source) }

        [ [ :get, :index ], [ :get, :new_merge ], [ :patch, :approve ], [ :patch, :reject ], [ :post, :merge ] ].each do |method, action|
          [ false, true ].each do |signed_in|
            it "#{signed_in ? 'returns 403 for regular users' : 'requires login'} for admin #{action}" do
              login if signed_in
              user_oshi.representative_image.attach(image_upload)
              original = data_snapshot
              paths = { index: admin_oshis_path, new_merge: new_merge_admin_oshis_path,
                approve: approve_admin_oshi_path(source), reject: reject_admin_oshi_path(source), merge: merge_admin_oshis_path }
              expect(Oshis::Merge).not_to receive(:call)
              request_with_format(method, paths.fetch(action), format,
                params: { oshi_merge: { source_id: source.id.to_s, target_id: target.id.to_s } })
              if signed_in
                expect(response).to have_http_status(:forbidden)
                if format == :json
                  expect(response.body).to eq("管理者権限が必要です。")
                  expect(response.media_type).to eq("text/plain")
                else
                  expect(response.media_type).to eq("text/html")
                  document = Nokogiri::HTML(response.body)
                  expect(document.at_css("title").text).to eq("アクセスできません | OshiLog")
                  expect(document.at_css("main h1").text).to eq("アクセスできません")
                  expect(document.at_css("main").text).to include("管理者権限が必要です。")
                  expect(document.at_css("main a[href='#{home_path}']").text).to eq("ホームへ戻る")
                end
                expect(response.headers["Location"]).to be_nil
              else
                expect_login_response(format)
              end
              expect(response.body).not_to include(source.name)
              expect(data_snapshot).to eq(original)
            end
          end
        end
      end

      context "with protected images" do
        [ [ :profile, :profile_image ], [ :user_oshi, :representative_image ], [ :activity, :images ] ].each do |kind, association|
          [ false, true ].each do |signed_in|
            it "returns #{signed_in ? 404 : 401} for a foreign #{kind} image without changing data" do
              record = create(kind, user: other_user)
              record.public_send(association).attach(image_upload)
              attachment = ActiveStorage::Attachment.find_by!(record: record, name: association)
              bytes = attachment.blob.download
              login if signed_in
              original = data_snapshot
              request_with_format(:get, protected_image_path(attachment), format)
              expect(response).to have_http_status(signed_in ? :not_found : :unauthorized)
              expect(response.body).to be_empty
              expect(response.headers["Location"]).to be_nil
              expect(response.headers["Cache-Control"]).to include("private", "no-store")
              expect(data_snapshot).to eq(original)
              expect(attachment.blob.download).to eq(bytes)
            end
          end
        end
      end

      context "with card endpoints" do
        let!(:foreign) { create(:user_oshi, user: other_user) }

        it "requires login for the card page using the existing navigation response" do
          original = data_snapshot
          request_with_format(:get, new_card_path, format)
          expect_login_response(format)
          expect(data_snapshot).to eq(original)
        end

        [ :create, :download ].each do |action|
          it "returns JSON 401 for signed-out card #{action} without changing data" do
            original = data_snapshot
            path = action == :create ? card_path : download_card_path
            request_with_format(:post, path, format, params: { card: {
              user_oshi_ids: [ foreign.id.to_s ], image_user_oshi_ids: [ foreign.id.to_s ], show_introduction: true
            } })
            expect(response).to have_http_status(:unauthorized)
            expect(response.media_type).to eq("application/json")
            expect(response.parsed_body).to eq("error" => "ログインしてください。")
            expect(response.headers["Location"]).to be_nil
            expect(response.headers["Cache-Control"]).to include("private", "no-store")
            expect(data_snapshot).to eq(original)
          end
        end

        it "returns JSON 404 for another user's card sources without changing data" do
          create(:profile, user: user)
          foreign.representative_image.attach(image_upload)
          login
          original = data_snapshot
          request_with_format(:post, card_path, format, params: { card: {
            user_oshi_ids: [ foreign.id.to_s ], image_user_oshi_ids: [ foreign.id.to_s ], show_introduction: true
          } })
          expect(response).to have_http_status(:not_found)
          expect(response.media_type).to eq("application/json")
          expect(response.parsed_body).to eq("error" => "選択した推しは利用できません。")
          expect(response.headers["Location"]).to be_nil
          expect(response.headers["X-Card-Receipt"]).to be_nil
          expect(data_snapshot).to eq(original)
        end

        it "returns JSON 403 for another account's genuine card receipt without changing data" do
          create(:profile, user: other_user)
          foreign.representative_image.attach(image_upload)
          login(other_user)
          request_with_format(:post, card_path, :json, params: { card: {
            user_oshi_ids: [ foreign.id.to_s ], image_user_oshi_ids: [ foreign.id.to_s ], show_introduction: true
          } })
          expect(response).to have_http_status(:ok)
          png = response.body.dup
          receipt = response.headers.fetch("X-Card-Receipt")
          delete destroy_user_session_path
          login
          original = data_snapshot
          accept = { html: "text/html", json: "application/json", turbo_stream: "text/vnd.turbo-stream.html" }.fetch(format)
          post download_card_path, params: png, headers: {
            "CONTENT_TYPE" => "image/png", "X-Card-Receipt" => receipt, "Accept" => accept
          }
          expect(response).to have_http_status(:forbidden)
          expect(response.media_type).to eq("application/json")
          expect(response.parsed_body).to eq("error" => "この画像は保存できません。")
          expect(response.headers["Location"]).to be_nil
          expect(response.headers["Cache-Control"]).to include("private", "no-store")
          expect(data_snapshot).to eq(original)
        end
      end
    end
  end
end
