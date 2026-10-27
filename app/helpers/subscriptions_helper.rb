module SubscriptionsHelper
  def billing_cycle_label(cycle)
    t({ "monthly" => "ui.billing_cycles.monthly", "yearly" => "ui.billing_cycles.yearly" }.fetch(cycle))
  end
end
