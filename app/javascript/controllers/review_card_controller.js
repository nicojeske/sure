import { Controller } from "@hotwired/stimulus";

const FIELD_KEYS = ["name", "merchant", "category", "tags", "notes"];
const FRAME_ID = "monthly_review_card";
const TYPING_INPUT_TYPES = ["checkbox", "radio", "button", "submit", "reset"];
// Focused elements whose own Enter must not accept the card.
const INTERACTIVE_TAGS = ["A", "BUTTON", "SUMMARY", "SELECT"];
// A card waiting for a background read updates over the cable. In case that
// update is missed it reloads its own frame every POLL_INTERVAL, at most
// POLL_LIMIT times; after that it says it is taking longer than usual.
const POLL_INTERVAL = 6000;
const POLL_LIMIT = 20;
const FEEDBACK_DURATION = 4000;

// Keyboard map of the monthly review card. The hint input is not autofocused:
// outside it every letter is a shortcut, `/` or `h` focuses it and Esc leaves
// it. The controller sits outside the card's Turbo frame, so the queue list
// keeps its scroll position while cards swap; each new card announces itself
// through the `card` target.
//
// Connects to data-controller="review-card"
export default class extends Controller {
  static targets = [
    "card",
    "list",
    "hint",
    "search",
    "edit",
    "feedback",
    "stalled",
  ];
  static values = { messages: Object };

  disconnect() {
    clearTimeout(this.pollTimer);
    clearTimeout(this.feedbackTimer);
  }

  cardTargetConnected(card) {
    this.hintSending = false;
    this.choiceIndex = 0;
    this.searchIndex = 0;
    this.paintList(card);
    this.paintChoices();
    if (this.hasHintTarget && document.activeElement === this.hintTarget) {
      this.hintTarget.blur();
    }
    this.schedulePoll(card);
  }

  cardTargetDisconnected() {
    clearTimeout(this.pollTimer);
  }

  // keydown@document
  key(event) {
    if (event.defaultPrevented || event.isComposing || !this.hasCardTarget)
      return;

    const plain = !event.ctrlKey && !event.metaKey && !event.altKey;
    if (
      event.shiftKey &&
      plain &&
      (event.key === "ArrowDown" || event.key === "ArrowUp")
    ) {
      event.preventDefault();
      return this.scrollReceipt(event.key === "ArrowDown" ? 1 : -1);
    }

    const target = event.target;
    const tag = target.tagName;
    if (tag === "SELECT" || tag === "TEXTAREA" || target.isContentEditable)
      return;

    const inHint = this.hasHintTarget && target === this.hintTarget;
    const inSearch = this.hasSearchTarget && this.searchTarget.contains(target);
    const inEdit =
      this.hasEditTarget &&
      this.editTarget.open &&
      tag !== "SUMMARY" &&
      this.editTarget.contains(target);
    const typing = tag === "INPUT" && !TYPING_INPUT_TYPES.includes(target.type);

    if (inSearch && this.searchOpen()) return this.searchKey(event);
    if (inEdit) {
      if (event.key === "Escape") {
        event.preventDefault();
        this.closeEdit();
      }
      return;
    }
    if (typing && !inHint) return;

    if (inHint) return this.hintKey(event, plain);

    // "/" needs Shift on some layouts (German: Shift+7), so only "h" checks it.
    if (
      plain &&
      (event.key === "/" || (event.key === "h" && !event.shiftKey))
    ) {
      event.preventDefault();
      return this.hintTarget?.focus();
    }

    if (
      plain &&
      this.state() === "receipt_choice" &&
      (event.key === "ArrowDown" || event.key === "ArrowUp")
    ) {
      event.preventDefault();
      return this.moveChoice(event.key === "ArrowDown" ? 1 : -1);
    }

    if (event.key === "Enter") {
      if (INTERACTIVE_TAGS.includes(tag) || target.closest("[role=button]"))
        return;
      event.preventDefault();
      if (event.ctrlKey || event.metaKey) return this.decide("reviewed_only");
      if (plain) this.accept();
      return;
    }

    if (event.key === "Escape" && plain) {
      event.preventDefault();
      if (this.hasEditTarget && this.editTarget.open) return this.closeEdit();
      if (this.searchOpen()) return this.closeSearch();
      return this.decide("skip");
    }

    if (
      event.altKey &&
      !event.ctrlKey &&
      !event.metaKey &&
      event.key === "ArrowLeft"
    ) {
      event.preventDefault();
      return this.decide("back", "first_card");
    }

    if (!plain) return;
    this.shortcut(event, event.key.toLowerCase());
  }

  // input on the receipt search query
  searchEdited() {
    this.searchDirty = true;
  }

  // turbo:frame-load on the receipt search results
  searchLoaded() {
    this.searchDirty = false;
    this.searchIndex = 0;
    this.paintSearch();
  }

  // ---- keys -----------------------------------------------------------------

  hintKey(event, plain) {
    if (event.key === "Escape") {
      event.preventDefault();
      this.hintTarget.blur();
      return;
    }
    if (event.key !== "Enter") return;

    if (event.ctrlKey || event.metaKey) {
      event.preventDefault();
      return this.decide("reviewed_only");
    }
    if (this.hintSending || this.busy()) return event.preventDefault();
    if (plain && !this.hintTarget.value.trim()) {
      event.preventDefault();
      this.accept();
      return;
    }
    // With text, Enter submits the hint form natively, once per card.
    this.hintSending = true;
  }

  shortcut(event, key) {
    if (/^[1-5]$/.test(key)) {
      event.preventDefault();
      return this.toggleField(FIELD_KEYS[Number(key) - 1]);
    }

    const handlers = {
      x: () => this.toggleField("split"),
      u: () =>
        this.state() === "reviewed"
          ? this.decide("undo")
          : this.flash("nothing_to_undo"),
      f: () => this.openSearch(),
      o: () => this.openReceipt(),
      e: () => this.toggleEdit(),
      b: () =>
        this.pressSuggestion("bill", event.shiftKey ? "dismiss" : "accept"),
    };
    if (handlers[key]) {
      event.preventDefault();
      handlers[key]();
    }
  }

  searchKey(event) {
    const results = this.searchResults();

    if (event.key === "Escape") {
      event.preventDefault();
      return this.closeSearch();
    }
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault();
      if (!results.length) return;
      const delta = event.key === "ArrowDown" ? 1 : -1;
      this.searchIndex =
        (this.searchIndex + delta + results.length) % results.length;
      return this.paintSearch();
    }
    if (event.key === "Enter") {
      event.preventDefault();
      if (this.searchDirty || !results.length) {
        return this.searchInput()?.form.requestSubmit();
      }
      if (!this.busy()) results[this.searchIndex]?.click();
    }
  }

  // ---- actions ---------------------------------------------------------------

  accept() {
    switch (this.state()) {
      case "loading":
        return this.flash("still_reading");
      case "receipt_choice":
        return this.choices()[this.choiceIndex]?.click();
      case "reviewed":
        return this.decide("skip");
      default:
        return this.decide("accept");
    }
  }

  // Submits the card's decision form through the button for `decision`, so
  // the key does exactly what the button does.
  decide(decision, missingMessage = null) {
    if (this.busy()) return;

    const button = this.cardTarget.querySelector(
      `[data-review-decision="${decision}"]`,
    );
    if (!button) {
      if (missingMessage) this.flash(missingMessage);
      return;
    }
    button.form.requestSubmit(button);
  }

  // Presses a suggestions-strip button (accept or dismiss) of the `kind`
  // suggestion, so the key does exactly what the button does.
  pressSuggestion(kind, action) {
    if (this.busy()) return;

    const button = this.cardTarget.querySelector(
      `[data-review-suggestion="${kind}"][data-review-suggestion-action="${action}"]`,
    );
    if (!button) return this.flash(`no_${kind}_suggestion`);

    button.form.requestSubmit(button);
  }

  toggleField(key) {
    const input = this.cardTarget.querySelector(`[data-review-field="${key}"]`);
    if (!input) return this.flash("nothing_proposed");

    input.checked = !input.checked;
    input.dispatchEvent(new Event("change", { bubbles: true }));
  }

  scrollReceipt(direction) {
    const pane = this.visible(
      this.element.querySelectorAll("[data-receipt-scroll]"),
    )[0];
    if (!pane) return;

    pane.scrollBy({
      top: direction * pane.clientHeight * 0.6,
      behavior: "smooth",
    });
  }

  openReceipt() {
    const url = this.cardTarget.dataset.reviewCardPaperlessUrl;
    if (!url) return this.flash("no_receipt");

    window.open(url, "_blank", "noopener");
  }

  toggleEdit() {
    if (!this.hasEditTarget) return;

    this.editTarget.open = !this.editTarget.open;
    if (this.editTarget.open) {
      this.editTarget.querySelector("input:not([type=hidden])")?.focus();
    }
  }

  closeEdit() {
    this.editTarget.open = false;
    document.activeElement?.blur();
  }

  // ---- receipt search (f) ----------------------------------------------------

  searchOpen() {
    return this.hasSearchTarget && !this.searchTarget.hidden;
  }

  openSearch() {
    if (!this.hasSearchTarget) return;

    this.searchTarget.hidden = false;
    const input = this.searchInput();
    input?.focus();
    input?.select();
    if (!this.searchResults().length) input?.form.requestSubmit();
  }

  closeSearch() {
    this.searchTarget.hidden = true;
    document.activeElement?.blur();
  }

  searchInput() {
    return this.searchTarget.querySelector("input[type=search]");
  }

  searchResults() {
    return this.hasSearchTarget
      ? [...this.searchTarget.querySelectorAll("[data-review-search-result]")]
      : [];
  }

  paintSearch() {
    this.searchResults().forEach((result, index) => {
      result.dataset.active = String(index === this.searchIndex);
      if (index === this.searchIndex)
        result.scrollIntoView({ block: "nearest" });
    });
  }

  // ---- receipt choice --------------------------------------------------------

  // The picker renders in the receipt column and inside the card; only the
  // visible copy answers.
  choices() {
    return this.visible(this.element.querySelectorAll("[data-review-choice]"));
  }

  moveChoice(delta) {
    const choices = this.choices();
    if (!choices.length) return;

    this.choiceIndex =
      (this.choiceIndex + delta + choices.length) % choices.length;
    this.paintChoices();
  }

  paintChoices() {
    this.choices().forEach((choice, index) => {
      choice.dataset.active = String(index === this.choiceIndex);
    });
  }

  // The end of the queue redirects to the month's summary, which has no card
  // frame: show it as a full page instead of "Content missing".
  // turbo:frame-missing->review-card#leaveFrame
  leaveFrame(event) {
    event.preventDefault();
    event.detail.visit(event.detail.response);
  }

  // ---- list and polling -----------------------------------------------------

  paintList(card) {
    if (!this.hasListTarget) return;

    const reviewed = new Set(
      JSON.parse(card.dataset.reviewCardReviewedIds || "[]"),
    );
    const currentId = card.dataset.reviewCardEntryId;
    const rows = [
      ...this.listTarget.querySelectorAll("[data-review-entry-id]"),
    ];
    // A split or an undone split changes the month's entries; the list is
    // outside the frame, so refresh the page (morphed, scroll kept).
    const total = Number(card.dataset.reviewCardTotal);
    if (total && total !== rows.length) return this.refreshPage();

    // Skips aren't stored: a row passed over stays open, as on the server.
    for (const row of rows) {
      const id = row.dataset.reviewEntryId;
      let status = "open";
      if (id === currentId) status = "current";
      else if (reviewed.has(id)) status = "reviewed";
      row.dataset.status = status;

      const link = row.querySelector("a");
      if (status === "current") {
        link?.setAttribute("aria-current", "true");
        if (link?.offsetParent) row.scrollIntoView({ block: "nearest" });
      } else {
        link?.removeAttribute("aria-current");
      }
    }

    for (const count of this.element.querySelectorAll(
      "[data-review-reviewed-count]",
    )) {
      count.textContent = reviewed.size;
    }
  }

  // A card waiting for its background read polls its own frame (never the
  // whole page, which would start a prefetch). The poll count restarts for
  // each entry; past POLL_LIMIT the card says it is taking longer than usual.
  schedulePoll(card) {
    clearTimeout(this.pollTimer);
    const entryId = card.dataset.reviewCardEntryId;
    if (entryId !== this.pollEntryId) {
      this.pollEntryId = entryId;
      this.polls = 0;
    }
    if (card.dataset.reviewCardState !== "loading") return;
    if (this.polls >= POLL_LIMIT) return this.showStalled();

    this.pollTimer = setTimeout(() => {
      this.polls += 1;
      Turbo.visit(window.location.href, { frame: FRAME_ID, action: "replace" });
    }, POLL_INTERVAL);
  }

  showStalled() {
    for (const element of this.stalledTargets) element.hidden = false;
  }

  refreshPage() {
    Turbo.renderStreamMessage('<turbo-stream action="refresh"></turbo-stream>');
  }

  // ---- helpers ---------------------------------------------------------------

  state() {
    return this.cardTarget.dataset.reviewCardState;
  }

  busy() {
    return document.getElementById(FRAME_ID)?.hasAttribute("aria-busy");
  }

  visible(elements) {
    return [...elements].filter((element) => element.offsetParent);
  }

  flash(messageKey) {
    if (!this.hasFeedbackTarget) return;

    this.feedbackTarget.textContent = this.messagesValue[messageKey] || "";
    clearTimeout(this.feedbackTimer);
    this.feedbackTimer = setTimeout(() => {
      if (this.hasFeedbackTarget) this.feedbackTarget.textContent = "";
    }, FEEDBACK_DURATION);
  }
}
