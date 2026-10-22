require "digest"
require "json"
require "yaml"

module InitialCatalog
  class DryRun
    class InvalidCatalog < StandardError; end

    ALLOWED_DECISIONS = %w[review_candidate hold].freeze

    def self.call(path: Rails.root.join("docs/issue-92-initial-catalog-candidates.yml"))
      new(path: path).call
    end

    def initialize(path:)
      @path = Pathname(path)
    end

    def call
      raise InvalidCatalog, "production環境では初期カタログdry-runを実行できません" if Rails.env.production?

      raw = @path.binread
      catalog = YAML.safe_load(raw, permitted_classes: [], aliases: false)
      candidates = Array(catalog&.fetch("candidates"))
      validate_catalog!(catalog, candidates)

      result = nil
      ActiveRecord::Base.transaction(requires_new: true) do
        make_transaction_read_only
        before = database_snapshot
        result = analyze(catalog, candidates, raw)
        result[:database_snapshot] = { before: before, after: database_snapshot }
        raise ActiveRecord::Rollback
      end
      result
    rescue KeyError, Psych::Exception => error
      raise InvalidCatalog, "候補台帳を読み込めません: #{error.message}"
    end

    private

      def validate_catalog!(catalog, candidates)
        raise InvalidCatalog, "version 1の候補台帳が必要です" unless catalog.is_a?(Hash) && catalog["version"] == 1
        raise InvalidCatalog, "候補がありません" if candidates.empty?
        raise InvalidCatalog, "候補はmappingで記述してください" unless candidates.all? { |candidate| candidate.is_a?(Hash) }

        stable_ids = candidates.map { |candidate| candidate["stable_id"] }
        duplicates = stable_ids.tally.select { |_stable_id, count| count > 1 }.keys
        raise InvalidCatalog, "stable_idが重複しています: #{duplicates.join(', ')}" if duplicates.any?
      end

      def analyze(catalog, candidates, raw)
        existing = Oshi.includes(:oshi_aliases).order(:id).to_a
        candidate_collisions = candidate_collisions(candidates)
        actions = {
          create_oshi: [],
          link_existing_oshi: [],
          create_alias: [],
          keep_alias: [],
          conflict: [],
          hold: []
        }

        candidates.each do |candidate|
          stable_id = candidate["stable_id"].to_s
          decision = candidate["decision"].to_s

          unless ALLOWED_DECISIONS.include?(decision)
            actions[:conflict] << conflict(stable_id, "unsupported_decision")
            next
          end

          if decision == "hold"
            actions[:hold] << stable_id
            next
          end

          validation_errors = candidate_errors(candidate)
          if validation_errors.any?
            actions[:conflict] << conflict(stable_id, "invalid_candidate", errors: validation_errors)
            next
          end

          if candidate_collisions.key?(stable_id)
            actions[:conflict] << conflict(stable_id, "candidate_value_collision",
              matches: candidate_collisions.fetch(stable_id))
            next
          end

          matches = existing.filter_map { |oshi| match_for(candidate, oshi) }
          if matches.any?
            actions[:conflict] << conflict(stable_id, "existing_match", matches: matches)
            next
          end

          actions[:create_oshi] << stable_id
          candidate.fetch("aliases", []).each do |alias_name|
            actions[:create_alias] << { stable_id: stable_id, alias_name: alias_name }
          end
        end

        {
          mode: "dry_run",
          writes_performed: false,
          started_at: Time.current.iso8601,
          catalog: {
            path: @path.relative_path_from(Rails.root).to_s,
            sha256: Digest::SHA256.hexdigest(raw),
            version: catalog["version"],
            candidate_count: candidates.size
          },
          connection: {
            environment: Rails.env,
            database: ActiveRecord::Base.connection_db_config.database,
            host: ActiveRecord::Base.connection_db_config.host.presence || "local_socket"
          },
          summary: actions.transform_values(&:size),
          actions: actions,
          images: {
            policy: "placeholder_only",
            blobs_created: 0,
            attachments_created: 0,
            common_images_created: 0
          }
        }
      end

      def candidate_errors(candidate)
        errors = []
        errors << "stable_id_required" if candidate["stable_id"].blank?
        errors << "name_required" if candidate["name"].blank?
        errors << "name_must_be_string" unless candidate["name"].is_a?(String)
        errors << "name_too_long" if candidate["name"].to_s.length > 255
        errors << "invalid_oshi_type" unless Oshi::OSHI_TYPES.include?(candidate["oshi_type"])
        errors << "affiliation_too_long" if candidate["affiliation"].to_s.length > 255

        aliases = candidate["aliases"]
        errors << "aliases_must_be_array" unless aliases.is_a?(Array)
        aliases = Array(aliases)
        errors << "invalid_alias" if aliases.any? { |name| !name.is_a?(String) || name.blank? || name.to_s.length > 255 }
        errors << "duplicate_alias" if aliases.map { |name| normalize(name) }.uniq.size != aliases.size
        errors << "existing_oshi_review_required" unless candidate.dig("review", "existing_oshi") == "checked_local_development_no_match"
        errors << "placeholder_image_required" unless candidate.dig("image", "action") == "placeholder"
        errors
      end

      def candidate_collisions(candidates)
        values = candidates.flat_map do |candidate|
          stable_id = candidate["stable_id"].to_s
          next [] if stable_id.blank?

          [ [ "name", candidate["name"] ], *Array(candidate["aliases"]).map { |value| [ "alias", value ] } ]
            .filter_map do |kind, value|
              normalized = normalize(value)
              { stable_id: stable_id, kind: kind, normalized: normalized } if normalized.present?
            end
        end

        collisions = Hash.new { |hash, key| hash[key] = [] }
        values.group_by { |entry| entry[:normalized] }.each_value do |entries|
          next if entries.map { |entry| entry[:stable_id] }.uniq.one?

          entries.each do |entry|
            entries.reject { |other| other[:stable_id] == entry[:stable_id] }.each do |other|
              collisions[entry[:stable_id]] << {
                stable_id: other[:stable_id],
                candidate_field: entry[:kind],
                other_field: other[:kind]
              }
            end
          end
        end
        collisions.transform_values(&:uniq)
      end

      def match_for(candidate, oshi)
        candidate_values = [ candidate["name"], *Array(candidate["aliases"]) ]
        existing_values = [ oshi.name, *oshi.oshi_aliases.map(&:alias_name) ]
        match_types = []

        candidate_values.each do |candidate_value|
          existing_values.each do |existing_value|
            match_types << "exact" if candidate_value == existing_value
            match_types << "normalized" if candidate_value != existing_value && normalize(candidate_value) == normalize(existing_value)
          end
        end
        return if match_types.empty?

        { oshi_id: oshi.id, status: oshi.status, match_types: match_types.uniq, identity: "unconfirmed" }
      end

      def conflict(stable_id, reason, **details)
        { stable_id: stable_id, reason: reason, **details }
      end

      def normalize(value)
        value.to_s.unicode_normalize(:nfkc).downcase.gsub(/[[:space:]　]+/, "")
      end

      def database_snapshot
        {
          oshis: Oshi.count,
          oshi_aliases: OshiAlias.count,
          active_storage_blobs: ActiveStorage::Blob.count,
          active_storage_attachments: ActiveStorage::Attachment.count,
          oshi_common_images: OshiCommonImage.count,
          oshis_max_updated_at: Oshi.maximum(:updated_at)&.iso8601,
          aliases_max_updated_at: OshiAlias.maximum(:updated_at)&.iso8601
        }
      end

      def make_transaction_read_only
        return unless ActiveRecord::Base.connection.adapter_name == "PostgreSQL"

        ActiveRecord::Base.connection.execute("SET TRANSACTION READ ONLY")
      end
  end
end
