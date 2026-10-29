import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "searchForm", "query", "searchButton", "results", "existingFields", "existingQuery",
    "existingPanel", "registrationPanel", "name", "status", "existingLink", "registrationLink"
  ]
  static values = { searching: String, failed: String, copied: String, kept: String, cleared: String, help: String }

  connect() {
    this.serial = 0
    this.focusEpoch = 0
    this.leaving = false
    this.composing = false
    this.compositionJustEnded = false
    this.nameEdited = this.nameTarget.value !== ""
    this.autoName = null
    this.setCurrent(this.registrationPanelTarget.contains(document.activeElement) ? "registration" : "existing")
  }

  disconnect() {
    this.leave()
  }

  ignoreImplicitSubmit(event) {
    event.preventDefault()
  }

  confirmSearch(event) {
    event.preventDefault()
    // An IME-confirming Enter can generate an implicit click on the submit button.
    if (event.detail === 0 && document.activeElement !== event.currentTarget) return
    if (this.composing) return
    this.compositionJustEnded = false
    this.search()
  }

  searchKeydown(event) {
    if (event.key !== "Enter") return
    if (this.composing || this.compositionJustEnded || event.isComposing || event.keyCode === 229) return
    event.preventDefault()
    this.search()
  }

  compositionStart() {
    this.composing = true
    this.cancelPending()
  }

  compositionEnd() {
    this.composing = false
    this.compositionJustEnded = true
  }

  compositionKeyup() {
    if (!this.composing) this.compositionJustEnded = false
  }

  queryChanged() {
    this.cancelPending()
    this.setStatus("")
  }

  nameChanged() {
    this.nameEdited = true
  }

  trackFocus(event) {
    if (!this.searchFormTarget.contains(event.target)) this.otherIntent()
    if (this.registrationPanelTarget.contains(event.target)) this.setCurrent("registration")
    else if (this.existingPanelTarget.contains(event.target)) this.setCurrent("existing")
  }

  trackPointer(event) {
    if (!this.searchFormTarget.contains(event.target)) this.otherIntent()
  }

  trackScrollIntent() {
    this.focusEpoch += 1
  }

  otherIntent() {
    this.focusEpoch += 1
    if (this.pendingQuery !== null && this.pendingQuery !== undefined) {
      this.cancelPending()
      this.setStatus("")
    }
  }

  leave() {
    this.leaving = true
    this.cancelPending()
  }

  visibilityChanged() {
    if (document.visibilityState === "hidden") this.leave()
    else this.leaving = false
  }

  cancelPending() {
    this.serial += 1
    this.abortController?.abort()
    this.abortController = null
    this.pendingQuery = null
    if (this.hasResultsTarget) this.resultsTarget.removeAttribute("aria-busy")
  }

  current(serial, query) {
    return !this.leaving && this.element.isConnected && this.serial === serial &&
      this.queryTarget.value === query
  }

  async search() {
    const query = this.queryTarget.value
    if (this.composing || this.leaving || this.pendingQuery === query) return
    this.cancelPending()

    if (query.trim() === "") {
      this.resultsTarget.replaceChildren()
      this.existingFieldsTarget.hidden = true
      this.setStatus(this.helpValue)
      return
    }

    const serial = this.serial
    const focusEpoch = this.focusEpoch
    const abortController = new AbortController()
    this.abortController = abortController
    this.pendingQuery = query
    this.resultsTarget.setAttribute("aria-busy", "true")
    this.setStatus(this.searchingValue)
    const url = new URL(this.searchFormTarget.action)
    url.search = new URLSearchParams(new FormData(this.searchFormTarget)).toString()

    try {
      const response = await fetch(url, {
        credentials: "same-origin", redirect: "error",
        headers: { Accept: "text/html" }, signal: abortController.signal
      })
      if (!this.current(serial, query)) return
      if (response.status !== 200 || response.redirected ||
          !response.headers.get("Content-Type")?.toLowerCase().includes("text/html")) throw new Error("Search failed")
      const responseUrl = new URL(response.url)
      if (responseUrl.origin !== url.origin || responseUrl.pathname !== url.pathname) throw new Error("Unexpected response")

      const documentResult = new DOMParser().parseFromString(await response.text(), "text/html")
      if (!this.current(serial, query)) return
      const result = documentResult.querySelector("#oshi-search-results")
      if (!result || result.dataset.oshiSearchQuery !== query) throw new Error("Unexpected search query")
      const count = Number(result.dataset.oshiSearchCount)
      const state = result.dataset.oshiSearchState
      const actualCount = result.querySelectorAll("input[type='radio'][name='oshi_id']").length
      if (!Number.isInteger(count) || count < 0 || count !== actualCount ||
          !((state === "empty" && count === 0) || (state === "results" && count > 0))) {
        throw new Error("Invalid search result")
      }

      this.pendingQuery = null
      this.resultsTarget.replaceChildren(...Array.from(result.childNodes, node => document.importNode(node, true)))
      this.resultsTarget.dataset.oshiSearchQuery = query
      this.resultsTarget.dataset.oshiSearchCount = String(count)
      this.resultsTarget.dataset.oshiSearchState = state
      this.existingQueryTarget.value = query
      this.existingFieldsTarget.hidden = count === 0

      if (count > 0) {
        const clearName = !this.nameEdited && this.autoName !== null && this.nameTarget.value === this.autoName
        if (clearName) {
          this.nameTarget.value = ""
          this.autoName = null
        }
        this.setStatus(clearName ? this.clearedValue : "")
        return
      }

      const canCopy = !this.nameEdited && (this.nameTarget.value === "" || this.nameTarget.value === this.autoName)
      if (canCopy) {
        this.nameTarget.value = query
        this.autoName = query
      }
      this.setStatus(canCopy ? this.copiedValue : this.keptValue)
      if (this.focusEpoch === focusEpoch && this.searchFormTarget.contains(document.activeElement) &&
          document.hasFocus() && document.visibilityState === "visible") this.moveTo("registration")
    } catch (error) {
      if (error.name !== "AbortError" && this.current(serial, query)) this.setStatus(this.failedValue)
    } finally {
      if (this.serial === serial) {
        this.abortController = null
        this.pendingQuery = null
        this.resultsTarget.removeAttribute("aria-busy")
      }
    }
  }

  returnToSearch(event) {
    event.preventDefault()
    this.cancelPending()
    this.setStatus("")
    this.moveTo("existing")
  }

  openRegistration(event) {
    event.preventDefault()
    this.cancelPending()
    this.setStatus("")
    this.moveTo("registration")
  }

  moveTo(stage) {
    this.setCurrent(stage)
    const panel = stage === "registration" ? this.registrationPanelTarget : this.existingPanelTarget
    const input = stage === "registration" ? this.nameTarget : this.queryTarget
    input.focus({ preventScroll: true })
    panel.scrollIntoView({
      block: "start", behavior: window.matchMedia("(prefers-reduced-motion: reduce)").matches ? "auto" : "smooth"
    })
  }

  setCurrent(stage) {
    for (const [name, link] of [["existing", this.existingLinkTarget], ["registration", this.registrationLinkTarget]]) {
      const current = name === stage
      if (current) link.setAttribute("aria-current", "step")
      else link.removeAttribute("aria-current")
      link.classList.toggle("button-secondary", !current)
    }
  }

  setStatus(message) {
    this.statusTarget.textContent = message
  }
}
