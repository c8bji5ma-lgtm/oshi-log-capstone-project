import { defaultCrop } from "lib/crop_geometry"

export class PhotoTemplateState {
  constructor(inputs) {
    this.selectedIds = inputs.filter(input => input.checked).map(input => input.value)
    this.libraries = new Map(inputs.map(input => [input.value, {
      name: input.dataset.name, editUrl: input.dataset.editUrl, images: JSON.parse(input.dataset.images)
    }]))
    this.imageSources = new Map(this.selectedIds.map(id => [id, this.defaultImage(id)]))
    this.crops = new Map()
    this.cropVersion = 0
  }

  defaultImage(ownerId) { return this.libraries.get(ownerId)?.images.find(image => image.representative)?.id || "" }

  image(attachmentId) {
    for (const ownerId of this.selectedIds) {
      const image = this.libraries.get(ownerId)?.images.find(candidate => candidate.id === attachmentId)
      if (image) return { ...image, ownerId }
    }
    return null
  }

  payload(showIntroduction) {
    return {
      template: "photo", user_oshi_ids: this.selectedIds,
      image_user_oshi_ids: this.selectedIds.map(id => this.image(this.imageSources.get(id))?.ownerId || ""),
      image_attachment_ids: this.selectedIds.map(id => this.imageSources.get(id) || ""),
      crops: this.selectedIds.map(id => this.crops.get(id) || defaultCrop()),
      show_introduction: showIntroduction
    }
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
