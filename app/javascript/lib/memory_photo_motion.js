// Only animate a Turbo click from the memory gallery to its matching photo.
let clickedLink
document.addEventListener("turbo:click", event => {
  clickedLink = event.target.closest("a[data-memory-photo-link]")
})
document.addEventListener("turbo:before-visit", event => {
  if (clickedLink?.href !== event.detail.url) clickedLink = null
})

document.addEventListener("turbo:before-render", ({ detail }) => {
  const link = clickedLink
  clickedLink = null
  if (!link?.isConnected || typeof document.startViewTransition !== "function") return
  if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return

  const root = document.documentElement
  if (root.hasAttribute("data-turbo-preview") || root.hasAttribute("data-memory-photo-transition")) return
  const source = link.querySelector(".oshi-memory-photo__frame")
  const destination = detail.newBody.querySelector("[data-memory-photo-feature]")
  if (!source || destination?.dataset.memoryPhotoFeature !== link.dataset.memoryPhotoLink) return

  const render = detail.render
  detail.render = (current, next) => {
    const clear = () => {
      root.removeAttribute("data-memory-photo-transition")
      source.classList.remove("memory-photo-transition-target")
      destination.classList.remove("memory-photo-transition-target")
    }
    root.setAttribute("data-memory-photo-transition", "")
    source.classList.add("memory-photo-transition-target")
    destination.classList.add("memory-photo-transition-target")
    let transition
    try {
      transition = document.startViewTransition(() => render(current, next))
    } catch {
      clear()
      return render(current, next)
    }
    transition.finished.then(clear, clear)
    return transition.updateCallbackDone
  }
})
