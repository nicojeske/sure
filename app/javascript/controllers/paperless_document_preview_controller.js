import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="paperless-document-preview"
// The cached mime type that decides <img> vs <iframe> reflects the document's *original*
// file, but Paperless-ngx's preview endpoint serves the archived version when one exists
// (e.g. a scanned image OCR'd into a PDF) — so the cached type can be stale. If the <img>
// fails to load, fall back to an <iframe> pointing at the same preview URL.
export default class extends Controller {
  static targets = ["image"];

  fallbackToFrame() {
    const image = this.imageTarget;
    const iframe = document.createElement("iframe");

    iframe.src = image.src;
    iframe.className = image.className;
    iframe.title = image.alt;

    image.replaceWith(iframe);
  }
}
