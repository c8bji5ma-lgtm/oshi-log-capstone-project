module Cards
  class MemoryMaterialsPage
    PAGE_SIZE = 50
    PURPOSE = "card-memory-materials-v1"
    KINDS = %w[oshis images].freeze

    Result = ::Data.define(:records, :next_cursor, :has_more, :total_count)
    class InvalidCursor < StandardError; end
    class InvalidKind < StandardError; end

    def self.call(activity:, kind:, cursor:)
      new(activity:, kind:, cursor:).call
    end

    def initialize(activity:, kind:, cursor:)
      @activity = activity
      @kind = kind
      @cursor = cursor
    end

    def call
      raise InvalidKind unless KINDS.include?(@kind)

      relation = material_scope
      total_count = relation.count
      relation = relation.where("#{relation.klass.quoted_table_name}.id > ?", decode_cursor) if @cursor.present?
      records = relation.limit(PAGE_SIZE + 1).to_a
      has_more = records.length > PAGE_SIZE
      records = records.first(PAGE_SIZE)
      Result.new(records:, next_cursor: (encode_cursor(records.last) if has_more), has_more:, total_count:)
    rescue ActiveSupport::MessageVerifier::InvalidSignature, ArgumentError, TypeError
      raise InvalidCursor
    end

    private
      def material_scope
        case @kind
        when "oshis"
          @activity.activity_oshis.includes(:oshi).reorder(:id)
        when "images"
          @activity.images_attachments.reorder(:id)
        end
      end

      def encode_cursor(record)
        verifier.generate([ @activity.id.to_s, @kind, record.id.to_s ])
      end

      def decode_cursor
        raise InvalidCursor unless @cursor.is_a?(String) && @cursor.bytesize <= 2.kilobytes

        activity_id, kind, id_string = verifier.verify(@cursor)
        raise InvalidCursor unless activity_id == @activity.id.to_s && kind == @kind
        raise InvalidCursor unless id_string.is_a?(String) && id_string.match?(/\A[1-9][0-9]{0,18}\z/)

        Integer(id_string, 10)
      end

      def verifier
        Rails.application.message_verifier(PURPOSE)
      end
  end
end
