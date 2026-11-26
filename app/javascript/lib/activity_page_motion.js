// Keep normal Turbo navigation outside the two activity screens.
document.addEventListener("turbo:before-render", ({ detail }) => {
  if (typeof document.startViewTransition !== "function") return
  if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return
  const root = document.documentElement
  if (root.hasAttribute("data-activity-transition") || root.hasAttribute("data-turbo-preview")) return

  const page = body => body.querySelector("main h1[data-activity-motion-page]")?.dataset.activityMotionPage
  const pair = [page(document.body), page(detail.newBody)]
  if (!pair.includes("index") || !pair.includes("new")) return

  const render = detail.render
  detail.render = (current, next) => {
    root.setAttribute("data-activity-transition", "")
    let transition
    try {
      transition = document.startViewTransition(() => render(current, next))
    } catch {
      root.removeAttribute("data-activity-transition")
      return render(current, next)
    }
    const clear = () => root.removeAttribute("data-activity-transition")
    transition.finished.then(clear, clear)
    // Turbo waits for the DOM update, never for the animation to finish.
    return transition.updateCallbackDone
  }
})
