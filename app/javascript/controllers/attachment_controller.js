import { Controller } from "@hotwired/stimulus";
import { DirectUpload } from "@rails/activestorage";

// Composer attachments: click-to-pick, drag-drop, paste. Direct-uploads each
// file, renders a pending chip, and injects hidden inputs with signed blob ids
// so MessagesController receives message[attachments][].
export default class extends Controller {
  static targets = ["fileInput", "pending"];
  static values = { url: String }; // rails_direct_uploads_url

  connect() {
    this.inflight = 0;
    this.handleKeydown = this.handleKeydown.bind(this);
    this.inputTarget?.addEventListener("keydown", this.handleKeydown, {
      capture: true,
    });
  }

  disconnect() {
    this.inputTarget?.removeEventListener("keydown", this.handleKeydown, {
      capture: true,
    });
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
        input.name = "message[attachments][]";
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

  updateSubmitState() {
    const submit = this.element.querySelector("[data-chat-target='submit']");
    if (!submit) return;
    if (this.inflight > 0) {
      submit.disabled = true;
      submit.title = this.uploadingWaitLabel;
    } else {
      submit.disabled = false;
      submit.removeAttribute("title");
    }
  }

  handleKeydown(event) {
    if (this.inflight > 0 && event.key === "Enter" && !event.shiftKey) {
      event.preventDefault();
      event.stopImmediatePropagation();
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
