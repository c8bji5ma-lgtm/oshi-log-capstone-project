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
    this.edits.set(id, { imageId: activity.images[0]?.id || "", crop: defaultCrop() })
  }

  load(activities) {
    this.activities = activities
    this.ids = activities.slice(0, 3).map(activity => activity.id)
    this.ids.forEach(id => this.initialize(id))
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
