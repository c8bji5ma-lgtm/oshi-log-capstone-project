module StartedPeriodPicker
  def select_started_period(value)
    root = find("[data-controller='oshi-period'][data-oshi-period-ready]")
    within(root) do
      if value.to_s.match?(/\A[0-9]{4}(?:\/(?:0[1-9]|1[0-2]))?\z/) || value.to_s.empty?
        click_button "入力をクリアして選び直す" if root["data-oshi-period-ready"] == "fallback"
        expect(root).to match_css("[data-oshi-period-ready='picker']")
        if value.to_s.empty?
          click_button "推し始めをクリア"
        else
          year, month = value.split("/")
          range = find("[data-oshi-period-target='range']", visible: :all)
          recent = ((Date.current.year - 79)..(Date.current.year + 20)).cover?(year.to_i)
          desired_range = recent ? "recent" : (year.to_i / 100 * 100).to_s
          if range.value != desired_range
            find("details summary").click unless find("details").evaluate_script("this.open")
            expect(range).to be_visible
            range.find("option[value='#{desired_range}']").select_option
          end
          find("[data-oshi-period-target='year'] option[value='#{year}']").select_option
          select(month ? "#{month.to_i}月" : "未設定", from: find("[data-oshi-period-target='month']")[:id])
        end
      else
        # Invalid periods cannot be chosen in the picker. Keep the existing
        # crafted-POST regression to verify server rejection and raw-value recovery.
        find("[data-oshi-period-target='source']", visible: :all).execute_script("this.value = arguments[0]", value)
      end
    end
  end
end
