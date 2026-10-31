import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["activityForm", "context", "choices", "status", "errors", "openButton", "panel", "registration", "registeredResults", "unknownActions", "restart"]
  static values = { registrationUrl: String, ownedUrl: String, labels: Object }

  connect() {
    this.epoch = (this.epoch ?? 0) + 1
    this.requests = new Set()
    this.edits = new Map()
    this.selectionEpoch = (this.selectionEpoch || 0) + 1
    this.owned = new Map()
    this.successes = new Map(JSON.parse(this.element.dataset.panelSuccesses || "[]"))
    this.uncertain = new Set(JSON.parse(this.element.dataset.panelUncertain || "[]"))
    this.unknown = this.element.dataset.panelPending === "true"
    this.posting = this.blocked = this.activityChecking = this.activitySaving = false
    this.activityHandler = event => this.guardActivity(event)
    this.activityFormTarget.addEventListener("submit", this.activityHandler, true)
    this.originalSubmit = this.activityFormTarget.submit
    this.directSubmit = () => this.activityFormTarget.requestSubmit()
    this.activityFormTarget.submit = this.directSubmit
    if (this.hasOpenButtonTarget) this.openButtonTarget.hidden = false
    this.showUnknownActions()
    if (this.unknown) this.message("unknown", true)
  }

  disconnect() {
    this.leave()
    this.activityFormTarget.removeEventListener("submit", this.activityHandler, true)
    if (this.activityFormTarget.submit === this.directSubmit) this.activityFormTarget.submit = this.originalSubmit
  }

  beforeCache() {
    this.leave()
  }

  leave() {
    if (this.posting && this.registrationSent) this.markUnknown()
    else this.posting = false
    this.activityChecking = false
    this.opening = false
    this.epoch += 1
    this.requests?.forEach(controller => controller.abort())
    this.requests?.clear()
    this.setPanelBusy(false)
  }

  current(epoch) {
    return epoch === this.epoch && this.element.isConnected
  }

  headers(accept = "application/json") {
    return { Accept: accept, "X-Activity-Panel": "1", "X-Activity-Context-Token": this.contextTarget.value }
  }

  async request(url, options = {}, epoch = this.epoch, html = false) {
    const target = new URL(url, location.href)
    if (target.origin !== location.origin) throw new Error("Unexpected origin")
    const controller = new AbortController()
    this.requests.add(controller)
    const timer = setTimeout(() => controller.abort(), 15000)
    try {
      const response = await fetch(target, { ...options, cache: "no-store", credentials: "same-origin", redirect: "error",
        headers: { ...this.headers(html ? "text/html" : "application/json"), ...(options.headers || {}) }, signal: controller.signal })
      if (!this.current(epoch)) throw new Error("Stale response")
      const actual = new URL(response.url)
      if (actual.origin !== target.origin || actual.pathname !== target.pathname || response.redirected) throw new Error("Unexpected response")
      if ([401, 403, 409].includes(response.status)) {
        this.blocked = true
        if (this.hasRestartTarget) this.restartTarget.hidden = false
        this.message("context_error", true)
        const error = new Error("Context rejected")
        error.contextRejected = true
        throw error
      }
      if (html) {
        if (response.status !== 200 || !response.headers.get("Content-Type")?.includes("text/html")) throw new Error("Invalid panel")
        return await response.text()
      }
      if (!response.headers.get("Content-Type")?.includes("application/json")) throw new Error("Invalid response type")
      const body = await response.json()
      if (!this.current(epoch)) throw new Error("Stale response")
      return { status: response.status, body }
    } finally {
      clearTimeout(timer)
      this.requests.delete(controller)
    }
  }

  async readOwned(epoch = this.epoch) {
    const { status, body } = await this.request(this.ownedUrlValue, {}, epoch)
    if (status !== 200 || !Array.isArray(body.oshis)) throw new Error("Invalid owned list")
    const owned = new Map()
    for (const item of body.oshis) {
      const oshi = item.oshi
      if (!oshi || !Number.isSafeInteger(oshi.id) || oshi.id <= 0 || typeof oshi.name !== "string") throw new Error("Invalid owned item")
      owned.set(String(oshi.id), item)
    }
    this.owned = owned
    return owned
  }

  async open(event) {
    event?.preventDefault()
    if (this.blocked || !this.hasPanelTarget || this.opening) return
    this.opening = true
    const epoch = this.epoch
    const focus = document.activeElement
    const intent = this.selectionEpoch
    this.panelTarget.hidden = false
    this.openButtonTarget.setAttribute("aria-expanded", "true")
    this.message(this.unknown ? "unknown" : "loading", this.unknown)
    try {
      await this.readOwned(epoch)
      if (!this.registrationTarget.childElementCount) {
        const html = await this.request(this.registrationUrlValue, {}, epoch, true)
        await this.readOwned(epoch)
        if (!this.current(epoch) || this.blocked || this.panelTarget.hidden) return
        if (this.selectionEpoch !== intent) return this.message("")
        const fragment = new DOMParser().parseFromString(html, "text/html").querySelector("[data-controller~='oshi-registration']")
        if (!fragment) throw new Error("Missing registration component")
        this.registrationTarget.replaceChildren(document.importNode(fragment, true))
      }
      if (!this.unknown && !this.posting) this.message("")
      if (document.activeElement === focus && !this.panelTarget.hidden) this.registrationTarget.querySelector("input[type='search']")?.focus({ preventScroll: true })
    } catch (error) {
      if (this.current(epoch) && !error.contextRejected) this.message("failed", true)
    } finally {
      if (this.current(epoch)) this.opening = false
    }
  }

  close(event) {
    event?.preventDefault()
    if (!this.hasPanelTarget) return
    if (this.posting && this.registrationSent) this.markUnknown()
    else this.posting = false
    this.activityChecking = false
    this.opening = false
    this.epoch += 1
    this.requests.forEach(controller => controller.abort())
    this.requests.clear()
    const component = this.registrationTarget.querySelector("[data-controller~='oshi-registration']")
    if (component) window.Stimulus.getControllerForElementAndIdentifier(component, "oshi-registration")?.cancelPending()
    this.setPanelBusy(false)
    this.panelTarget.hidden = true
    this.openButtonTarget.setAttribute("aria-expanded", "false")
    this.openButtonTarget.focus({ preventScroll: true })
  }

  keydown(event) {
    if (event.key !== "Escape" || event.isComposing || event.keyCode === 229 || !this.hasPanelTarget ||
        this.panelTarget.hidden || !this.panelTarget.contains(event.target)) return
    event.preventDefault()
    this.close()
  }

  trackFocus(event) {
    if (this.activityFormTarget.contains(event.target)) this.focusEpoch = (this.focusEpoch || 0) + 1
  }

  selectionChanged(event) {
    this.selectionEpoch = (this.selectionEpoch || 0) + 1
    const input = event.target
    if (this.activityFormTarget.contains(input) && input.matches("input[type='checkbox'][name='activity[oshi_ids][]']")) {
      this.edits.set(input.value, (this.edits.get(input.value) || 0) + 1)
    }
    if (this.hasRegistrationTarget && this.registrationTarget.contains(input) && input.name === "oshi_id") {
      const registered = this.owned.has(input.value)
      const period = input.form.querySelector("[data-activity-panel-period]")
      if (period) period.hidden = registered
      const button = input.form.querySelector("input[type='submit']")
      if (button) button.value = this.labelsValue[registered ? "select" : "register_select"]
    }
  }

  async submitRegistration(event) {
    event.preventDefault()
    event.stopPropagation()
    if (this.blocked || this.posting || this.activityChecking || this.activitySaving) return
    if (this.unknown) return this.message("unknown", true)
    const form = event.target
    if (!this.registrationTarget.contains(form)) return
    const data = new FormData(form)
    const isNew = Boolean(form.querySelector("input[name='oshi[name]']"))
    const id = String(data.get("oshi_id") || "")
    if (!isNew && !/^[1-9][0-9]*$/.test(id)) return this.message("validation", true)
    const details = isNew ? [data.get("oshi[name]"), data.get("oshi[oshi_type]"), data.get("oshi[affiliation]") || ""] : [id]
    const signature = JSON.stringify([isNew ? "new" : "existing", ...details])
    const editEpoch = this.edits.get(id) || 0
    const focusEpoch = this.focusEpoch || 0
    const epoch = ++this.epoch
    let sent = false
    this.registrationSent = false
    this.opening = false
    this.posting = true
    this.setPanelBusy(true)
    this.message("posting")
    this.errorsTarget.replaceChildren()
    this.errorsTarget.hidden = true
    try {
      await this.readOwned(epoch)
      const knownId = isNew ? this.successes.get(signature) : id
      if (knownId && this.owned.has(String(knownId))) {
        this.applyChoice(this.owned.get(String(knownId)), editEpoch, "selected")
        return
      }
      if (this.uncertain.has(signature)) {
        this.markUnknown(signature)
        return
      }
      data.set("activity_panel", "1")
      data.set("activity_context_token", this.contextTarget.value)
      this.element.dataset.panelPending = "true"
      this.element.dataset.panelSignature = signature
      sent = true
      this.registrationSent = true
      const { status, body } = await this.request(form.action, { method: "POST", body: data }, epoch)
      if ([404, 422].includes(status)) {
        this.clearPending()
        if (status === 422) this.showErrors(body.errors, focusEpoch)
        else this.message("unavailable", true)
        return
      }
      if (![200, 201].includes(status) || !body.oshi || !Number.isSafeInteger(body.oshi.id)) throw new Error("Unconfirmed registration")
      if (!isNew && String(body.oshi.id) !== id) throw new Error("Wrong candidate")
      if (isNew && JSON.stringify([body.oshi.name, body.oshi.oshi_type, body.oshi.affiliation || ""]) !== JSON.stringify(details)) throw new Error("Wrong new candidate")
      await this.readOwned(epoch)
      const item = this.owned.get(String(body.oshi.id))
      if (!item) throw new Error("Registration not confirmed")
      this.clearPending()
      this.successes.set(signature, String(body.oshi.id))
      this.element.dataset.panelSuccesses = JSON.stringify([...this.successes])
      this.applyChoice(item, isNew ? 0 : editEpoch, body.result === "already_registered" ? "selected" : "registered")
    } catch (error) {
      if (!this.current(epoch)) return
      if (error.contextRejected) this.clearPending()
      else if (sent) this.markUnknown(signature)
      else this.message("failed", true)
    } finally {
      if (this.current(epoch)) {
        this.posting = false
        this.setPanelBusy(false)
      }
    }
  }

  applyChoice(item, editEpoch, message) {
    const oshi = item.oshi
    const id = String(oshi.id)
    let input = [...this.choicesTarget.querySelectorAll("input[type='checkbox']")].find(candidate => candidate.value === id)
    if (!input) {
      const label = document.createElement("label")
      label.className = "choice-chip"
      input = document.createElement("input")
      input.type = "checkbox"
      input.name = "activity[oshi_ids][]"
      input.id = "activity_oshi_ids_" + id
      input.value = id
      label.htmlFor = input.id
      const text = document.createElement("span")
      text.textContent = oshi.name
      label.append(input, text)
      this.choicesTarget.append(label)
    }
    if ((this.edits.get(id) || 0) === editEpoch) {
      input.checked = true
      this.message(message)
    } else this.message("kept")
  }

  async confirm(event) {
    event?.preventDefault()
    if (this.blocked || !this.hasPanelTarget) return
    this.panelTarget.hidden = false
    this.openButtonTarget.setAttribute("aria-expanded", "true")
    const epoch = this.epoch
    try {
      await this.readOwned(epoch)
      this.registeredResultsTarget.replaceChildren()
      const description = document.createElement("p")
      description.textContent = this.labelsValue[this.owned.size ? "review_help" : "no_registered"]
      this.registeredResultsTarget.append(description)
      for (const item of this.owned.values()) {
        const row = document.createElement("p")
        const text = document.createElement("span")
        text.textContent = item.oshi.name + "／" + item.oshi.oshi_type + "／" + (item.oshi.affiliation || "") + " "
        const button = document.createElement("button")
        button.type = "button"
        button.textContent = this.labelsValue.select
        button.addEventListener("click", async () => {
          const selectionEpoch = this.edits.get(String(item.oshi.id)) || 0
          try {
            await this.readOwned(epoch)
            if (!this.owned.has(String(item.oshi.id))) return this.message("unavailable", true)
            this.clearPending()
            this.applyChoice(this.owned.get(String(item.oshi.id)), selectionEpoch, "selected")
          } catch (error) {
            if (this.current(epoch) && !error.contextRejected) this.message("failed", true)
          }
        })
        row.append(text, button)
        this.registeredResultsTarget.append(row)
      }
    } catch (error) {
      if (this.current(epoch) && !error.contextRejected) this.message("failed", true)
    }
  }

  continueWithout(event) {
    event?.preventDefault()
    if (this.blocked) return
    this.epoch += 1
    this.activityChecking = false
    this.opening = false
    this.requests.forEach(controller => controller.abort())
    this.requests.clear()
    this.posting = false
    this.clearPending()
    this.setPanelBusy(false)
    this.message("continued")
  }

  markUnknown(signature = this.element.dataset.panelSignature) {
    this.posting = false
    this.unknown = true
    this.element.dataset.panelPending = "true"
    if (signature) this.uncertain.add(signature)
    this.element.dataset.panelUncertain = JSON.stringify([...this.uncertain])
    this.showUnknownActions()
    this.message("unknown", true)
  }

  clearPending() {
    this.unknown = false
    this.element.dataset.panelPending = "false"
    this.showUnknownActions()
  }

  showUnknownActions() {
    if (this.hasUnknownActionsTarget) this.unknownActionsTarget.hidden = !this.unknown
  }

  setPanelBusy(busy) {
    if (!this.hasRegistrationTarget) return
    if (busy && !this.panelButtons) {
      this.panelButtons = new Map([...this.registrationTarget.querySelectorAll("button[type='submit'],input[type='submit']")].map(button => [button, button.disabled]))
      this.panelButtons.forEach((_disabled, button) => { button.disabled = true })
    } else if (!busy && this.panelButtons) {
      this.panelButtons.forEach((disabled, button) => { if (button.isConnected) button.disabled = disabled })
      this.panelButtons = null
    }
    if (this.hasPanelTarget) this.panelTarget.setAttribute("aria-busy", String(busy))
  }

  async guardActivity(event) {
    if (this.passActivity) {
      this.passActivity = false
      this.activitySaving = true
      return
    }
    if (this.activityFormTarget.getAttribute("aria-busy") === "true" && !this.posting && !this.unknown && !this.blocked) return
    event.preventDefault()
    event.stopImmediatePropagation()
    if (this.blocked) return this.message("context_error", true)
    if (this.posting) return this.message("posting")
    if (this.unknown) return this.message("unknown", true)
    if (this.activityChecking || this.activitySaving) return
    this.activityChecking = true
    const epoch = this.epoch
    const submitter = event.submitter
    this.message("checking")
    try {
      await this.readOwned(epoch)
      if (!this.current(epoch) || this.posting || this.unknown) return
      this.passActivity = true
      this.activityFormTarget.requestSubmit(submitter?.isConnected ? submitter : undefined)
      this.passActivity = false
      if (this.activityFormTarget.getAttribute("aria-busy") === "true") this.activitySaving = false
    } catch (error) {
      this.passActivity = false
      this.activitySaving = false
      if (this.current(epoch) && !error.contextRejected) this.message("failed", true)
    } finally {
      if (this.current(epoch)) this.activityChecking = false
    }
  }

  activityFinished(event) {
    if (event.target === this.activityFormTarget) this.activitySaving = false
  }

  verifySearch(event) {
    const epoch = this.epoch
    const intent = this.selectionEpoch
    event.detail.promise = (async () => {
      if (this.blocked || this.panelTarget.hidden) throw new DOMException("Stopped search", "AbortError")
      await this.readOwned(epoch)
      if (!this.current(epoch) || this.blocked || this.panelTarget.hidden || this.selectionEpoch !== intent) {
        throw new DOMException("Stale search intent", "AbortError")
      }
    })()
  }

  async searchFailed() {
    if (this.blocked || this.posting) return
    const epoch = this.epoch
    try {
      await this.readOwned(epoch)
    } catch (error) {
      if (this.current(epoch) && !error.contextRejected) this.message("failed", true)
    }
  }

  showErrors(errors, focusEpoch) {
    this.errorsTarget.replaceChildren()
    for (const message of Array.isArray(errors) ? errors : []) {
      const item = document.createElement("li")
      item.textContent = message
      this.errorsTarget.append(item)
    }
    this.errorsTarget.hidden = this.errorsTarget.childElementCount === 0
    this.message("validation", true)
    if ((this.focusEpoch || 0) === focusEpoch && !this.errorsTarget.hidden && document.hasFocus()) {
      this.errorsTarget.tabIndex = -1
      this.errorsTarget.focus()
    }
  }

  message(key, error = false) {
    this.statusTarget.textContent = key ? this.labelsValue[key] : ""
    this.statusTarget.setAttribute("role", error ? "alert" : "status")
  }
}
