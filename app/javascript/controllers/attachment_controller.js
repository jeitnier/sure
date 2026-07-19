import { Controller } from "@hotwired/stimulus";
import { DirectUpload } from "@rails/activestorage";

// Composer attachments: click-to-pick, drag-drop, paste. Direct-uploads each
// file, renders a pending chip, and injects hidden inputs with signed blob ids
// so MessagesController receives message[attachments][].
export default class extends Controller {
  static targets = ["fileInput", "pending", "form"];
  static values = { url: String }; // rails_direct_uploads_url

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
      new DirectUpload(file, this.urlValue).create((error, blob) => {
        if (error) {
          chip.querySelector("[data-status]").textContent =
            chip.dataset.errorLabel;
          return;
        }
        chip.dataset.signedId = blob.signed_id;
        chip.querySelector("[data-status]").remove();
        const input = document.createElement("input");
        input.type = "hidden";
        input.name = "message[attachments][]";
        input.value = blob.signed_id;
        chip.appendChild(input);
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

  clear() {
    this.pendingTarget.innerHTML = "";
  } // action: turbo:submit-end->attachment#clear (clears pending chips after send)

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
}
