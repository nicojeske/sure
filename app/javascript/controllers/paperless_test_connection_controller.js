import { Controller } from "@hotwired/stimulus"

// Posts to Settings::ReceiptsController#test_connection and renders the
// success/failure message inline, without a full page reload.
export default class extends Controller {
  static targets = ["button", "result"]
  static values = { url: String }

  async test() {
    const button = this.buttonTarget
    const result = this.resultTarget
    const originalText = button.textContent

    button.disabled = true
    button.textContent = button.dataset.testingText || "Testing..."
    result.textContent = ""
    result.classList.remove("text-success", "text-destructive")

    try {
      const response = await fetch(this.urlValue, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Accept: "application/json",
          "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content
        }
      })
      const data = await response.json()

      result.textContent = data.message
      result.classList.add(data.success ? "text-success" : "text-destructive")
    } catch (error) {
      result.textContent = error.message
      result.classList.add("text-destructive")
    } finally {
      button.disabled = false
      button.textContent = originalText
    }
  }
}
