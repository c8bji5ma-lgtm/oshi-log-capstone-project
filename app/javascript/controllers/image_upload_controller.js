import { Controller } from "@hotwired/stimulus"

const CONTENT_TYPES = ["image/jpeg", "image/png", "image/webp"]
const MAX_BYTES = 10 * 1024 * 1024
const MAX_BATCH_BYTES = 10 * 1024 * 1024
const MAX_SOURCE_BYTES = 25 * 1024 * 1024
const MAX_DIMENSION = 2560
const MAX_PIXELS = 5_000_000
const LOSSY_QUALITIES = [0.9, 0.82, 0.74, 0.66]

export default class extends Controller {
  static targets = ["input", "status", "preview", "previewImages"]
  static values = { previewAlt: String, previewError: String }

  connect() {
    this.version ??= 0
    this.queue = Promise.resolve()
    this.form = this.element.closest("form")
    this.submitHandler = event => this.guardSubmit(event)
    this.form?.addEventListener("submit", this.submitHandler)
    this.previewSuspended = false
    if (this.hasPreviewTarget) {
      this.cacheHandler = () => {
        this.previewSuspended = true
        this.clearPreview()
      }
      document.addEventListener("turbo:before-cache", this.cacheHandler)
      this.renderPreview()
    }
    if (this.inputTarget.dataset.imageUploadReady === "false" && this.inputTarget.files.length > 0) this.change()
  }

  disconnect() {
    this.version += 1
    this.form?.removeEventListener("submit", this.submitHandler)
    document.removeEventListener("turbo:before-cache", this.cacheHandler)
    this.clearPreview()
    this.setBusy(false)
  }

  change() {
    const version = ++this.version
    const files = Array.from(this.inputTarget.files || [])
    this.inputTarget.dataset.imageUploadReady = "false"
    this.clearPreview()

    if (files.length === 0) {
      this.setStatus("")
      this.setBusy(false)
      return
    }

    this.setBusy(true)
    this.setStatus(`${files.length}枚の画像を確認しています。`)
    this.queue = this.queue.then(() => this.prepare(version, files))
  }

  guardSubmit(event) {
    if (!this.busy) return

    event.preventDefault()
    event.stopImmediatePropagation()
    this.setStatus("画像の処理が完了するまでお待ちください。", true)
  }

  async prepare(version, files) {
    const prepared = []
    let resized = 0

    try {
      for (const file of files) {
        if (!this.current(version)) return
        const result = await this.prepareFile(file, version)
        prepared.push(result.file)
        if (result.resized) resized += 1
      }
      if (prepared.reduce((total, file) => total + file.size, 0) > MAX_BATCH_BYTES) {
        throw new Error("1回に送信する画像の合計を10 MiB以下にしてください。分けて追加できます。")
      }

      if (!this.current(version)) return

      const transfer = new DataTransfer()
      prepared.forEach(file => transfer.items.add(file))
      this.inputTarget.files = transfer.files
      this.inputTarget.dataset.imageUploadReady = "true"
      const unchanged = files.length - resized
      const details = [
        resized > 0 ? `${resized}枚を縮小しました` : null,
        unchanged > 0 ? `${unchanged}枚は元のファイルを使用します` : null
      ].filter(Boolean).join("。")
      this.setStatus(`${details}。送信できます。`)
      this.renderPreview()
    } catch (error) {
      if (!this.current(version)) return
      this.inputTarget.value = ""
      this.inputTarget.dataset.imageUploadReady = "false"
      this.clearPreview()
      this.setStatus(error instanceof Error ? error.message : "画像を処理できませんでした。画像を選び直してください。", true)
    } finally {
      if (this.current(version)) this.setBusy(false)
    }
  }

  renderPreview() {
    this.clearPreview()
    const generation = this.previewGeneration

    try {
      if (!this.hasPreviewTarget || !this.hasPreviewImagesTarget || this.previewSuspended) return
      if (this.inputTarget.dataset.imageUploadReady !== "true" || this.inputTarget.files.length === 0) return

      const fragment = document.createDocumentFragment()
      Array.from(this.inputTarget.files).forEach((file, index) => {
        const url = URL.createObjectURL(file)
        this.previewURLs.push(url)
        const image = document.createElement("img")
        image.alt = this.previewAltValue
          .replace("%{index}", () => String(index + 1))
          .replace("%{filename}", () => file.name)
        image.onerror = () => this.failPreview(generation)
        image.src = url
        fragment.append(image)
      })
      this.previewImagesTarget.append(fragment)
      this.previewTarget.hidden = false
    } catch {
      this.failPreview(generation)
    }
  }

  clearPreview() {
    this.previewGeneration = (this.previewGeneration ?? 0) + 1
    const urls = this.previewURLs || []
    this.previewURLs = []

    try {
      if (this.hasPreviewTarget) this.previewTarget.hidden = true
      if (this.hasPreviewImagesTarget) this.previewImagesTarget.replaceChildren()
    } catch {
      // A display failure must not clear a valid FileList.
    }
    urls.forEach(url => {
      try {
        URL.revokeObjectURL(url)
      } catch {
        // Continue releasing the other URLs if the browser rejects one.
      }
    })
  }

  failPreview(generation) {
    if (generation !== this.previewGeneration || this.previewSuspended || !this.element.isConnected) return

    this.clearPreview()
    try {
      this.setStatus(this.previewErrorValue, true)
    } catch {
      // A disconnected status target must not fail the image preparation.
    }
  }

  async prepareFile(file, version) {
    if (!CONTENT_TYPES.includes(file.type)) throw new Error("JPEG・PNG・WebP形式の画像を選び直してください。")
    if (file.size <= 0 || file.size > MAX_SOURCE_BYTES) {
      throw new Error("画像が大きすぎて端末で安全に処理できません。25 MiB以下の画像を選び直してください。")
    }
    if (await this.animated(file)) throw new Error("アニメーション画像には対応していません。静止画像を選び直してください。")
    if (!this.current(version)) throw new Error("画像の選択が変更されました。")
    if (typeof createImageBitmap !== "function") {
      throw new Error("このブラウザーでは画像を縮小できません。端末で縮小してから選び直してください。")
    }

    let bitmap
    try {
      bitmap = await createImageBitmap(file, { imageOrientation: "from-image" })
      if (!this.current(version)) return { file, resized: false }
      if (bitmap.width <= 0 || bitmap.height <= 0) throw new Error("画像の寸法を確認できません。")
      if (this.withinLimits(bitmap.width, bitmap.height, file.size)) return { file, resized: false }

      const dimensions = this.targetDimensions(bitmap.width, bitmap.height)
      const blob = await this.encode(bitmap, file.type, dimensions.width, dimensions.height)
      await this.validateOutput(blob)
      return {
        file: new File([blob], file.name, { type: blob.type, lastModified: file.lastModified }),
        resized: true
      }
    } catch (error) {
      if (error instanceof Error && error.message.endsWith("。")) throw error
      throw new Error("画像を端末で縮小できませんでした。別の画像を選ぶか、端末で縮小してから再選択してください。")
    } finally {
      bitmap?.close()
    }
  }

  withinLimits(width, height, bytes) {
    return width <= MAX_DIMENSION && height <= MAX_DIMENSION &&
      width * height <= MAX_PIXELS && bytes <= MAX_BYTES
  }

  targetDimensions(width, height) {
    const scale = Math.min(1, MAX_DIMENSION / width, MAX_DIMENSION / height, Math.sqrt(MAX_PIXELS / (width * height)))
    return { width: Math.max(1, Math.floor(width * scale)), height: Math.max(1, Math.floor(height * scale)) }
  }

  async encode(bitmap, type, initialWidth, initialHeight) {
    const canvas = document.createElement("canvas")
    let width = initialWidth
    let height = initialHeight

    try {
      for (let pass = 0; pass < 4; pass += 1) {
        canvas.width = width
        canvas.height = height
        const context = canvas.getContext("2d", { alpha: type !== "image/jpeg" })
        if (!context) throw new Error("画像処理を開始できません。")
        context.drawImage(bitmap, 0, 0, width, height)

        const qualities = type === "image/png" ? [undefined] : LOSSY_QUALITIES
        let smallest
        for (const quality of qualities) {
          const blob = await this.toBlob(canvas, type, quality)
          if (blob.type !== type) throw new Error("画像形式を維持できないブラウザーです。")
          if (!smallest || blob.size < smallest.size) smallest = blob
          if (blob.size <= MAX_BYTES) return blob
        }

        const scale = Math.min(0.9, Math.sqrt(MAX_BYTES / smallest.size) * 0.95)
        width = Math.max(1, Math.floor(width * scale))
        height = Math.max(1, Math.floor(height * scale))
      }
    } finally {
      canvas.width = 1
      canvas.height = 1
    }

    throw new Error("画像を10 MiB以下に圧縮できませんでした。端末で縮小してから再選択してください。")
  }

  toBlob(canvas, type, quality) {
    return new Promise((resolve, reject) => {
      canvas.toBlob(blob => blob ? resolve(blob) : reject(new Error("画像を書き出せませんでした。")), type, quality)
    })
  }

  async validateOutput(blob) {
    if (!CONTENT_TYPES.includes(blob.type) || blob.size <= 0 || blob.size > MAX_BYTES) {
      throw new Error("縮小後の画像を安全に確認できませんでした。")
    }

    const output = await createImageBitmap(blob, { imageOrientation: "from-image" })
    try {
      if (!this.withinLimits(output.width, output.height, blob.size)) {
        throw new Error("縮小後の画像が上限を超えています。")
      }
    } finally {
      output.close()
    }
  }

  async animated(file) {
    if (file.type === "image/jpeg") return false
    const bytes = new Uint8Array(await file.arrayBuffer())

    if (file.type === "image/png") {
      let offset = 8
      while (offset + 12 <= bytes.length) {
        const length = this.uint32(bytes, offset)
        const kind = String.fromCharCode(...bytes.slice(offset + 4, offset + 8))
        if (kind === "acTL") return true
        if (offset + length + 12 > bytes.length) return false
        offset += length + 12
        if (kind === "IEND") return false
      }
      return false
    }

    let offset = 12
    while (offset + 8 <= bytes.length) {
      const kind = String.fromCharCode(...bytes.slice(offset, offset + 4))
      const length = this.uint32(bytes, offset + 4, true)
      if (kind === "ANIM" || kind === "ANMF") return true
      if (offset + length + 8 > bytes.length) return false
      offset += 8 + length + (length % 2)
    }
    return false
  }

  uint32(bytes, offset, littleEndian = false) {
    return new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength).getUint32(offset, littleEndian)
  }

  current(version) {
    return version === this.version && this.inputTarget.isConnected
  }

  setBusy(busy) {
    this.busy = busy
    if (!this.form) return

    if (busy && !this.submitStates) {
      this.submitStates = new Map(Array.from(this.form.querySelectorAll("button[type='submit'], input[type='submit']")).map(button => [button, button.disabled]))
      this.submitStates.forEach((_disabled, button) => { button.disabled = true })
    } else if (!busy && this.submitStates) {
      this.submitStates.forEach((disabled, button) => {
        if (button.isConnected) button.disabled = disabled
      })
      this.submitStates = null
    }
    this.form.setAttribute("aria-busy", busy ? "true" : "false")
  }

  setStatus(message, error = false) {
    this.statusTarget.textContent = message
    this.statusTarget.setAttribute("role", error ? "alert" : "status")
  }
}
