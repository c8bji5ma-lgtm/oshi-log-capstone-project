import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["checkbox", "status", "panel", "summary"]
  static values = { labels: Object }

  connect() {
    this.refresh()
    this.statusTarget.hidden = false
  }

  refresh() {
    const count = this.checkboxTargets.filter(input => input.checked).length
    const message = count ? this.labelsValue.selected.replace("%{count}", String(count)) : this.labelsValue.none
    if (this.statusTarget.textContent.trim() !== message) this.statusTarget.textContent = message
  }

  keydown(event) {
    if (event.key !== "Escape" || event.isComposing || !this.panelTarget.open) return

    event.preventDefault()
    this.panelTarget.open = false
    this.summaryTarget.focus()
  }
}
