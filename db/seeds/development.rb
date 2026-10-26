# Ownership contract: demo@example.com, multi@example.com, light@example.com,
# empty@example.com and admin@example.com are reserved development seed identities.
# Their password, admin flag, Profile and defined associations are reconciled to
# canonical values, even when these reserved records already exist.
# Oshi keys are (name, oshi_type, created_by_user), with the creator being the
# reserved demo or multi user defined below. Alias keys are (oshi, alias_name).
# UserOshi keys are (reserved user, oshi); Activity and Subscription keys are
# (reserved user, defined title/name including the 【デモ】 prefix).
# Other records, including undefined keys under reserved users, are not changed.
# On managed records, only filenames starting with seed- are managed images.
# Manual images are retained, including a manual has_one image in place of a seed.
# Class definitions are loadable for fixed-date tests; only automatic execution
# is development-only (independently of the guard in db/seeds.rb).

module DevelopmentSeeds
  class Dataset
    def initialize(reference_date: Date.current)
      @date = reference_date
      @users = {}
      @oshis = {}
    end

    def call
      raise ArgumentError, "Run the dataset outside an existing DB transaction" if ActiveRecord::Base.connection.transaction_open?

      @image_definitions = []
      # Phase 1: database records and links commit before any file operations.
      ActiveRecord::Base.transaction do
        create_users
        create_oshis
        create_registrations
        create_activities
        Emotion.seed_defaults!
        create_activity_emotions
        create_subscriptions
      end
      # Phase 2 is retryable, not atomic with Phase 1. Errors propagate; the
      # canonical DB records remain committed for the next seed run to repair.
      @image_definitions.each { |record, attribute, filenames| sync_images(record, attribute, filenames) }
      create_common_images
      report if Rails.env.development?
    end

    private

      def report
        puts "Development seed completed (reference date: #{@date})."
        puts "Demo accounts:"
        @users.each_value { |user| puts "#{user.email} / password123" }
        puts "Users: #{@users.size}, Oshis: #{@oshis.size}"
        puts "Activities: #{Activity.where(user: @users.values).count}"
        puts "Subscriptions: #{Subscription.where(user: @users.values).count}"
      end

      def upsert(record, attributes)
        record.assign_attributes(attributes)
        record.save!
        record
      end

      def create_users
        { demo: "YUKI", multi: "MULTI FAN", light: "LIGHT USER", empty: "EMPTY USER", admin: "ADMIN" }.each do |key, name|
          user = User.find_or_initialize_by(email: "#{key}@example.com")
          user.assign_attributes(admin: key == :admin)
          # Retain the password digest when the demo password already matches.
          user.password = user.password_confirmation = "password123" unless user.valid_password?("password123")
          user.save!
          @users[key] = user
          profile = upsert(user.profile || user.build_profile,
            display_name: name, introduction: key == :demo ? "推し活の記録を楽しんでいます。" : nil)
          @image_definitions << [ profile, :profile_image, key == :demo ? [ "seed-flowers.jpg" ] : [] ]
        end
      end

      def create_oshis
        [
          [ "LUMINA", "アイドル", "LUMINA PROJECT", "approved", :demo ],
          [ "ASTER", "アーティスト", "ASTER MUSIC", "approved", :demo ],
          [ "MIO", "アイドル", "LUMINA PROJECT", "pending", :demo ],
          [ "NOVA", "キャラクター", "Star Story", "rejected", :demo ],
          [ "SOL", "アーティスト", "SOL RECORDS", "approved", :multi ],
          [ "OTHER PENDING", "アイドル", "ORBIT PROJECT", "pending", :multi ]
        ].each do |name, type, affiliation, status, owner|
          # This complete key is reserved; unrelated same-name masters are untouched.
          record = Oshi.find_or_initialize_by(name: name, oshi_type: type, created_by_user: @users.fetch(owner))
          @oshis[name] = upsert(record, affiliation: affiliation, status: status)
        end
        { "LUMINA" => "ルミナ", "ASTER" => "アスター", "MIO" => "ミオ", "NOVA" => "ノヴァ", "SOL" => "ソル" }.each do |name, alias_name|
          @oshis.fetch(name).oshi_aliases.find_or_create_by!(alias_name: alias_name)
        end
      end

      def create_registrations
        {
          demo: [
            [ "LUMINA", (@date - 2.years).strftime("%Y/%m"), nil, "seed-concert.jpg" ],
            [ "ASTER", (@date.year - 1).to_s, nil, "seed-microphone.jpg" ],
            [ "MIO", (@date - 1.year).strftime("%Y/%m"), (@date - 7.months).strftime("%Y/%m"), nil ],
            [ "NOVA", nil, nil, nil ]
          ],
          multi: [ [ "LUMINA", "2023", nil, nil ], [ "ASTER", "2024/04", nil, nil ], [ "SOL", "2024", nil, nil ] ],
          light: [ [ "SOL", (@date.year - 1).to_s, nil, nil ] ]
        }.each do |key, definitions|
          definitions.each do |name, started, ended, image|
            record = @users.fetch(key).user_oshis.find_or_initialize_by(oshi: @oshis.fetch(name))
            upsert(record, started_period: started, ended_period: ended)
            @image_definitions << [ record, :representative_image, Array(image) ]
          end
        end
      end

      def month_date(offset)
        (@date.beginning_of_month - offset.months).change(day: [ @date.day, 5 ].min)
      end

      def year_date(year, month)
        [ Date.new(year, month, 5), @date ].min
      end

      def activity(user, title, date, category, amount, names = [ "LUMINA" ], place: nil, memo: nil, images: [])
        # Stable titles identify seeds even when their dates move on subsequent runs.
        record = @users.fetch(user).activities.find_or_initialize_by(title: "【デモ】#{title}")
        Activities::Save.call(activity: record,
          attributes: { occurred_on: date, activity_type: category, amount: amount, place: place, memo: memo },
          oshi_ids: names.map { |name| @oshis.fetch(name).id })
        @image_definitions << [ record, :images, images ]
      end

      def create_activities
        # Recent three calendar months: six live events out of eight activities.
        [
          [ "周年ライブ", 0, "ライブ・イベント", 12000, [ "LUMINA" ], "福岡", "周年ライブのアンコールが忘れられない。", [ "seed-concert.jpg", "seed-microphone.jpg", "seed-flowers.jpg" ] ],
          [ "合同ライブ", 0, "ライブ・イベント", 10000, [ "LUMINA", "ASTER" ], "東京", "初めての遠征。", [ "seed-concert.jpg" ] ],
          [ "福岡公演", 0, "ライブ・イベント", 8000, [ "LUMINA" ], "福岡", nil, [] ],
          [ "ライブ後のカフェ", 0, "その他", 1200, [ "LUMINA" ], "福岡", "余韻をノートに残した。", [] ],
          [ "コラボイベント", 1, "ライブ・イベント", 6000, [ "LUMINA", "MIO" ], "東京", nil, [] ],
          [ "ツアー遠征", 1, "ライブ・イベント", 50000, [ "LUMINA" ], "東京", "交通費と宿泊費も含めた遠征。", [] ],
          [ "ホール公演", 2, "ライブ・イベント", 18400, [ "LUMINA" ], "福岡", nil, [] ],
          [ "ライブ記念アクスタ購入", 2, "グッズ購入", 3000, [ "LUMINA" ], nil, "限定グッズを購入。", [] ],
          # Previous three months: streaming and merchandise, no live events.
          [ "YouTube生配信", 3, "配信視聴", 0, [ "LUMINA" ], "オンライン", nil, [] ],
          [ "新曲リリース配信", 3, "配信視聴", nil, [ "LUMINA" ], "オンライン", "新曲の制作秘話。", [] ],
          [ "通販アクスタ購入", 4, "グッズ購入", 3000, [ "LUMINA" ], nil, "限定グッズの再販。", [] ],
          [ "メンバー限定配信", 5, "配信視聴", 1200, [ "LUMINA" ], "オンライン", nil, [] ]
        ].each do |title, offset, category, amount, names, place, memo, images|
          activity(:demo, title, month_date(offset), category, amount, names, place: place, memo: memo, images: images)
        end

        # February stays empty when outside the moving comparison windows.
        [
          [ "新年の雑誌インタビュー", 1, "メディア視聴", nil, [ "ASTER" ] ],
          [ "新年の応援ノート", 1, "その他", 0, [ "NOVA" ] ],
          [ "写真集購入", 3, "グッズ購入", 4500, [ "LUMINA" ] ],
          [ "ラジオ特集", 4, "メディア視聴", nil, [ "LUMINA" ] ]
        ].each do |title, month, category, amount, names|
          activity(:demo, title, year_date(@date.year, [ month, @date.month ].min), category, amount, names)
        end

        [ 1, 3, 4, 5, 6, 7, 8, 9, 11, 12 ].zip([
          "新年配信の思い出", "春のグッズ通販", "春の雑誌特集", "新曲MV鑑賞", "夏の配信トーク",
          "応援ノートを整理", "限定ポーチ購入", "秋のラジオ特番", "冬の配信視聴", "年末グッズ購入"
        ]).each_with_index do |(month, title), index|
          category = [ "配信視聴", "グッズ購入", "メディア視聴", "メディア視聴", "配信視聴",
            "その他", "グッズ購入", "メディア視聴", "配信視聴", "グッズ購入" ][index]
          activity(:demo, title, year_date(@date.year - 1, month), category, index.even? ? 1200 : nil)
        end
        activity(:demo, "初めての応援配信", year_date(@date.year - 2, 6), "配信視聴", 0)
        activity(:demo, "最初のグッズ購入", year_date(@date.year - 2, 9), "グッズ購入", 2500)

        [ "合同ツアー初日", "合同ツアー千秋楽", "コラボ配信", "合同グッズ通販", "フェス遠征",
          "新曲対談", "合同ラジオ", "コラボ展示", "ソロ公演", "ライブ映像鑑賞" ].each_with_index do |title, index|
          names = index < 8 ? [ "LUMINA", "ASTER", "SOL" ].first(index.even? ? 2 : 3) : [ "SOL" ]
          category = [ "ライブ・イベント", "ライブ・イベント", "配信視聴", "グッズ購入", "ライブ・イベント",
            "メディア視聴", "メディア視聴", "その他", "ライブ・イベント", "メディア視聴" ][index]
          activity(:multi, title, month_date(index % 3), category, 2000 + index * 1000, names)
        end
        [ "SOL配信デビュー", "SOL新曲配信", "SOLライブ初参加", "SOL小ホール公演" ].each_with_index do |title, index|
          activity(:light, title, month_date(index % 2), index < 2 ? "配信視聴" : "ライブ・イベント",
            index < 2 ? nil : 3000, [ "SOL" ])
        end
      end

      # Link five actual demo activities to the seeded emotion master.
      def create_activity_emotions
        [ "周年ライブ", "合同ライブ", "福岡公演", "ライブ後のカフェ", "コラボイベント" ]
          .zip(Emotion::DEFAULT_NAMES.first(5)).each do |title, name|
          activity = @users.fetch(:demo).activities.find_by!(title: "【デモ】#{title}")
          emotion = Emotion.find_by!(name: name)
          ActivityEmotion.find_or_create_by!(activity: activity, emotion: emotion)
        end
      end

      # Only existing, documented Unsplash-licensed local images may be used.
      # This uses the same validated create service as the administrator UI;
      # no HTTP download, fabricated authorship or production seed is allowed.
      def create_common_images
        sources = [
          [ "LUMINA", "seed-concert.jpg", "https://unsplash.com/photos/group-of-people-attending-a-performance-8XLapfNMW04", "Yvette de Wit" ],
          [ "LUMINA", "seed-microphone.jpg", "https://unsplash.com/photos/condenser-microphone-with-black-background-OKLqGsCT8qs", "Matt Botsford" ],
          [ "ASTER", "seed-flowers.jpg", "https://unsplash.com/photos/red-flower-arrangement-on-white-table-0IsBu45B3T8", "Christie Kim" ],
          [ "ASTER", "seed-microphone.jpg", "https://unsplash.com/photos/condenser-microphone-with-black-background-OKLqGsCT8qs", "Matt Botsford" ],
          [ "SOL", "seed-concert.jpg", "https://unsplash.com/photos/group-of-people-attending-a-performance-8XLapfNMW04", "Yvette de Wit" ]
        ]
        sources.each do |oshi_name, filename, source_url, author|
          oshi = @oshis.fetch(oshi_name)
          next if OshiCommonImage.exists?(oshi: oshi, source_url: source_url, registered_by_user: @users.fetch(:admin))

          path = Rails.root.join("db/seeds/assets", filename)
          # UploadedFile#open delegates to tempfile.open; a plain File lacks
          # the public Tempfile#open method expected by the production service.
          tempfile = Tempfile.new([ "oshi-seed-", ".jpg" ])
          begin
            tempfile.binmode
            tempfile.write(File.binread(path))
            tempfile.rewind
            upload = ActionDispatch::Http::UploadedFile.new(
              tempfile: tempfile, filename: filename, type: "image/jpeg"
            )
            OshiCommonImages::Create.call(
              oshi: oshi, administrator: @users.fetch(:admin), file: upload,
              attributes: {
                source_url: source_url, creator_name: author, license_name: "Unsplash License",
                attribution_text: "写真：#{author} / Unsplash",
                usage_notes: "開発用のイメージ写真です。架空の推し本人を撮影したものではありません。",
                rights_confirmed_at: Time.zone.local(2026, 10, 6, 12),
                active: true
              }
            )
          ensure
            tempfile.close!
          end
        end
      end

      def subscription(user, name, amount, cycle, names, started: nil, ended: nil)
        record = @users.fetch(user).subscriptions.find_or_initialize_by(name: "【デモ】#{name}")
        Subscriptions::Save.call(subscription: record,
          attributes: { amount: amount, billing_cycle: cycle, started_on: started, ended_on: ended },
          oshi_ids: names.map { |oshi| @oshis.fetch(oshi).id })
      end

      def create_subscriptions
        subscription(:demo, "ファンクラブ", 550, "monthly", [ "LUMINA" ])
        subscription(:demo, "メンバーシップ", 980, "monthly", [ "LUMINA" ], started: @date - 1.year)
        subscription(:demo, "年会費", 6600, "yearly", [ "LUMINA" ])
        subscription(:demo, "合同ファンサービス", 1500, "monthly", [ "LUMINA", "ASTER" ])
        subscription(:demo, "推し活クラウド", 500, "monthly", [])
        subscription(:demo, "過去の配信サービス", 1000, "monthly", [ "NOVA" ], started: @date - 1.year, ended: @date - 1.month)
        subscription(:demo, "来月開始サービス", 2000, "monthly", [ "ASTER" ], started: @date + 1.month)
        subscription(:demo, "ASTERファンクラブ", 550, "monthly", [ "ASTER" ])
        subscription(:multi, "合同サポーター", 3000, "monthly", [ "LUMINA", "ASTER" ])
        subscription(:multi, "SOL年会費", 12000, "yearly", [ "SOL" ])
        subscription(:multi, "記録クラウド", 800, "monthly", [])
        subscription(:light, "SOLメンバーシップ", 500, "monthly", [ "SOL" ])
      end

      def sync_images(record, attribute, filenames)
        attached = record.public_send(attribute)
        existing = attached.is_a?(ActiveStorage::Attached::Many) ? attached.attachments.to_a : Array(attached.attachment)
        desired = filenames.to_h do |filename|
          path = Rails.root.join("db/seeds/assets", filename)
          [ filename, [ path, Digest::MD5.file(path).base64digest ] ]
        end
        # Reconcile only seed images, retaining a user's own uploads.
        removed = false
        seen = []
        existing.each do |attachment|
          filename = attachment.blob.filename.to_s
          next unless filename.start_with?("seed-")
          if desired[filename]&.last != attachment.blob.checksum || seen.include?(filename)
            attachment.purge
            removed = true
          end
          seen << filename
        end
        attached = record.reload.public_send(attribute) if removed
        filenames.each do |filename|
          path, checksum = desired.fetch(filename)
          match = existing.find { |item| !item.destroyed? && item.blob.filename.to_s == filename && item.blob.checksum == checksum }
          if match
            # A failed after-commit upload can leave a valid attachment without
            # its file. Retry that upload without creating another blob/link.
            match.blob.upload(StringIO.new(File.binread(path))) unless match.blob.service.exist?(match.blob.key)
            next
          end
          next if attached.is_a?(ActiveStorage::Attached::One) && attached.attached?
          attached.attach(io: StringIO.new(File.binread(path)), filename: filename, content_type: "image/jpeg")
        end
      end
  end
end

DevelopmentSeeds::Dataset.new.call if Rails.env.development?
