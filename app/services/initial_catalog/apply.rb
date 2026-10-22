require "fileutils"
require "json"
require "tempfile"
require "yaml"

module InitialCatalog
  class Apply
    class Refused < StandardError; end

    EXPECTED_SUMMARY = { create_oshi: 17, create_alias: 23, conflict: 0, hold: 3 }.freeze
    DEFAULT_LEDGER_PATH = Rails.root.join("tmp/issue92_initial_catalog/development-ledger.json")
    ADVISORY_LOCK_KEY = 9_202_610_220_001

    def self.call(expected_sha256:, path: Rails.root.join("docs/issue-92-initial-catalog-candidates.yml"),
      ledger_path: DEFAULT_LEDGER_PATH)
      new(expected_sha256: expected_sha256, path: path, ledger_path: ledger_path).call
    end

    def initialize(expected_sha256:, path:, ledger_path:)
      @expected_sha256 = expected_sha256.to_s
      @path = Pathname(path)
      @ledger_path = Pathname(ledger_path).expand_path
    end

    def call
      raise Refused, "production環境では初期カタログを登録できません" if Rails.env.production?
      validate_ledger_path!

      catalog_sha256 = Digest::SHA256.file(@path).hexdigest
      validate_catalog_sha256!(catalog_sha256)
      if @ledger_path.exist?
        return verify_existing_ledger(catalog_sha256: catalog_sha256)
      end

      preview = InitialCatalog::DryRun.call(path: @path)
      validate_preview!(preview)

      catalog = YAML.safe_load(@path.binread, permitted_classes: [], aliases: false)
      candidates = catalog.fetch("candidates").select { |candidate| candidate["decision"] == "review_candidate" }
      records = []

      ActiveRecord::Base.transaction do
        lock_catalog_tables!
        refuse_new_matches!(candidates)

        candidates.each do |candidate|
          oshi = Oshi.create!(
            name: candidate.fetch("name"),
            oshi_type: candidate.fetch("oshi_type"),
            affiliation: candidate["affiliation"].presence,
            status: :approved,
            created_by_user: nil
          )
          alias_ids = candidate.fetch("aliases", []).map do |alias_name|
            OshiAlias.create!(oshi: oshi, alias_name: alias_name).id
          end
          records << ledger_record(candidate, oshi, alias_ids)
        end

        write_ledger(preview, records, state: "pending_commit")
      end

      write_ledger(preview, records, state: "complete")
      result(preview, records, applied: true)
    rescue InitialCatalog::DryRun::InvalidCatalog, ActiveRecord::ActiveRecordError, JSON::ParserError,
      KeyError, Psych::Exception => error
      raise Refused, error.message
    end

    private

      def validate_preview!(preview)
        validate_catalog_sha256!(preview.dig(:catalog, :sha256))

        actual = EXPECTED_SUMMARY.keys.to_h { |key| [ key, preview.fetch(:summary).fetch(key) ] }
        raise Refused, "予定件数が一致しません: #{actual.inspect}" unless actual == EXPECTED_SUMMARY
        raise Refused, "dry-runが書込みありと報告しました" unless preview[:writes_performed] == false
      end

      def validate_catalog_sha256!(actual_sha256)
        raise Refused, "CATALOG_SHA256が必要です" if @expected_sha256.blank?
        return if ActiveSupport::SecurityUtils.secure_compare(actual_sha256, @expected_sha256)

        raise Refused, "候補台帳のSHA256が承認値と一致しません"
      end

      def validate_ledger_path!
        allowed_root = Rails.root.join("tmp").expand_path
        return if @ledger_path.to_s.start_with?("#{allowed_root}/")

        raise Refused, "実行台帳はリポジトリのtmp配下に保存してください"
      end

      def lock_catalog_tables!
        connection = ActiveRecord::Base.connection
        if connection.adapter_name == "PostgreSQL"
          locked = connection.select_value("SELECT pg_try_advisory_xact_lock(#{ADVISORY_LOCK_KEY})")
          raise Refused, "別の初期カタログ登録が実行中です" unless ActiveModel::Type::Boolean.new.cast(locked)

          connection.execute("LOCK TABLE oshis, oshi_aliases IN SHARE ROW EXCLUSIVE MODE NOWAIT")
        end
      end

      def refuse_new_matches!(candidates)
        existing = Oshi.includes(:oshi_aliases).order(:id).to_a
        conflicts = candidates.filter_map do |candidate|
          candidate_values = [ candidate["name"], *candidate.fetch("aliases", []) ].map { |value| normalize(value) }
          matches = existing.select do |oshi|
            ([ oshi.name ] + oshi.oshi_aliases.map(&:alias_name)).any? do |value|
              candidate_values.include?(normalize(value))
            end
          end
          candidate["stable_id"] if matches.any?
        end
        raise Refused, "dry-run後に既存候補が変化しました: #{conflicts.join(', ')}" if conflicts.any?
      end

      def verify_existing_ledger(catalog_sha256:)
        ledger = JSON.parse(@ledger_path.read)
        raise Refused, "実行台帳のSHA256が一致しません" unless ledger["catalog_sha256"] == catalog_sha256
        raise Refused, "実行台帳の環境が一致しません" unless ledger["environment"] == Rails.env
        unless ledger["database"] == ActiveRecord::Base.connection_db_config.database
          raise Refused, "実行台帳のデータベースが一致しません"
        end

        records = ledger.fetch("records")
        records.each do |record|
          oshi = Oshi.includes(:oshi_aliases).find(record.fetch("oshi_id"))
          expected = record.fetch("attributes")
          actual = {
            "name" => oshi.name,
            "oshi_type" => oshi.oshi_type,
            "affiliation" => oshi.affiliation,
            "status" => oshi.status,
            "created_by_user_id" => oshi.created_by_user_id
          }
          raise Refused, "登録後にOshiが変更されています: #{record.fetch('stable_id')}" unless actual == expected
          unless oshi.oshi_aliases.order(:id).pluck(:id, :alias_name) == record.fetch("aliases").map { |item| [ item.fetch("id"), item.fetch("name") ] }
            raise Refused, "登録後に別名が変更されています: #{record.fetch('stable_id')}"
          end
        end

        preview = { catalog: { sha256: catalog_sha256 } }
        write_ledger(preview, records, state: "complete") if ledger["state"] == "pending_commit"
        result(preview, records, applied: false)
      end

      def ledger_record(candidate, oshi, alias_ids)
        {
          stable_id: candidate.fetch("stable_id"),
          oshi_id: oshi.id,
          attributes: {
            name: oshi.name,
            oshi_type: oshi.oshi_type,
            affiliation: oshi.affiliation,
            status: oshi.status,
            created_by_user_id: oshi.created_by_user_id
          },
          aliases: alias_ids.zip(candidate.fetch("aliases", [])).map { |id, name| { id: id, name: name } }
        }
      end

      def write_ledger(preview, records, state:)
        @ledger_path.dirname.mkpath
        payload = {
          state: state,
          catalog_sha256: preview.dig(:catalog, :sha256),
          environment: Rails.env,
          database: ActiveRecord::Base.connection_db_config.database,
          written_at: Time.current.iso8601,
          records: records
        }
        Tempfile.create([ "issue92-ledger", ".json" ], @ledger_path.dirname) do |file|
          file.chmod(0o600)
          file.write(JSON.pretty_generate(payload))
          file.flush
          file.fsync
          File.rename(file.path, @ledger_path)
        end
        File.chmod(0o600, @ledger_path)
      end

      def result(preview, records, applied:)
        {
          mode: "apply",
          applied: applied,
          catalog_sha256: preview.dig(:catalog, :sha256),
          created_oshis: applied ? records.size : 0,
          created_aliases: applied ? records.sum { |record| record[:aliases]&.size || record["aliases"].size } : 0,
          verified_records: records.size,
          ledger_path: @ledger_path.relative_path_from(Rails.root).to_s
        }
      end

      def normalize(value)
        value.to_s.unicode_normalize(:nfkc).downcase.gsub(/[[:space:]　]+/, "")
      end
  end
end
