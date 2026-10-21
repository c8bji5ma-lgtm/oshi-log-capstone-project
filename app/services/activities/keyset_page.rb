module Activities
  class KeysetPage
    PAGE_SIZE = 50
    PURPOSE_PREFIX = "activity-keyset-v1"
    ORDER = { occurred_on: :desc, created_at: :desc, id: :desc }.freeze
    REVERSE_ORDER = { occurred_on: :asc, created_at: :asc, id: :asc }.freeze

    Result = Data.define(:records, :older_cursor, :newer_cursor, :has_older, :has_newer)
    class InvalidCursor < StandardError; end

    def self.call(scope:, cursor:, direction:, purpose:)
      new(scope:, cursor:, direction:, purpose:).call
    end

    def initialize(scope:, cursor:, direction:, purpose:)
      @scope = scope
      @cursor = cursor
      @direction = direction.presence || "older"
      @purpose = purpose
    end

    def call
      raise InvalidCursor unless %w[older newer].include?(@direction)
      raise InvalidCursor if @cursor.blank? && @direction != "older"

      boundary = decode_cursor if @cursor.present?
      relation = boundary ? after_boundary(boundary) : @scope
      records = relation.reorder(@direction == "newer" ? REVERSE_ORDER : ORDER).limit(PAGE_SIZE + 1).to_a
      has_more = records.length > PAGE_SIZE
      records = records.first(PAGE_SIZE)
      records.reverse! if @direction == "newer"

      Result.new(records:, older_cursor: encode_cursor(records.last), newer_cursor: encode_cursor(records.first),
        has_older: records.any? && (@direction == "newer" || has_more),
        has_newer: records.any? && @cursor.present? && (@direction == "older" || has_more))
    rescue ActiveSupport::MessageVerifier::InvalidSignature, ArgumentError, TypeError
      raise InvalidCursor
    end

    private
      def after_boundary(boundary)
        comparator = @direction == "newer" ? ">" : "<"
        date, created_at, id = boundary
        @scope.where(<<~SQL.squish, date:, created_at:, id:)
          activities.occurred_on #{comparator} :date OR
          (activities.occurred_on = :date AND activities.created_at #{comparator} :created_at) OR
          (activities.occurred_on = :date AND activities.created_at = :created_at AND activities.id #{comparator} :id)
        SQL
      end

      def encode_cursor(record)
        return unless record

        verifier.generate([ record.occurred_on.iso8601, record.created_at.iso8601(6), record.id.to_s ])
      end

      def decode_cursor
        raise InvalidCursor unless @cursor.is_a?(String) && @cursor.bytesize <= 2.kilobytes

        payload = verifier.verify(@cursor)
        raise InvalidCursor unless payload.is_a?(Array) && payload.length == 3

        date = Date.iso8601(payload[0])
        created_at = Time.iso8601(payload[1])
        id_string = payload[2]
        raise InvalidCursor unless id_string.is_a?(String) && id_string.match?(/\A[1-9][0-9]{0,18}\z/)
        id = Integer(id_string, 10)

        [ date, created_at, id ]
      end

      def verifier
        Rails.application.message_verifier("#{PURPOSE_PREFIX}-#{@purpose}")
      end
  end
end
