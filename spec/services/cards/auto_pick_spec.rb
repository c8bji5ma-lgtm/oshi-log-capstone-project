require "rails_helper"
require "tmpdir"
require_relative "../../support/card_images"

RSpec.describe Cards::AutoPick do
  include CardImages

  let(:user) { create(:user) }

  around do |example|
    previous_registry = ActiveStorage::Blob.services
    previous_service = ActiveStorage::Blob.service
    Dir.mktmpdir("oshilog-auto-pick-") do |directory|
      storage = ActiveStorage::Service::DiskService.new(root: directory)
      storage.name = "test"
      ActiveStorage::Blob.services = { "test" => storage }
      ActiveStorage::Blob.service = storage
      example.run
    ensure
      ActiveStorage::Blob.services = previous_registry
      ActiveStorage::Blob.service = previous_service
    end
  end

  def recommendation
    described_class.new(user: user).call
  end

  it "chooses data without querying activities when there are no registered oshis" do
    expect(user.activities).not_to receive(:where)
    expect(recommendation).to include(template: "data", user_oshi_ids: [])
  end

  it "prefers the registered user's available images and limits selection to four" do
    records = Array.new(5) { create(:user_oshi, user: user) }
    attach_coordinates(records.last)
    another_user = create(:user)
    create(:user_oshi, user: another_user)
    suggestion = recommendation

    expect(suggestion[:template]).to eq("photo")
    expect(suggestion[:user_oshi_ids]).to eq(
      [ records.last, *records.first(3) ].map { |record| record.id.to_s }
    )
    expect(suggestion[:reason]).to be_present
  end

  it "chooses memories when a user's past activity has an image" do
    create(:user_oshi, user: user)
    activity = create(:activity, user: user, occurred_on: Date.current)
    create(:activity, user: user, occurred_on: Date.current - 1)
    photo = coordinate_image(width: 400, height: 300)
    activity.images.attach(io: StringIO.new(photo), filename: "memory.png", content_type: "image/png")

    expect(recommendation[:template]).to eq("memories")
  end

  it "chooses data for three activities without registered images" do
    create(:user_oshi, user: user)
    3.times { |index| create(:activity, user: user, occurred_on: Date.current - index) }

    expect(recommendation[:template]).to eq("data")
  end

  it "does not count future activity toward the recommended template" do
    record = create(:user_oshi, user: user)
    4.times { create(:activity, user: user, occurred_on: Date.current + 1) }

    expect(recommendation).to include(template: "photo", user_oshi_ids: [ record.id.to_s ])
  end

  it "only recommends the current user's registered oshis" do
    mine = create(:user_oshi, user: user)
    other = create(:user_oshi)
    attach_coordinates(other)

    expect(recommendation[:user_oshi_ids]).to eq([ mine.id.to_s ])
  end
end
