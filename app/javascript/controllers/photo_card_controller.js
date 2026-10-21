import { Controller } from "@hotwired/stimulus"
import { defaultCrop } from "lib/crop_geometry"
import { DataTemplateState, MemoryTemplateState, PhotoTemplateState } from "lib/card_template_state"
import { createCard, downloadCard, errorMessage } from "lib/card_png_transport"

export default class extends Controller {
  static targets = ["form", "status", "error", "preview", "image", "generateButton", "downloadButton", "oshi", "frames", "frameTemplate", "template", "panel", "settingsForm", "cropDialog", "memoryStatus", "memoryRetry", "memoryMore", "memoryEmpty", "memoryFrames", "memoryFrameTemplate", "memoryAdd", "dataYear", "dataOshi", "dataStatus", "dataRetry"]
  static values = { createUrl: String, downloadUrl: String, layouts: Object, memoriesUrl: String, statisticsUrl: String }

  connect() {
    this.sequence = (this.sequence || 0) + 1
    this.disposed = false
    this.generating = false
    this.lastAction = Date.now()
    this.template = "photo"
    this.settingsFormTargets.forEach(form => {
      form.reset()
      form.querySelectorAll("input, select").forEach(input => { input.disabled = false })
    })
    this.photoState = new PhotoTemplateState(this.oshiTargets)
    this.memoryState = new MemoryTemplateState()
    this.dataState = new DataTemplateState()
    this.dataYearTarget.disabled = true
    this.dataOshiTarget.disabled = true
    this.renderFrames()
    this.renderPanels()
    this.timer = setInterval(() => this.checkExpiry(), 1000)
  }

  disconnect() { this.dispose() }

  switchTemplate(event) {
    if (this.disposed || !this.checkExpiry()) return
    this.lastAction = Date.now()
    this.closeCrop()
    this.template = event.target.value
    this.invalidate()
    this.renderPanels()
    if (this.template === "memories" && !this.memories) this.loadMemories()
    if (this.template === "data" && !this.dataSettings) this.loadStatistics()
    this.errorTarget.textContent = ""
    this.statusTarget.textContent = "テンプレートを切り替えました。プレビューを作成してください。"
  }

  renderPanels() {
    this.panelTargets.forEach(panel => { panel.hidden = panel.dataset.template !== this.template })
  }

  get canGenerate() {
    return !this.disposed && (this.template === "photo" ? this.selectedIds?.length > 0 :
      (this.template === "memories" ? this.memoryIds?.length > 0 : this.template === "data" && Boolean(this.dataSettings)))
  }

  updateGenerateButtons(busy = this.generating) {
    this.generateButtonTargets.forEach(button => {
      button.disabled = busy || !this.canGenerate || button.closest("[data-template]").dataset.template !== this.template
    })
  }

  async loadStatistics() {
    if (this.disposed || !this.checkExpiry() || this.dataLoad || this.dataSettings) return
    this.lastAction = Date.now()
    const operation = new AbortController()
    this.dataLoad = operation
    this.dataRetryTarget.hidden = true
    this.dataStatusTarget.textContent = "年と集計対象を読み込んでいます。"
    try {
      const response = await fetch(this.statisticsUrlValue, { credentials: "same-origin", signal: operation.signal,
        headers: { Accept: "application/json" } })
      if (!response.ok) throw new Error(await errorMessage(response))
      const options = await response.json()
      if (this.disposed || this.dataLoad !== operation || !this.checkExpiry()) return
      this.dataYearTarget.replaceChildren(...options.years.map(year => new Option(`${year}年`, year)))
      this.dataOshiTarget.replaceChildren(new Option("すべての推し", ""), ...options.oshis.map(oshi => new Option(oshi.name, oshi.id)))
      this.dataSettings = { year: options.year, oshi_id: "" }
      this.dataYearTarget.value = options.year
      this.dataOshiTarget.value = ""
      this.dataYearTarget.disabled = false
      this.dataOshiTarget.disabled = false
      this.dataStatusTarget.textContent = options.oshis.length ? "年と集計対象を選択できます。" : "推しの登録がなくても全体のカードを作成できます。"
      this.updateGenerateButtons()
    } catch (error) {
      if (!this.disposed && this.dataLoad === operation && error.name !== "AbortError") {
        this.dataStatusTarget.textContent = `選択肢を取得できません。${error.message}`
        this.dataRetryTarget.hidden = false
      }
    } finally {
      if (this.dataLoad === operation) this.dataLoad = null
    }
  }

  changeStatistics() {
    if (this.disposed || !this.checkExpiry() || this.template !== "data" || !this.dataSettings) return
    this.lastAction = Date.now()
    const next = { year: this.dataYearTarget.value, oshi_id: this.dataOshiTarget.value }
    if (next.year === this.dataSettings.year && next.oshi_id === this.dataSettings.oshi_id) return
    this.dataSettings = next
    this.invalidate()
    this.errorTarget.textContent = ""
    this.statusTarget.textContent = "設定を変更しました。プレビューを作成してください。"
  }

  async loadMemories() {
    if (this.disposed || !this.checkExpiry() || this.memoryLoad || this.memories) return
    this.lastAction = Date.now()
    const operation = new AbortController()
    this.memoryLoad = operation
    this.memoryRetryTarget.hidden = true
    this.memoryStatusTarget.textContent = "活動記録を読み込んでいます。"
    try {
      const response = await fetch(this.memoriesUrlValue, { credentials: "same-origin", signal: operation.signal,
        headers: { Accept: "application/json" } })
      if (!response.ok) throw new Error(await errorMessage(response))
      const { activities, next_cursor: nextCursor, has_more: hasMore } = await response.json()
      if (this.disposed || this.memoryLoad !== operation || !this.checkExpiry()) return
      this.memoryState.load(activities)
      this.memoryCursor = nextCursor
      this.memoryMoreTarget.hidden = !hasMore
      this.memoryStatusTarget.textContent = activities.length ? "最新の活動を選択しました。掲載順と写真を変更できます。" : ""
      this.memoryEmptyTarget.hidden = activities.length > 0
      this.renderMemoryFrames()
    } catch (error) {
      if (!this.disposed && this.memoryLoad === operation && error.name !== "AbortError") {
        this.memoryStatusTarget.textContent = `活動記録を取得できません。${error.message}`
        this.memoryRetryTarget.hidden = false
      }
    } finally {
      if (this.memoryLoad === operation) this.memoryLoad = null
    }
  }

  async loadMoreMemories() {
    if (!this.memoryAction() || this.memoryLoad || !this.memories || !this.memoryCursor) return
    const cursor = this.memoryCursor
    const sequence = this.sequence
    const operation = new AbortController()
    this.memoryLoad = operation
    this.memoryMoreTarget.disabled = true
    this.memoryStatusTarget.textContent = "古い活動記録を読み込んでいます。"
    try {
      const url = new URL(this.memoriesUrlValue, window.location.href)
      url.searchParams.set("cursor", cursor)
      const response = await fetch(url, { credentials: "same-origin", signal: operation.signal,
        headers: { Accept: "application/json" } })
      if (!response.ok) throw new Error(await errorMessage(response))
      const { activities, next_cursor: nextCursor, has_more: hasMore } = await response.json()
      if (!this.current(sequence) || this.template !== "memories" || this.memoryLoad !== operation || this.memoryCursor !== cursor || !this.checkExpiry()) return
      const added = this.memoryState.append(activities)
      this.memoryCursor = nextCursor
      this.memoryMoreTarget.hidden = !hasMore
      this.memoryStatusTarget.textContent = added ? `${added}件の古い活動を追加しました。選択中の内容は維持されています。` : "追加できる活動はありませんでした。"
      this.renderMemoryFrames()
    } catch (error) {
      if (!this.disposed && this.memoryLoad === operation && error.name !== "AbortError") {
        this.memoryStatusTarget.textContent = `古い活動記録を取得できません。${error.message}`
        this.memoryMoreTarget.hidden = false
      }
    } finally {
      if (this.memoryLoad === operation) {
        this.memoryLoad = null
        this.memoryMoreTarget.disabled = false
      }
    }
  }

  initializeMemory(id) { this.memoryState.initialize(id) }

  memoryAction() {
    if (this.disposed || !this.checkExpiry() || this.template !== "memories") return false
    this.lastAction = Date.now()
    return true
  }

  memoryChanged() {
    this.closeCrop()
    this.invalidate()
    this.errorTarget.textContent = ""
    this.statusTarget.textContent = "設定を変更しました。プレビューを作成してください。"
  }

  addMemory() {
    if (!this.memoryAction() || !this.memories || this.memoryIds.length >= 3) return
    const next = this.memories.find(item => !this.memoryIds.includes(item.id))
    if (!next) return
    this.memoryIds.push(next.id)
    this.initializeMemory(next.id)
    this.memoryChanged()
    this.renderMemoryFrames()
    this.memoryFramesTarget.lastElementChild.querySelector("select").focus()
  }

  removeMemory(event) {
    if (!this.memoryAction()) return
    const id = event.currentTarget.dataset.activityId
    this.memoryIds = this.memoryIds.filter(item => item !== id)
    this.memoryEdits.delete(id)
    this.memoryChanged()
    this.renderMemoryFrames()
    this.memoryAddTarget.focus()
  }

  changeMemory(event) {
    if (!this.memoryAction()) return
    const old = event.target.dataset.activityId
    const id = event.target.value
    if (old === id) return
    if (this.memoryIds.includes(id)) { event.target.value = old; return }
    this.memoryIds[this.memoryIds.indexOf(old)] = id
    this.memoryEdits.delete(old)
    this.initializeMemory(id)
    this.memoryChanged()
    this.renderMemoryFrames()
    this.memoryFramesTarget.querySelector(`[data-memory-activity][data-activity-id="${id}"]`).focus()
  }

  moveMemory(event) {
    if (!this.memoryAction()) return
    const id = event.currentTarget.dataset.activityId
    const from = this.memoryIds.indexOf(id)
    const to = from + Number(event.currentTarget.dataset.direction)
    if (from < 0 || to < 0 || to >= this.memoryIds.length) return
    ;[this.memoryIds[from], this.memoryIds[to]] = [this.memoryIds[to], this.memoryIds[from]]
    this.memoryChanged()
    this.renderMemoryFrames()
    this.memoryFramesTarget.querySelector(`[data-memory-activity][data-activity-id="${id}"]`).focus()
  }

  changeMemoryPhoto(event) {
    if (!this.memoryAction()) return
    const edit = this.memoryEdits.get(event.target.dataset.activityId)
    if (edit.imageId === event.target.value) return
    edit.imageId = event.target.value
    edit.crop = defaultCrop()
    this.memoryChanged()
  }

  renderMemoryFrames() {
    const rows = this.memoryIds.map((id, index) => {
      const activity = this.memories.find(item => item.id === id)
      const row = this.memoryFrameTemplateTarget.content.firstElementChild.cloneNode(true)
      row.dataset.activityId = id
      row.querySelector("[data-memory-heading]").textContent = `掲載位置 ${index + 1}（左から）`
      const select = row.querySelector("[data-memory-activity]")
      select.id = `memory-activity-${id}`
      const label = row.querySelector("[data-memory-activity-label]")
      label.htmlFor = select.id
      label.textContent = `${index + 1}. 掲載する活動`
      this.memories.forEach(item => {
        const option = new Option(`${item.date} ${item.title}`, item.id)
        option.disabled = item.id !== id && this.memoryIds.includes(item.id)
        select.add(option)
      })
      select.value = id
      row.querySelector("[data-memory-details]").textContent = `${activity.category} / ${activity.oshis.join("・")}`
      const photos = row.querySelector("[data-memory-photo]")
      photos.id = `memory-photo-${id}`
      const photoLabel = row.querySelector("[data-memory-photo-label]")
      photoLabel.htmlFor = photos.id
      photoLabel.textContent = `${index + 1}. 活動の写真`
      activity.images.forEach((image, n) => photos.add(new Option(`写真${n + 1}`, image.id)))
      if (!activity.images.length) photos.add(new Option("写真なし（代替表示）", ""))
      photos.value = this.memoryEdits.get(id).imageId
      photos.disabled = !activity.images.length
      row.querySelector("[data-memory-crop]").disabled = !activity.images.length
      row.querySelectorAll("button, select").forEach(input => { input.dataset.activityId = id })
      const up = row.querySelector("[data-memory-up]")
      up.dataset.direction = "-1"
      up.disabled = index === 0
      const down = row.querySelector("[data-memory-down]")
      down.dataset.direction = "1"
      down.disabled = index === this.memoryIds.length - 1
      return row
    })
    this.memoryFramesTarget.replaceChildren(...rows)
    this.memoryAddTarget.disabled = this.memoryIds.length >= 3 || this.memoryIds.length >= this.memories.length
    this.updateGenerateButtons()
  }

  editMemoryCrop(event) {
    if (!this.memoryAction()) return
    const id = event.currentTarget.dataset.activityId
    const edit = this.memoryEdits.get(id)
    const activity = this.memories.find(item => item.id === id)
    const image = activity.images.find(item => item.id === edit.imageId)
    if (!image) return
    this.cropDialogTarget.dispatchEvent(new CustomEvent("crop:open", { detail: {
      frameId: `memory-${id}`, sourceId: image.id, src: image.url, opener: event.currentTarget,
      crop: edit.crop, width: 424, height: 400
    } }))
  }

  confirmMemoryCrop(event) {
    if (!this.memoryAction()) return
    const { frameId, sourceId, crop } = event.detail
    const id = frameId.slice(7)
    const edit = this.memoryEdits.get(id)
    if (!this.memoryIds.includes(id) || edit?.imageId !== sourceId) return
    if (["x", "y", "zoom"].every(key => Math.abs(edit.crop[key] - crop[key]) <= 1e-9)) return
    edit.crop = crop
    this.invalidate()
    this.statusTarget.textContent = "画像の調整範囲を変更しました。プレビューを作成してください。"
  }

  cropActivity() {
    if (!this.disposed && this.checkExpiry()) this.lastAction = Date.now()
  }

  closeCrop() {
    this.photoCropVersion += 1
    this.cropDialogTarget.dispatchEvent(new Event("crop:cancel"))
  }

  editCrop(event) {
    if (this.disposed || !this.checkExpiry() || this.template !== "photo") return
    this.lastAction = Date.now()
    const frameId = event.currentTarget.dataset.cropFor
    const attachmentId = this.imageSources.get(frameId)
    const source = this.photoImage(attachmentId)
    if (!source) return
    const sourceId = `${attachmentId}:${++this.photoCropVersion}`
    this.cropDialogTarget.dispatchEvent(new CustomEvent("crop:open", { detail: {
      frameId, sourceId, src: source.url, opener: event.currentTarget,
      crop: this.crops.get(frameId) || defaultCrop(), ...this.layoutsValue[this.selectedIds.length]
    } }))
  }

  confirmCrop(event) {
    if (event.detail.frameId.startsWith("memory-")) {
      this.confirmMemoryCrop(event)
      return
    }
    if (this.disposed || !this.checkExpiry() || this.template !== "photo") return
    const { frameId, sourceId, crop } = event.detail
    if (!this.cropDialogTarget.open || !this.selectedIds.includes(frameId) || `${this.imageSources.get(frameId)}:${this.photoCropVersion}` !== sourceId) return
    const old = this.crops.get(frameId) || defaultCrop()
    if (["x", "y", "zoom"].every(key => Math.abs(old[key] - crop[key]) <= 1e-9)) return
    this.crops.set(frameId, crop)
    this.invalidate()
    this.statusTarget.textContent = "画像の調整範囲を変更しました。プレビューを作成してください。"
  }

  selectOshi(event) {
    if (this.disposed || !this.checkExpiry()) return
    this.closeCrop()
    const input = event.target
    this.lastAction = Date.now()
    if (input.checked) {
      if (this.selectedIds.length >= 4) {
        input.checked = false
        event.stopPropagation()
        this.errorTarget.textContent = "推しは4人まで選択できます。"
        return
      }
      this.selectedIds.push(input.value)
      this.imageSources.set(input.value, this.defaultImage(input.value))
    } else {
      this.selectedIds = this.selectedIds.filter(id => id !== input.value)
      this.imageSources.delete(input.value)
      this.crops.delete(input.value)
      for (const id of this.selectedIds) {
        const source = this.imageSources.get(id)
        if (source && !this.photoImage(source)) {
          this.imageSources.set(id, this.defaultImage(id))
          this.crops.delete(id)
        }
      }
    }
    this.renderFrames()
  }

  // Attachment IDs are globally unique. The owner is resolved from the
  // selected libraries, never from a URL, filename or the frame's name.
  defaultImage(ownerId) { return this.photoState.defaultImage(ownerId) }

  photoImage(attachmentId) { return this.photoState.image(attachmentId) }

  renderFrames() {
    const rows = this.selectedIds.map((id, index) => {
      const library = this.photoLibraries.get(id)
      const row = this.frameTemplateTarget.content.firstElementChild.cloneNode(true)
      const label = row.querySelector("[data-frame-label]")
      const source = row.querySelector("[data-frame-source]")
      source.id = `card-image-source-${id}`
      source.dataset.imageFor = id
      label.htmlFor = source.id
      label.textContent = `${index + 1}. ${library.name}の画像`
      source.add(new Option("画像を表示しない", ""))
      for (const candidate of this.selectedIds) {
        const owner = this.photoLibraries.get(candidate)
        if (!owner.images.length) continue
        const group = document.createElement("optgroup")
        group.label = owner.name
        owner.images.forEach(image => group.append(new Option(image.label, image.id)))
        source.append(group)
      }
      source.value = this.imageSources.get(id) || ""
      const image = this.photoImage(source.value)
      const preview = row.querySelector("[data-frame-preview]")
      const status = row.querySelector("[data-frame-image-status]")
      if (image) {
        preview.alt = `選択中：${image.label}`
        preview.src = image.url
        preview.hidden = false
        status.textContent = image.label
        preview.addEventListener("error", () => {
          preview.hidden = true
          status.textContent = "選択画像を取得できません。画像を選び直すか、ページを開き直して再生成してください。"
        })
      } else {
        status.textContent = library.images.length ? "画像を表示しません。" : "この推しの画像は未登録です。別の選択中の推しの画像も使えます。"
      }
      const adjust = row.querySelector("[data-crop-for]")
      adjust.dataset.cropFor = id
      adjust.setAttribute("aria-label", `${index + 1}. ${library.name}の画像を調整`)
      adjust.disabled = !image
      row.querySelector("[data-frame-library]").href = this.photoLibraries.get(image?.ownerId || id).editUrl
      return row
    })
    this.framesTarget.replaceChildren(...rows)
    this.updateGenerateButtons()
  }

  changed(event) {
    if (this.disposed || !this.checkExpiry()) return
    this.lastAction = Date.now()
    const id = event.target.dataset.imageFor
    if (id) {
      this.closeCrop()
      this.imageSources.set(id, event.target.value)
      this.crops.delete(id)
      this.renderFrames()
      this.framesTarget.querySelector(`[data-image-for="${id}"]`).focus()
    }
    this.invalidate()
    this.errorTarget.textContent = ""
    this.statusTarget.textContent = "設定を変更しました。プレビューを作成してください。"
  }

  async generate(event) {
    event.preventDefault()
    if (this.disposed || !this.checkExpiry()) return
    if (!this.canGenerate) return
    this.lastAction = Date.now()
    this.invalidate()
    const sequence = this.sequence
    const operation = new AbortController()
    this.operation = operation
    this.errorTarget.textContent = ""
    this.statusTarget.textContent = "カードを作成しています。"
    this.generating = true
    this.updateGenerateButtons(true)
    try {
      const card = this.template === "data" ? this.dataState.payload() :
        this.template === "memories" ? this.memoryState.payload() :
          this.photoState.payload(this.formTarget.elements.show_introduction.checked)
      const result = await createCard(this.createUrlValue, card, this.csrfToken, operation.signal)
      if (!this.current(sequence)) return
      this.result = result
      this.url = URL.createObjectURL(result.blob)
      this.imageTarget.src = this.url
      this.previewTarget.hidden = false
      this.downloadButtonTarget.disabled = false
      this.statusTarget.textContent = "完成プレビューを確認してから保存してください。"
    } catch (error) {
      if (this.current(sequence) && error.name !== "AbortError") {
        this.errorTarget.textContent = error.message
        this.statusTarget.textContent = ""
      }
    } finally {
      if (this.current(sequence)) {
        this.generating = false
        this.updateGenerateButtons()
      }
    }
  }

  async download() {
    if (this.disposed || !this.checkExpiry() || !this.result) return
    this.lastAction = Date.now()
    const result = this.result
    const sequence = this.sequence
    const operation = new AbortController()
    this.operation = operation
    this.downloadButtonTarget.disabled = true
    this.errorTarget.textContent = ""
    this.statusTarget.textContent = "保存前の確認をしています。"
    try {
      const blob = await downloadCard(this.downloadUrlValue, result, this.csrfToken, operation.signal)
      if (!this.checkExpiry() || !this.current(sequence) || this.result !== result) return
      const url = URL.createObjectURL(blob)
      const link = document.createElement("a")
      link.href = url
      link.download = "oshilog-card.png"
      document.body.append(link)
      link.click()
      link.remove()
      // Give the browser time to take ownership of the explicit download.
      setTimeout(() => URL.revokeObjectURL(url), 1000)
      this.statusTarget.textContent = "ダウンロードを開始しました。保存先をブラウザーで確認してください。"
    } catch (error) {
      if (this.current(sequence) && error.name !== "AbortError") {
        if (error.invalidatesPreview) this.invalidate()
        this.errorTarget.textContent = error.message
      }
    } finally {
      if (this.current(sequence) && this.result) this.downloadButtonTarget.disabled = false
    }
  }

  checkExpiry() {
    if (Date.now() - this.lastAction >= 30 * 60 * 1000) {
      this.dispose()
      this.statusTarget.textContent = "30分間操作がなかったため破棄しました。ページを開き直してください。"
      return false
    }
    if (this.result && Date.now() >= this.result.expiresAt) {
      this.invalidate()
      this.statusTarget.textContent = "プレビューの期限が切れました。再生成してください。"
    }
    return true
  }

  invalidate() {
    this.sequence += 1
    this.generating = false
    this.operation?.abort()
    if (this.url) URL.revokeObjectURL(this.url)
    this.url = null
    this.result = null
    this.imageTarget.removeAttribute("src")
    this.previewTarget.hidden = true
    this.updateGenerateButtons()
    this.downloadButtonTarget.disabled = true
  }

  dispose() {
    this.disposed = true
    clearInterval(this.timer)
    this.closeCrop()
    this.invalidate()
    this.settingsFormTargets.forEach(form => {
      form.reset()
      for (const input of form.elements) input.disabled = true
    })
    this.template = "photo"
    this.renderPanels()
    this.photoState?.clear()
    this.dataLoad?.abort()
    this.dataLoad = null
    this.dataState?.reset()
    this.dataYearTarget.replaceChildren()
    this.dataOshiTarget.replaceChildren()
    this.dataRetryTarget.hidden = true
    this.dataStatusTarget.textContent = ""
    this.memoryLoad?.abort()
    this.memoryLoad = null
    this.memoryState?.reset()
    this.memoryFramesTarget.replaceChildren()
    this.memoryAddTarget.disabled = true
    this.memoryRetryTarget.hidden = true
    this.memoryMoreTarget.hidden = true
    this.memoryMoreTarget.disabled = false
    this.memoryCursor = null
    this.memoryStatusTarget.textContent = ""
    this.framesTarget.replaceChildren()
    this.updateGenerateButtons(true)
  }

  current(sequence) { return !this.disposed && this.sequence === sequence }
  get csrfToken() { return document.querySelector('meta[name="csrf-token"]').content }

  get selectedIds() { return this.photoState.selectedIds }
  set selectedIds(value) { this.photoState.selectedIds = value }
  get photoLibraries() { return this.photoState.libraries }
  get imageSources() { return this.photoState.imageSources }
  get crops() { return this.photoState.crops }
  get photoCropVersion() { return this.photoState.cropVersion }
  set photoCropVersion(value) { this.photoState.cropVersion = value }
  get memories() { return this.memoryState.activities }
  set memories(value) { this.memoryState.activities = value }
  get memoryIds() { return this.memoryState.ids }
  set memoryIds(value) { this.memoryState.ids = value }
  get memoryEdits() { return this.memoryState.edits }
  get dataSettings() { return this.dataState.settings }
  set dataSettings(value) { this.dataState.settings = value }
}
