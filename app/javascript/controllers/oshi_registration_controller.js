import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "searchForm", "query", "searchButton", "results", "existingFields", "existingQuery",
    "existingPanel", "registrationPanel", "name", "status", "existingLink", "registrationLink", "catalogSnapshot", "suggestions", "suggestionHelp"
  ]
  static values = { searching: String, failed: String, copied: String, kept: String, cleared: String, help: String, contextToken: String, catalogReady: String, catalogEmpty: String, catalogAdded: String, suggestLabels: Object }

  connect() {
    this.serial = (this.serial ?? -1) + 1
    this.focusEpoch = 0
    this.leaving = false
    this.composing = false
    this.compositionJustEnded = false
    this.nameEdited = this.nameTarget.value !== ""
    this.autoName = null
    this.configureSuggestions()
    this.observeCatalogRegistrations()
    this.setCurrent(this.registrationPanelTarget.contains(document.activeElement) ? "registration" : "existing")
  }

  disconnect() {
    this.catalogObserver?.disconnect()
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
    if (this.composing || event.isComposing || event.keyCode === 229) return
    if (event.key === "Enter" && event.repeat) {
      event.preventDefault()
      return
    }
    const open = !this.suggestionsTarget.hidden
    if (event.key === "Escape" && (open || this.pendingSuggestions || this.suggestionTimer)) {
      event.preventDefault()
      event.stopPropagation()
      this.cancelPending()
      this.setStatus(this.suggestLabelsValue.closed)
      return
    }
    if (event.key === "Tab") {
      if (open || this.pendingSuggestions || this.suggestionTimer) {
        this.cancelPending()
        this.setStatus(this.suggestLabelsValue.closed)
      }
      return
    }
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      if (!this.queryTarget.value.trim()) return
      event.preventDefault()
      const direction = event.key === "ArrowDown" ? 1 : -1
      if (open) this.moveSuggestion(direction)
      else this.search({ suggestions: true, direction })
      return
    }
    if (event.key !== "Enter" || this.compositionJustEnded) return
    event.preventDefault()
    if (open && this.activeSuggestion >= 0) this.chooseSuggestion()
    else this.search()
  }

  compositionStart() {
    this.composing = true
    this.cancelPending()
  }

  compositionEnd() {
    this.composing = false
    this.compositionJustEnded = true
    this.queryChanged()
  }

  compositionKeyup() {
    if (!this.composing) this.compositionJustEnded = false
  }

  queryChanged() {
    this.cancelPending()
    this.setStatus("")
    if (this.composing) {
      this.resultsTarget.hidden = true
      this.existingFieldsTarget.hidden = true
      return
    }
    if (this.queryTarget.value.trim() === "") {
      this.restoreCatalog(this.queryTarget.value)
      return
    }
    this.resultsTarget.hidden = true
    this.existingFieldsTarget.hidden = true
    this.scheduleSuggestions()
  }

  nameChanged() {
    this.nameEdited = true
    if (this.hasContextTokenValue && this.contextTokenValue && this.pendingQuery != null) {
      this.cancelPending()
      this.setStatus("")
    }
  }

  trackFocus(event) {
    if (!this.searchFormTarget.contains(event.target)) this.otherIntent()
    if (this.registrationPanelTarget.contains(event.target)) this.setCurrent("registration")
    else if (this.existingPanelTarget.contains(event.target)) this.setCurrent("existing")
  }

  trackPointer(event) {
    if (!this.searchFormTarget.contains(event.target)) this.otherIntent()
  }

  trackScrollIntent(event) {
    this.focusEpoch += 1
    if (this.hasSuggestionsTarget && this.suggestionsTarget.contains(event.target)) return
    if (this.pendingSuggestions || this.suggestionTimer || !this.suggestionsTarget.hidden) {
      this.cancelPending()
      this.setStatus("")
    }
  }

  otherIntent() {
    this.focusEpoch += 1
    if (this.pendingQuery !== null && this.pendingQuery !== undefined) {
      this.cancelPending()
      this.setStatus("")
    }
    this.closeSuggestions()
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
    clearTimeout(this.suggestionTimer)
    this.suggestionTimer = null
    this.abortController?.abort()
    this.abortController = null
    this.pendingQuery = null
    if (this.pendingSuggestions && this.hasResultsTarget) this.resultsTarget.dataset.oshiSearchState = "paused"
    this.pendingSuggestions = false
    this.pendingDirection = 0
    this.closeSuggestions()
    if (this.hasResultsTarget) this.resultsTarget.removeAttribute("aria-busy")
    if (this.hasQueryTarget) this.queryTarget.removeAttribute("aria-busy")
  }

  current(serial, query) {
    return !this.leaving && this.element.isConnected && this.serial === serial &&
      this.queryTarget.value === query
  }

  configureSuggestions() {
    this.pendingSuggestions = false
    this.pendingDirection = 0
    this.suggestionHelpTarget.hidden = false
    this.queryTarget.setAttribute("role", "combobox")
    this.queryTarget.setAttribute("aria-autocomplete", "list")
    this.queryTarget.setAttribute("aria-controls", this.suggestionsTarget.id)
    this.queryTarget.setAttribute("aria-describedby", "oshi-suggestion-help oshi-search-status")
    this.closeSuggestions()
    if (this.resultsTarget.dataset.oshiSearchMode === "suggestions" && ["loading", "paused"].includes(this.resultsTarget.dataset.oshiSearchState)) {
      this.resultsTarget.dataset.oshiSearchState = "paused"
      this.setStatus(this.suggestLabelsValue.closed)
    }
  }

  closeSuggestions() {
    this.activeSuggestion = -1
    this.suggestionQuery = null
    if (this.hasSuggestionsTarget) {
      this.suggestionsTarget.hidden = true
      this.suggestionsTarget.replaceChildren()
    }
    if (this.hasQueryTarget) {
      this.queryTarget.setAttribute("aria-expanded", "false")
      this.queryTarget.removeAttribute("aria-activedescendant")
    }
  }

  pageShown(event) {
    if (!event.persisted) return
    this.leaving = false
    this.cancelPending()
    this.setStatus(this.suggestLabelsValue.closed)
  }

  scheduleSuggestions() {
    const query = this.queryTarget.value
    if (this.composing || this.leaving || query.trim() === "") return
    const serial = this.serial
    this.pendingQuery = query
    this.pendingSuggestions = true
    this.suggestionTimer = setTimeout(() => {
      this.suggestionTimer = null
      if (!this.current(serial, query) || this.composing) return
      this.pendingQuery = null
      this.search({ suggestions: true })
    }, 300)
  }

  positionSuggestions() {
    if (!this.hasSuggestionsTarget || this.suggestionsTarget.hidden) return
    const bounds = this.searchFormTarget.getBoundingClientRect()
    const below = innerHeight - bounds.bottom - 12
    const above = bounds.top - 12
    const opensAbove = below < 160 && above > below
    this.suggestionsTarget.dataset.placement = opensAbove ? "above" : "below"
    this.suggestionsTarget.style.maxHeight = String(Math.max(80, Math.min(320, opensAbove ? above : below))) + "px"
  }

  moveSuggestion(direction) {
    const options = [...this.suggestionsTarget.children]
    if (!options.length) return
    const next = this.activeSuggestion < 0 ? (direction > 0 ? 0 : options.length - 1) :
      (this.activeSuggestion + direction + options.length) % options.length
    this.activeSuggestion = next
    options.forEach((option, index) => { option.dataset.active = String(index === next) })
    const option = options[next]
    this.queryTarget.setAttribute("aria-activedescendant", option.id)
    const optionBounds = option.getBoundingClientRect()
    const listBounds = this.suggestionsTarget.getBoundingClientRect()
    if (optionBounds.top < listBounds.top) this.suggestionsTarget.scrollTop += optionBounds.top - listBounds.top
    else if (optionBounds.bottom > listBounds.bottom) this.suggestionsTarget.scrollTop += optionBounds.bottom - listBounds.bottom
  }

  keepQueryFocus(event) {
    event.preventDefault()
  }

  chooseSuggestion(event) {
    event?.preventDefault()
    const option = event?.currentTarget?.closest("[role='option']") || this.suggestionsTarget.children[this.activeSuggestion]
    if (!option || this.suggestionsTarget.hidden || this.suggestionQuery !== this.queryTarget.value) return
    const input = [...this.resultsTarget.querySelectorAll("input[name='oshi_id']")].find(radio => radio.value === option.dataset.oshiId)
    if (!input || !input.dataset.suggestionName) return
    this.syncSuggestionAdded()
    this.cancelPending()
    input.checked = true
    this.queryTarget.value = input.dataset.suggestionName
    this.existingQueryTarget.value = input.dataset.suggestionName
    this.resultsTarget.hidden = false
    this.resultsTarget.dataset.oshiSearchMode = "selection"
    this.resultsTarget.dataset.oshiSearchState = "selected"
    this.resultsTarget.dataset.oshiSearchQuery = input.dataset.suggestionName
    this.existingFieldsTarget.hidden = false
    this.queryTarget.focus({ preventScroll: true })
    input.dispatchEvent(new Event("change", { bubbles: true }))
    this.setStatus(input.dataset.suggestionMessage)
  }

  validateSuggestions(result, count) {
    const options = [...result.querySelectorAll("[data-oshi-suggestion-options] > [role='option']")]
    const radios = [...result.querySelectorAll("[data-oshi-suggestion-radios] input[type='radio'][name='oshi_id']")]
    const ids = radios.map(input => input.value)
    if (result.dataset.oshiSearchMode !== "suggestions" || count > 8 || options.length !== count ||
        new Set(ids).size !== count || ids.some(id => !/^[1-9][0-9]*$/.test(id)) ||
        options.some((option, index) => option.dataset.oshiId !== ids[index] || option.id !== "oshi-suggestion-" + ids[index]) ||
        result.querySelector("form,script,[data-controller]") || result.querySelectorAll("input").length !== count ||
        options.some(option => option.querySelector("input,button,a,select,textarea"))) throw new Error("Invalid suggestions")
  }

  applySuggestions(result, query, count) {
    const radios = result.querySelector("[data-oshi-suggestion-radios]")
    const options = result.querySelector("[data-oshi-suggestion-options]")
    if (!radios || !options) throw new Error("Missing suggestions")
    this.resultsTarget.replaceChildren(...Array.from(radios.children, node => document.importNode(node, true)))
    this.resultsTarget.dataset.oshiSearchMode = "suggestions"
    this.resultsTarget.dataset.oshiSearchState = count ? "results" : "empty"
    this.resultsTarget.dataset.oshiSearchQuery = query
    this.resultsTarget.dataset.oshiSearchCount = String(count)
    this.resultsTarget.hidden = true
    this.existingFieldsTarget.hidden = true
    this.existingQueryTarget.value = query
    this.suggestionsTarget.replaceChildren(...Array.from(options.children, node => document.importNode(node, true)))
    this.suggestionQuery = query
    this.activeSuggestion = -1
    this.syncSuggestionAdded()
    this.suggestionsTarget.hidden = count === 0
    this.queryTarget.setAttribute("aria-expanded", String(count > 0))
    this.positionSuggestions()
    this.setStatus(count ? this.suggestLabelsValue.count.replace("%{count}", String(count)) : this.suggestLabelsValue.empty)
    if (count && this.pendingDirection) this.moveSuggestion(this.pendingDirection)
  }

  syncSuggestionAdded() {
    if (!this.activityChoices) return
    const owned = new Set([...this.activityChoices.querySelectorAll("input[name='activity[oshi_ids][]']")].map(input => input.value))
    for (const input of this.resultsTarget.querySelectorAll("input[data-suggestion-name]")) {
      if (!owned.has(input.value) || input.dataset.suggestionMessage === input.dataset.suggestionAddedMessage) continue
      input.dataset.suggestionMessage = input.dataset.suggestionAddedMessage
      const option = [...this.suggestionsTarget.children].find(item => item.dataset.oshiId === input.value)
      const label = option?.querySelector("[data-suggestion-added]")
      if (label) label.textContent = this.catalogAddedValue
      if (input.checked && !this.resultsTarget.hidden && !this.existingFieldsTarget.hidden) {
        input.dispatchEvent(new Event("change", { bubbles: true }))
        this.setStatus(input.dataset.suggestionMessage)
      }
    }
  }

  observeCatalogRegistrations() {
    this.catalogObserver?.disconnect()
    this.activityChoices = this.element.closest("[data-controller~='activity-oshi-panel']")?.querySelector("[data-activity-oshi-panel-target~='choices']")
    if (!this.activityChoices) return
    this.catalogObserver = new MutationObserver(() => {
      this.syncCatalogAdded()
      this.syncSuggestionAdded()
    })
    this.catalogObserver.observe(this.activityChoices, { childList: true })
    this.syncCatalogAdded()
    this.syncSuggestionAdded()
  }

  syncCatalogAdded() {
    if (!this.activityChoices) return
    const owned = new Set([...this.activityChoices.querySelectorAll("input[name='activity[oshi_ids][]']")].map(input => input.value))
    for (const card of this.resultsTarget.querySelectorAll(".oshi-catalog-card")) {
      const input = card.querySelector("input[name='oshi_id']")
      if (!owned.has(input.value) || input.dataset.catalogMessage === input.dataset.catalogAddedMessage) continue
      card.querySelector(".oshi-catalog-registration").textContent = this.catalogAddedValue
      input.dataset.catalogMessage = input.dataset.catalogAddedMessage
      if (input.checked) input.dispatchEvent(new Event("change", { bubbles: true }))
    }
  }

  catalogChanged(event) {
    const input = event.target
    if (input.name !== "oshi_id" || !input.checked || !input.dataset.catalogMessage) return
    this.otherIntent()
    const card = input.closest(".oshi-catalog-card")
    const track = card.closest(".oshi-catalog-track")
    track.scrollTo({ left: track.scrollLeft + card.getBoundingClientRect().left - track.getBoundingClientRect().left, behavior: "auto" })
    this.setStatus(input.dataset.catalogMessage)
  }

  async restoreCatalog(query) {
    const serial = this.serial
    this.pendingQuery = query
    this.resultsTarget.setAttribute("aria-busy", "true")
    try {
      const fragment = document.createElement("template")
      fragment.innerHTML = JSON.parse(this.catalogSnapshotTarget.textContent)
      const catalog = fragment.content.querySelector("[data-oshi-catalog-count]")
      const count = Number(catalog?.dataset.oshiCatalogCount)
      if (!catalog || !Number.isInteger(count) || count < 0 || count > 12 ||
          catalog.querySelectorAll("input[type='radio'][name='oshi_id']").length !== count) throw new Error("Invalid catalog")

      if (this.hasContextTokenValue && this.contextTokenValue) {
        const verification = this.dispatch("verify-context", { detail: { promise: null } }).detail.promise
        if (!verification || typeof verification.then !== "function") throw new Error("Missing continuity check")
        await verification
        if (!this.current(serial, query)) return
      }

      if (!this.current(serial, query)) return
      this.resultsTarget.replaceChildren(fragment.content)
      this.resultsTarget.hidden = false
      this.resultsTarget.dataset.oshiSearchMode = "catalog"
      this.syncCatalogAdded()
      this.resultsTarget.dataset.oshiSearchQuery = query
      this.resultsTarget.dataset.oshiSearchCount = String(count)
      this.resultsTarget.dataset.oshiSearchState = "initial"
      this.existingQueryTarget.value = ""
      this.existingFieldsTarget.hidden = count === 0
      this.setStatus(count ? this.catalogReadyValue : this.catalogEmptyValue)
    } catch (error) {
      if (error.name !== "AbortError" && !error.contextRejected && this.current(serial, query)) {
        this.setStatus(this.failedValue)
        if (this.hasContextTokenValue && this.contextTokenValue) this.dispatch("failed")
      }
    } finally {
      if (this.serial === serial) {
        this.pendingQuery = null
        this.resultsTarget.removeAttribute("aria-busy")
      }
    }
  }

  async search({ suggestions = false, direction = 0 } = {}) {
    const query = this.queryTarget.value
    if (this.composing || this.leaving) return
    if (this.pendingQuery === query && this.abortController && this.pendingSuggestions === suggestions) {
      if (direction) this.pendingDirection = direction
      return
    }
    this.cancelPending()

    if (query.trim() === "") {
      await this.restoreCatalog(query)
      return
    }

    const serial = this.serial
    const focusEpoch = this.focusEpoch
    const abortController = new AbortController()
    this.abortController = abortController
    this.pendingQuery = query
    this.pendingSuggestions = suggestions
    this.pendingDirection = direction
    this.resultsTarget.setAttribute("aria-busy", "true")
    this.queryTarget.setAttribute("aria-busy", "true")
    if (suggestions) {
      this.resultsTarget.hidden = true
      this.existingFieldsTarget.hidden = true
      this.resultsTarget.dataset.oshiSearchMode = "suggestions"
      this.resultsTarget.dataset.oshiSearchState = "loading"
    }
    this.setStatus(suggestions ? this.suggestLabelsValue.loading : this.searchingValue)
    const url = new URL(this.searchFormTarget.action)
    url.search = new URLSearchParams(new FormData(this.searchFormTarget)).toString()
    if (suggestions) url.searchParams.set("suggest", "1")

    try {
      const headers = { Accept: "text/html" }
      if (this.hasContextTokenValue && this.contextTokenValue) headers["X-Activity-Context-Token"] = this.contextTokenValue
      const response = await fetch(url, {
        cache: suggestions || (this.hasContextTokenValue && this.contextTokenValue) ? "no-store" : "default",
        credentials: "same-origin", redirect: "error",
        headers, signal: abortController.signal
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
      if (suggestions) this.validateSuggestions(result, count)

      if (this.hasContextTokenValue && this.contextTokenValue) {
        const verification = this.dispatch("verify-context", { detail: { promise: null } }).detail.promise
        if (!verification || typeof verification.then !== "function") throw new Error("Missing continuity check")
        await verification
        if (!this.current(serial, query)) return
      }

      this.pendingQuery = null
      if (suggestions) {
        this.applySuggestions(result, query, count)
        return
      }
      this.resultsTarget.hidden = false
      this.resultsTarget.dataset.oshiSearchMode = "explicit"
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
      if (suggestions && this.current(serial, query) && (error.contextRejected || error.name === "AbortError")) {
        this.resultsTarget.dataset.oshiSearchState = "paused"
        this.setStatus("")
      }
      if (error.name !== "AbortError" && !error.contextRejected && this.current(serial, query)) {
        if (suggestions) this.resultsTarget.dataset.oshiSearchState = "error"
        this.setStatus(suggestions ? this.suggestLabelsValue.failed : this.failedValue)
        if (this.hasContextTokenValue && this.contextTokenValue) this.dispatch("failed")
      }
    } finally {
      if (this.serial === serial) {
        this.abortController = null
        this.pendingQuery = null
        this.pendingSuggestions = false
        this.pendingDirection = 0
        this.resultsTarget.removeAttribute("aria-busy")
        this.queryTarget.removeAttribute("aria-busy")
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
