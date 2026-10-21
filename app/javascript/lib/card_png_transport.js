async function errorMessage(response) {
  try { return (await response.json()).error || "処理に失敗しました。" }
  catch { return "通信に失敗しました。もう一度操作してください。" }
}

async function sha256(blob) {
  if (!crypto.subtle) throw new Error("HTTPSまたはlocalhostで開いてください。")
  const digest = await crypto.subtle.digest("SHA-256", await blob.arrayBuffer())
  return Array.from(new Uint8Array(digest), byte => byte.toString(16).padStart(2, "0")).join("")
}

export async function createCard(url, card, csrfToken, signal) {
  const response = await fetch(url, {
    method: "POST", credentials: "same-origin", signal,
    headers: { "Content-Type": "application/json", "X-CSRF-Token": csrfToken },
    body: JSON.stringify({ card })
  })
  if (!response.ok) throw new Error(await errorMessage(response))
  const blob = await response.blob()
  const digest = await sha256(blob)
  const expiresAt = Number(response.headers.get("X-Card-Expires-At")) * 1000
  if (blob.type !== "image/png" || digest !== response.headers.get("X-PNG-SHA256") || expiresAt <= Date.now()) {
    throw new Error("完成画像を確認できません。再生成してください。")
  }
  return { blob, digest, expiresAt, receipt: response.headers.get("X-Card-Receipt") }
}

export async function downloadCard(url, result, csrfToken, signal) {
  const response = await fetch(url, {
    method: "POST", credentials: "same-origin", signal,
    headers: { "Content-Type": "image/png", "X-CSRF-Token": csrfToken, "X-Card-Receipt": result.receipt },
    body: result.blob
  })
  if (!response.ok) {
    const error = new Error(await errorMessage(response))
    error.invalidatesPreview = [401, 403, 409, 410, 422].includes(response.status)
    throw error
  }
  const blob = await response.blob()
  const digest = await sha256(blob)
  if (digest !== result.digest || blob.size !== result.blob.size) throw new Error("確認したPNGと一致しません。")
  return blob
}

export { errorMessage }
