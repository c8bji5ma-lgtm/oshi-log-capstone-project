# Dedicated, demo-only deployment gate for the graduation guest accounts.
# Never enable it against a database containing actual users or submissions.
class GraduationGuestSandbox
  ACCOUNTS = {
    "viewer" => "demo@example.com",
    "admin" => "admin@example.com"
  }.freeze
  RESERVED_EMAILS = %w[
    demo@example.com multi@example.com light@example.com
    empty@example.com admin@example.com
  ].freeze

  def self.enabled?
    ENV["OSHI_GUEST_SANDBOX"] == "isolated" &&
      (Rails.env.test? || ENV["OSHI_GUEST_SANDBOX_PRODUCTION_ACK"] == "true")
  end

  def self.reserved_email?(email)
    RESERVED_EMAILS.include?(email.to_s.downcase)
  end

  def self.ready?
    return false unless enabled?
    # Fail closed if a new user has joined the database since the last request.
    return false unless User.count == RESERVED_EMAILS.length
    return false unless User.where(email: RESERVED_EMAILS).count == RESERVED_EMAILS.length
    return false if Oshi.where(created_by_user_id: nil).exists?

    admin = User.find_by(email: ACCOUNTS.fetch("admin"))
    viewer = User.find_by(email: ACCOUNTS.fetch("viewer"))
    admin&.admin? && viewer && !viewer.admin?
  end

  def self.account(role)
    return unless ready?
    email = ACCOUNTS[role]
    User.find_by(email: email) if email
  end

  def self.actor?(user, role)
    user && ACCOUNTS[role] == user.email && user.admin? == (role == "admin")
  end
end
