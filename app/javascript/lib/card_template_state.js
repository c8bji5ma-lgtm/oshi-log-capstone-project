import { defaultCrop } from "lib/crop_geometry"

export class PhotoTemplateState {
  constructor(inputs) {
    this.selectedIds = inputs.filter(input => input.checked).map(input => input.value)
    this.libraries = new Map(inputs.map(input => [input.value, {
      name: input.dataset.name, editUrl: input.dataset.editUrl, images: JSON.parse(input.dataset.images)
    }]))
    this.imageSources = new Map()
    this.crops = new Map()
    this.cropVersion = 0
    this.syncFrames()
  }

  defaultImage(ownerId) { return this.libraries.get(ownerId)?.images.find(image => image.representative)?.id || "" }

  image(attachmentId) {
    for (const ownerId of this.selectedIds) {
      const image = this.libraries.get(ownerId)?.images.find(candidate => candidate.id === attachmentId)
      if (image) return { ...image, ownerId }
    }
    return null
  }

  collageKeys() {
    const ownerId = this.selectedIds[0]
    return ownerId ? [ownerId, `${ownerId}-supplement-1`, `${ownerId}-supplement-2`] : []
  }

  frameKeys() { return this.selectedIds.length === 1 ? this.collageKeys() : [...this.selectedIds] }

  frames() {
    if (this.selectedIds.length !== 1) {
      return this.selectedIds.map((id, index) => ({ key: id, ownerId: id, label: `${index + 1}. ${this.libraries.get(id).name}の画像`, supplementary: false }))
    }
    const ownerId = this.selectedIds[0]
    const name = this.libraries.get(ownerId).name
    return this.collageKeys().map((key, index) => ({
      key, ownerId, supplementary: index > 0,
      label: index === 0 ? `主写真：${name}` : `補助写真${index}：${name}`
    }))
  }

  syncFrames() {
    const keys = this.frameKeys()
    const allowed = new Set(keys)
    for (const key of this.imageSources.keys()) if (!allowed.has(key)) this.imageSources.delete(key)
    for (const key of this.crops.keys()) if (!allowed.has(key)) this.crops.delete(key)
    if (!keys.length) return

    if (this.selectedIds.length === 1) {
      const ownerId = this.selectedIds[0]
      const library = this.libraries.get(ownerId)?.images || []
      if (!this.imageSources.has(ownerId)) this.imageSources.set(ownerId, this.defaultImage(ownerId))
      const initial = library.map(image => image.id).filter(id => id !== this.imageSources.get(ownerId))
      keys.slice(1).forEach((key, index) => {
        if (!this.imageSources.has(key)) this.imageSources.set(key, initial[index] || "")
      })
    } else {
      keys.forEach(id => {
        if (!this.imageSources.has(id)) this.imageSources.set(id, this.defaultImage(id))
      })
    }
  }

  select(ownerId) { this.selectedIds.push(ownerId); this.syncFrames() }

  deselect(ownerId) {
    this.selectedIds = this.selectedIds.filter(id => id !== ownerId)
    this.syncFrames()
    for (const id of this.selectedIds) {
      const source = this.imageSources.get(id)
      if (source && !this.image(source)) {
        this.imageSources.set(id, this.defaultImage(id))
        this.crops.delete(id)
      }
    }
  }

  layout(frameId, layouts, collageLayouts) {
    if (this.selectedIds.length !== 1) return layouts[this.selectedIds.length]
    const keys = this.collageKeys()
    if (frameId === keys[0]) return collageLayouts.main
    const visible = keys.slice(1).filter(key => this.imageSources.get(key))
    if (visible.length <= 1) return collageLayouts.supplement_one
    return frameId === visible[0] ? collageLayouts.supplement_left : collageLayouts.supplement_right
  }

  payload(showIntroduction) {
    const payload = {
      template: "photo", user_oshi_ids: this.selectedIds,
      image_user_oshi_ids: this.selectedIds.map(id => this.image(this.imageSources.get(id))?.ownerId || ""),
      show_introduction: showIntroduction
    }
    if (this.selectedIds.length === 1) {
      const keys = this.collageKeys()
      payload.collage_image_attachment_ids = keys.map(key => this.imageSources.get(key) || "")
      payload.collage_crops = keys.map(key => this.crops.get(key) || defaultCrop())
    } else {
      payload.image_attachment_ids = this.selectedIds.map(id => this.imageSources.get(id) || "")
      payload.crops = this.selectedIds.map(id => this.crops.get(id) || defaultCrop())
    }
    return payload
  }

  clear() {
    this.selectedIds = []
    this.imageSources.clear()
    this.libraries.clear()
    this.crops.clear()
  }
}

export class MemoryTemplateState {
  constructor() { this.reset() }

  initialize(id) {
    const activity = this.activities.find(item => item.id === id)
    if (!activity.oshis) activity.oshis = []
    if (!activity.images) activity.images = []
    activity.materials ||= {
      oshis: { cursor: null, hasMore: activity.oshi_count > 0, loaded: false, total: activity.oshi_count, error: null },
      images: { cursor: null, hasMore: activity.image_count > 0, loaded: false, total: activity.image_count, error: null }
    }
    if (!this.edits.has(id)) this.edits.set(id, { imageId: null, crop: defaultCrop() })
  }

  load(activities) {
    this.activities = activities
    this.ids = activities.slice(0, 3).map(activity => activity.id)
    this.ids.forEach(id => this.initialize(id))
  }

  append(activities) {
    const known = new Set(this.activities.map(activity => activity.id))
    const additions = activities.filter(activity => !known.has(activity.id))
    this.activities.push(...additions)
    return additions.length
  }

  appendMaterials(id, kind, items, nextCursor, hasMore, totalCount) {
    const activity = this.activities.find(item => item.id === id)
    if (!activity || !["oshis", "images"].includes(kind)) return 0
    this.initialize(id)
    const known = new Set(activity[kind].map(item => item.id))
    const additions = items.filter(item => !known.has(item.id))
    activity[kind].push(...additions)
    Object.assign(activity.materials[kind], { cursor: nextCursor, hasMore, loaded: true, total: totalCount, error: null })
    const edit = this.edits.get(id)
    if (kind === "images" && edit.imageId === null) edit.imageId = activity.images[0]?.id || ""
    return additions.length
  }

  material(id, kind) {
    const activity = this.activities.find(item => item.id === id)
    this.initialize(id)
    return activity.materials[kind]
  }

  forget(id) {
    this.edits.delete(id)
  }

  payload() {
    return {
      template: "memory", activity_ids: this.ids,
      image_attachment_ids: this.ids.map(id => this.edits.get(id).imageId),
      crops: this.ids.map(id => this.edits.get(id).crop)
    }
  }

  reset() { this.activities = null; this.ids = []; this.edits = new Map() }
}

export class DataTemplateState {
  constructor() { this.settings = null }
  payload() { return { template: "data", ...this.settings } }
  reset() { this.settings = null }
}
