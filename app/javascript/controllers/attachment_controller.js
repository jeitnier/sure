import { Controller } from "@hotwired/stimulus";
import { DirectUpload } from "@rails/activestorage";

// Composer attachments: click-to-pick, drag-drop, paste. Direct-uploads each
// file, renders a pending chip, and injects hidden inputs with signed blob ids
// so MessagesController receives message[attachments][].
//
// Ownership rule: chat_controller owns `submit.disabled`. This controller only
// (a) forces disabled=true while uploads are in flight, via the shared
// `data-uploads-inflight` flag on this.element (the #chat-form wrapper), and
// (b) pokes chat_controller to recompute once uploads finish by dispatching an
// `input` event on the textarea. chat_controller reads the same flag before
// submitting on Enter and before (re)computing disabled, so there is a single
// source of truth instead of two controllers racing to set `disabled`.
export default class extends Controller {
  static targets = ["fileInput", "pending"];
  static values = { url: String }; // rails_direct_uploads_url

  connect() {
    this.inflight = 0;
  }

  pick() {
    this.fileInputTarget.click();
  }

  filesChosen() {
    this.upload(Array.from(this.fileInputTarget.files));
    this.fileInputTarget.value = "";
  }

  // action on the form wrapper: dragover->attachment#dragover drop->attachment#drop paste->attachment#paste
  dragover(e) {
    e.preventDefault();
  }

  drop(e) {
    e.preventDefault();
    this.upload(Array.from(e.dataTransfer.files));
  }

  paste(e) {
    const files = Array.from(e.clipboardData?.files || []);
    if (files.length) {
      e.preventDefault();
      this.upload(files);
    }
  }

  upload(files) {
    for (const file of files) {
      const chip = this.renderChip(file);
      this.inflight += 1;
      this.updateSubmitState();
      new DirectUpload(file, this.urlValue).create((error, blob) => {
        if (error) {
          chip.querySelector("[data-status]").textContent =
            chip.dataset.errorLabel;
          this.inflight -= 1;
          this.updateSubmitState();
          return;
        }
        chip.dataset.signedId = blob.signed_id;
        chip.querySelector("[data-status]").remove();
        const input = document.createElement("input");
        input.type = "hidden";
        // The composer renders under two form scopes: `message` mid-chat
        // (messages#create) and `chat` on the new-chat page (chats#create ->
        // Chat.start!). Derive the scope from a sibling field so the signed
        // id lands under whichever param root the controller actually reads
        // — hardcoding message[...] silently dropped first-message uploads.
        const scoped = chip
          .closest("form")
          ?.querySelector('[name$="[ai_model]"]');
        const scope = scoped
          ? scoped.name.slice(0, -"[ai_model]".length)
          : "message";
        input.name = `${scope}[attachments][]`;
        input.value = blob.signed_id;
        chip.appendChild(input);
        this.inflight -= 1;
        this.updateSubmitState();
      });
    }
  }

  renderChip(file) {
    const chip = document.createElement("div");
    chip.dataset.chip = "";
    chip.dataset.errorLabel =
      this.element.dataset.attachmentErrorLabel || "failed";
    chip.className =
      "flex items-center gap-1.5 px-2 py-1 rounded-md bg-surface-inset text-xs";
    chip.innerHTML = `<span>${this.escape(file.name)}</span><span data-status class="text-secondary">${this.uploadingLabel}</span>
      <button type="button" class="cursor-pointer text-secondary" aria-label="${this.removeLabel}">&times;</button>`;
    chip.querySelector("button").addEventListener("click", () => chip.remove());
    this.pendingTarget.appendChild(chip);
    return chip;
  }

  // action: turbo:submit-end->attachment#clear (clears pending chips after a
  // successful send only — a failed submission (e.g. validation error) must
  // preserve the user's staged uploads so they aren't silently lost)
  clear(event) {
    if (event?.detail && event.detail.success === false) return;
    this.pendingTarget.innerHTML = "";
  }

  // Maintains the shared `data-uploads-inflight` flag on this.element
  // (#chat-form) and forces the submit button's disabled state while uploads
  // are in flight. chat_controller reads the flag directly for its own
  // Enter-to-submit and disabled-state logic; when uploads finish here we
  // dispatch an `input` event so chat_controller immediately recomputes
  // (rather than only owning disabled while inflight, then leaving it stuck).
  updateSubmitState() {
    const submit = this.element.querySelector("[data-chat-target='submit']");

    if (this.inflight > 0) {
      this.element.dataset.uploadsInflight = "true";
      if (submit) {
        submit.disabled = true;
        submit.title = this.uploadingWaitLabel;
      }
    } else {
      delete this.element.dataset.uploadsInflight;
      if (submit) submit.removeAttribute("title");
      this.inputTarget?.dispatchEvent(new Event("input", { bubbles: true }));
    }
  }

  get inputTarget() {
    return this.element.querySelector("[data-chat-target='input']");
  }

  escape(s) {
    const d = document.createElement("div");
    d.textContent = s;
    return d.innerHTML;
  }

  get uploadingLabel() {
    return this.element.dataset.attachmentUploadingLabel || "…";
  }

  get removeLabel() {
    return this.element.dataset.attachmentRemoveLabel || "remove";
  }

  get uploadingWaitLabel() {
    return (
      this.element.dataset.attachmentUploadingWaitLabel ||
      "Please wait for uploads to finish"
    );
  }
}
