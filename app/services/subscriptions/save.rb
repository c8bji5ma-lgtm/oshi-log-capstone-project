module Subscriptions
  class Save
    # Scalar attributes and link changes commit together; omitted IDs retain links.
    # Every linked Oshi must be registered to the Subscription owner through UserOshi.
    # expected_lock_version is supplied by persisted edit forms. Programmatic
    # callers may omit it when they are not acting on a user-visible snapshot.
    def self.call(subscription:, attributes: {}, oshi_ids: nil, expected_lock_version: nil)
      Subscription.transaction do
        starting_lock_version = nil
        if subscription.persisted?
          subscription.lock!
          starting_lock_version = subscription.lock_version
          if !expected_lock_version.nil? && expected_lock_version != starting_lock_version
            raise ActiveRecord::StaleObjectError.new(subscription, "update")
          end
          subscription.subscription_oshis.reload
        end
        existing_ids = subscription.subscription_oshis.map(&:oshi_id)
        subscription.assign_attributes(attributes)
        ids = oshi_ids.nil? ? existing_ids : oshi_ids.map { |id| Oshi.type_for_attribute("id").cast(id) }.uniq

        registered_ids = UserOshi.where(user_id: subscription.user_id || subscription.user&.id, oshi_id: ids).pluck(:oshi_id)
        if (ids - registered_ids).any?
          subscription.errors.add(:subscription_oshis, "must belong to oshis registered by the subscription user")
          raise ActiveRecord::RecordInvalid, subscription
        end
        subscription.save!
        (ids - existing_ids).each { |id| subscription.subscription_oshis.create!(oshi_id: id) }
        subscription.subscription_oshis.where.not(oshi_id: ids).each(&:destroy!)
        subscription.subscription_oshis.reload
        if starting_lock_version && subscription.lock_version == starting_lock_version
          subscription.touch
        end
        subscription
      end
    end
  end
end
