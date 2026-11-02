module Oshis
  class Delete
    class Error < StandardError; end
    class InvalidConfirmation < Error; end
    class InUse < Error
      attr_reader :references

      def initialize(references)
        @references = references
        super("関連データがある推しマスタは削除できません。")
      end
    end

    REFERENCE_MODELS = {
      user_oshis: UserOshi, activity_oshis: ActivityOshi,
      subscription_oshis: SubscriptionOshi, oshi_common_images: OshiCommonImage,
      oshi_aliases: OshiAlias
    }.freeze

    def self.find(id)
      valid = (id.is_a?(Integer) || id.is_a?(String)) &&
        id.to_s.match?(/\A[1-9][0-9]{0,18}\z/) && id.to_i <= 9_223_372_036_854_775_807
      raise ActiveRecord::RecordNotFound unless valid

      Oshi.find(id.to_i)
    end

    def self.references(oshi)
      REFERENCE_MODELS.filter_map do |name, model|
        name if model.unscoped.where(oshi_id: oshi.id).exists?
      end
    end

    def self.confirmation(oshi)
      verifier.generate(fingerprint(oshi), purpose: "delete", expires_in: 15.minutes)
    end

    def self.fingerprint(oshi)
      { "id" => oshi.id, "name" => oshi.name, "status" => oshi.status,
        "updated_at" => oshi.updated_at.iso8601(6) }
    end

    def self.verifier
      Rails.application.message_verifier("admin_oshi_deletion")
    end

    def self.call(id:, confirmation:)
      new(id, confirmation).call
    end

    def initialize(id, confirmation)
      @id = id
      @confirmation = confirmation
    end

    def call
      Oshi.transaction(requires_new: true) do
        record = self.class.find(@id)
        # Only lock the parent, and never wait behind a registration/image/merge
        # transaction. No child row locks or dependent deletions are acquired.
        # Existing immediate, non-cascading FKs block new references while this
        # FOR UPDATE lock is held; recheck every association inside that lock.
        record.lock!("FOR UPDATE NOWAIT")
        raise InvalidConfirmation unless valid_confirmation?(record)

        references = self.class.references(record)
        raise InUse, references if references.any?

        record.destroy!
      end
    end

    private

      def valid_confirmation?(record)
        @confirmation.is_a?(String) && @confirmation.valid_encoding? &&
          @confirmation.bytesize <= 4096 &&
          self.class.verifier.verified(@confirmation, purpose: "delete") == self.class.fingerprint(record)
      end
  end
end
