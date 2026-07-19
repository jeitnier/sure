import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["form", "input", "submit", "pendingResponse"];
  static values = {
    // How long a pending "Thinking…" bubble may wait before we assume the
    // background worker never delivered a response. Generous so slow models or
    // tool calls don't trip it.
    responseTimeout: { type: Number, default: 90000 },
    // How often to re-check pending bubbles.
    pollInterval: { type: Number, default: 5000 },
  };

  connect() {
    this.reportedUrls = new Set();
    this.inFlightUrls = new Set();
    this.#updateSubmitState();
    this.#startUndeliveredWatchdog();
  }

  disconnect() {
    if (this.watchdogTimer) {
      clearInterval(this.watchdogTimer);
    }
  }

  autoResize() {
    const input = this.inputTarget;
    const lineHeight = 20; // text-sm line-height (14px * 1.429 ≈ 20px)
    const maxLines = 3; // 3 lines = 60px total

    input.style.height = "auto";
    input.style.height = `${Math.min(input.scrollHeight, lineHeight * maxLines)}px`;
    input.style.overflowY =
      input.scrollHeight > lineHeight * maxLines ? "auto" : "hidden";

    this.#updateSubmitState();
  }

  submitSampleQuestion(e) {
    this.inputTarget.value = e.target.dataset.chatQuestionParam;
    this.#updateSubmitState();

    setTimeout(() => {
      this.formTarget.requestSubmit();
    }, 200);
  }

  // Newlines require shift+enter, otherwise submit the form (same functionality as ChatGPT and others)
  handleInputKeyDown(e) {
    if (e.key === "Enter" && !e.shiftKey) {
      // The mention popover owns Enter while it's open (to select the
      // highlighted entry) -- its own keydown handler runs after this one
      // (data-action order: chat#handleInputKeyDown then mention#onKeydown)
      // and calls preventDefault() + selects. If we preventDefault/submit
      // here first, the keystroke never reaches mention_controller and a
      // keyboard-selected mention would submit a junk partial message
      // instead of being inserted. So bail out early, untouched.
      if (this.#mentionMenuOpen()) return;

      e.preventDefault();
      if (this.#hasContent() && !this.#uploadsInflight()) {
        this.formTarget.requestSubmit();
      }
    }
  }

  #hasContent() {
    return this.inputTarget.value.trim().length > 0;
  }

  // Single source of truth for whether an attachment upload is still in
  // flight: attachment_controller (attached to the #chat-form wrapper, a
  // descendant of this controller's element) sets/clears
  // `data-uploads-inflight` on that element. See the ownership-rule comment
  // atop attachment_controller.js — chat_controller owns `disabled`,
  // attachment_controller only forces it true and pokes us to recompute.
  #uploadsInflight() {
    return !!this.element.querySelector("#chat-form")?.dataset.uploadsInflight;
  }

  // Single source of truth for whether the mention popover is open:
  // mention_controller (attached to the #chat-form wrapper, a descendant of
  // this controller's element) sets/clears `data-mention-menu-open` on that
  // element when it opens/closes the popover. Same ownership pattern as
  // `#uploadsInflight()` above.
  #mentionMenuOpen() {
    return !!this.element.querySelector("#chat-form")?.dataset.mentionMenuOpen;
  }

  #updateSubmitState() {
    if (!this.hasSubmitTarget) return;
    this.submitTarget.disabled = !this.#hasContent() || this.#uploadsInflight();
  }

  // Scroll position/anchoring for the messages pane is owned by the
  // chat-scroll Stimulus controller (attached directly to the messages
  // target) so pinned-to-bottom vs. remembered-scroll-position behavior
  // isn't fought over by two observers. See chat_scroll_controller.js.

  // Watchdog: a "Thinking…" bubble only resolves when the background worker
  // streams a response over Turbo. If the worker is down — or the job dies
  // before it can broadcast an error — the bubble would otherwise spin forever
  // with no feedback. We detect a pending bubble that has waited past the
  // threshold and ask the server to mark it failed, so the user gets an error
  // message + Retry instead of a dead spinner.
  //
  // We key off the pending marker itself (it only exists while pending and
  // disappears the instant a real response renders) rather than a status flag,
  // so a response that starts streaming can never be falsely timed out.
  #startUndeliveredWatchdog() {
    this.#checkUndeliveredResponses();
    this.watchdogTimer = setInterval(() => {
      this.#checkUndeliveredResponses();
    }, this.pollIntervalValue);
  }

  #checkUndeliveredResponses() {
    if (!this.hasPendingResponseTarget) return;

    const now = Date.now();

    this.pendingResponseTargets.forEach((el) => {
      const url = el.dataset.pendingResponseTimeoutUrl;
      // Skip if already reported (succeeded) or a report is in flight.
      if (!url || this.reportedUrls.has(url) || this.inFlightUrls.has(url))
        return;

      const createdAt = Date.parse(el.dataset.pendingResponseCreatedAt);
      if (Number.isNaN(createdAt)) return;
      if (now - createdAt < this.responseTimeoutValue) return;

      this.#reportUndelivered(url);
    });
  }

  #reportUndelivered(url) {
    const token = document.querySelector('meta[name="csrf-token"]')?.content;

    this.inFlightUrls.add(url);

    fetch(url, {
      method: "POST",
      headers: {
        "X-CSRF-Token": token || "",
        Accept: "text/vnd.turbo-stream.html, text/html",
      },
      credentials: "same-origin",
    })
      .then((response) => {
        // Only mark as reported on success. fetch resolves on HTTP 4xx/5xx
        // (it rejects only on network errors), so without this check a failed
        // POST would permanently suppress retries and strand the bubble.
        if (response.ok) this.reportedUrls.add(url);
      })
      .catch(() => {
        // Best-effort. Leave the URL un-reported so the next tick can retry.
      })
      .finally(() => {
        this.inFlightUrls.delete(url);
      });
  }
}
