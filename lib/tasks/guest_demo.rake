namespace :guest_demo do
  desc "Initialize an empty, isolated production demo database (never copies real data)"
  task prepare: :environment do
    raise "This task requires the dedicated production demo" unless Rails.env.production?

    result = GuestDemo::Prepare.call
    puts "Demo prepared: #{result.fetch(:users)} users, #{result.fetch(:oshis)} oshis, #{result.fetch(:activities)} activities"
  end
end
