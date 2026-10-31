import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["source", "fallback", "picker", "range", "year", "month", "summary", "recover"]
  static values = { currentYear: Number, unset: String, summaryLabel: String }

  connect() {
    const value = this.sourceTarget.value
    const match = /^([0-9]{4})(?:\/(0[1-9]|1[0-2]))?$/.exec(value)
    if (this.sourceTarget.getAttribute("aria-invalid") === "true" || (value !== "" && (!match || match[0] !== value))) {
      this.fallbackTarget.hidden = false
      this.pickerTarget.hidden = true
      this.recoverTarget.hidden = false
      this.element.dataset.oshiPeriodReady = "fallback"
      return
    }
    this.showPicker(match?.[1] || "", match?.[2] || "")
  }

  disconnect() {
    this.fallbackTarget.hidden = false
    this.pickerTarget.hidden = true
    this.recoverTarget.hidden = true
    this.rangeTarget.disabled = true
    this.yearTarget.disabled = true
    this.monthTarget.disabled = true
    delete this.element.dataset.oshiPeriodReady
  }

  showPicker(year, month) {
    const ranges = [new Option(`最近の年（${this.formatYear(this.recentStart)}〜${this.formatYear(this.recentEnd)}年）`, "recent")]
    for (let start = 0; start < 10000; start += 100) {
      ranges.push(new Option(`${this.formatYear(start)}〜${this.formatYear(start + 99)}年`, String(start)))
    }
    this.rangeTarget.replaceChildren(...ranges)
    this.rangeTarget.value = year === "" || (Number(year) >= this.recentStart && Number(year) <= this.recentEnd)
      ? "recent" : String(Math.floor(Number(year) / 100) * 100)
    this.renderYears(year)
    this.monthTarget.value = month
    this.monthTarget.disabled = year === ""
    this.rangeTarget.disabled = false
    this.yearTarget.disabled = false
    this.updateSummary()
    this.fallbackTarget.hidden = true
    this.pickerTarget.hidden = false
    this.recoverTarget.hidden = true
    this.element.dataset.oshiPeriodReady = "picker"
  }

  browseRange() {
    // Browsing candidates must keep the selected year visible and preserve its month.
    this.renderYears(this.yearTarget.value)
  }

  renderYears(selected) {
    const recent = this.rangeTarget.value === "recent"
    const start = recent ? this.recentStart : Number(this.rangeTarget.value)
    const end = recent ? this.recentEnd : start + 99
    const options = [new Option(this.unsetValue, "")]
    if (selected !== "" && (Number(selected) < start || Number(selected) > end)) {
      options.push(new Option(`${selected}年（選択中）`, selected))
    }
    if (recent) {
      const past = document.createElement("optgroup")
      past.label = "今年・過去の年"
      for (let year = Math.min(this.currentYearValue, end); year >= start; year -= 1) {
        past.append(new Option(`${this.formatYear(year)}年`, this.formatYear(year)))
      }
      options.push(past)
      if (end > this.currentYearValue) {
        const future = document.createElement("optgroup")
        future.label = "これからの年"
        for (let year = this.currentYearValue + 1; year <= end; year += 1) {
          future.append(new Option(`${this.formatYear(year)}年`, this.formatYear(year)))
        }
        options.push(future)
      }
    } else {
      for (let year = start; year <= end; year += 1) {
        const value = this.formatYear(year)
        options.push(new Option(`${value}年`, value))
      }
    }
    this.yearTarget.replaceChildren(...options)
    this.yearTarget.value = selected
  }

  change() {
    const year = this.yearTarget.value
    if (year === "") this.monthTarget.value = ""
    this.monthTarget.disabled = year === ""
    this.sourceTarget.value = year ? `${year}${this.monthTarget.value ? `/${this.monthTarget.value}` : ""}` : ""
    this.updateSummary()
  }

  clear() {
    this.sourceTarget.value = ""
    for (const target of [this.sourceTarget, this.pickerTarget, this.yearTarget, this.monthTarget]) {
      target.setAttribute("aria-invalid", "false")
    }
    this.showPicker("", "")
    this.yearTarget.focus()
  }

  updateSummary() {
    const year = this.yearTarget.value
    const month = this.monthTarget.value
    const period = year ? `${year}年${month ? `${Number(month)}月` : ""}` : this.unsetValue
    this.summaryTarget.textContent = `${this.summaryLabelValue}：${period}`
  }

  get recentStart() { return Math.max(0, this.currentYearValue - 79) }
  get recentEnd() { return Math.min(9999, this.currentYearValue + 20) }
  formatYear(year) { return String(year).padStart(4, "0") }
}
