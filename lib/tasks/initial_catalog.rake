namespace :initial_catalog do
  desc "Review the initial Oshi catalog without writing to the database"
  task dry_run: :environment do
    result = InitialCatalog::DryRun.call
    puts JSON.pretty_generate(result)
  rescue InitialCatalog::DryRun::InvalidCatalog => error
    abort("Initial catalog dry-run refused: #{error.message}")
  end

  desc "Apply the reviewed initial Oshi catalog to a non-production database"
  task apply: :environment do
    result = InitialCatalog::Apply.call(expected_sha256: ENV["CATALOG_SHA256"])
    puts JSON.pretty_generate(result)
  rescue InitialCatalog::Apply::Refused => error
    abort("Initial catalog apply refused: #{error.message}")
  end
end
