FactoryBot.define do
  factory :oshi_common_image do
    oshi
    association :registered_by_user, factory: [ :user, :admin ]
    sequence(:source_url) { |n| "https://example.test/source/#{n}" }
    creator_name { "権利者" }
    license_name { "利用許諾済み" }
    attribution_text { "画像提供：権利者" }
    rights_confirmed_at { Time.current }
    active { true }

    after(:build) do |record|
      next if record.image.attached?

      data = File.binread(Rails.root.join("spec/fixtures/files/image.png"))
      record.image.attach(io: StringIO.new(data), filename: "image.png", content_type: "image/png")
    end
  end
end
