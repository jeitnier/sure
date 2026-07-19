import { Controller } from "@hotwired/stimulus";

// @-mention typeahead for the chat composer. Attach to the form wrapper:
//   data-controller="mention" data-mention-url-value="/chats/mentions"
// Targets: input (the textarea), menu (popover), list (ul inside menu)
export default class extends Controller {
  static targets = ["input", "menu", "list"];
  static values = { url: String, labels: Object };

  connect() {
    this.active = false;
    this.selectedIndex = 0;
    // Defensive: never start with a stale flag left behind (e.g. a prior
    // instance was torn down mid-popover).
    delete this.element.dataset.mentionMenuOpen;
  }

  disconnect() {
    delete this.element.dataset.mentionMenuOpen;
  }

  // action: input->mention#onInput keydown->mention#onKeydown on the textarea
  onInput() {
    const caret = this.inputTarget.selectionStart;
    const upToCaret = this.inputTarget.value.slice(0, caret);
    const match = upToCaret.match(/(^|\s)@(\w{0,30})$/);
    if (!match) return this.close();
    this.query = match[2];
    this.triggerStart = caret - this.query.length - 1;
    this.search();
  }

  onKeydown(event) {
    if (!this.active) return;
    if (event.key === "Escape") {
      event.preventDefault();
      this.close();
    }
    if (event.key === "ArrowDown") {
      event.preventDefault();
      this.move(1);
    }
    if (event.key === "ArrowUp") {
      event.preventDefault();
      this.move(-1);
    }
    if (event.key === "Enter") {
      event.preventDefault();
      this.chooseSelected();
    }
  }

  async search() {
    clearTimeout(this.debounce);
    this.debounce = setTimeout(async () => {
      const resp = await fetch(
        `${this.urlValue}?q=${encodeURIComponent(this.query)}`,
        { headers: { Accept: "application/json" } },
      );
      if (!resp.ok) return this.close();
      this.render(await resp.json());
    }, 150);
  }

  render(groups) {
    const entries = [];
    for (const [type, items] of [
      ["account", groups.accounts],
      ["category", groups.categories],
      ["merchant", groups.merchants],
      ["tag", groups.tags],
    ]) {
      for (const item of items || []) entries.push({ type, ...item });
    }
    this.entries = entries;
    this.selectedIndex = 0;
    this.listTarget.innerHTML =
      entries.length === 0
        ? `<li class="px-3 py-1.5 text-sm text-secondary">${this.escape(this.labelsValue.empty)}</li>`
        : entries
            .map(
              (e, i) =>
                `<li class="px-3 py-1.5 text-sm cursor-pointer rounded-md ${i === 0 ? "bg-surface-inset" : ""}" data-index="${i}" data-action="click->mention#choose">
         <span class="text-secondary text-xs uppercase mr-2">${this.escape(this.labelsValue[e.type])}</span>${this.escape(e.label)}
       </li>`,
            )
            .join("");
    this.menuTarget.classList.remove("hidden");
    this.active = true;
    // Single source of truth read by chat_controller#handleInputKeyDown so
    // Enter-to-submit and Enter-to-select-mention never race each other. See
    // the ownership-rule comment atop attachment_controller.js for the
    // pattern this mirrors (data-uploads-inflight).
    this.element.dataset.mentionMenuOpen = "true";
  }

  move(delta) {
    if (!this.entries || this.entries.length === 0) return;
    this.selectedIndex =
      (this.selectedIndex + delta + this.entries.length) % this.entries.length;
    this.listTarget
      .querySelectorAll("li")
      .forEach((li, i) =>
        li.classList.toggle("bg-surface-inset", i === this.selectedIndex),
      );
  }

  choose(event) {
    this.insert(this.entries[Number(event.currentTarget.dataset.index)]);
  }
  chooseSelected() {
    if (!this.entries || this.entries.length === 0) return;
    this.insert(this.entries[this.selectedIndex]);
  }

  insert(entry) {
    const token = `@[${entry.label}](${entry.type}:${entry.id}) `;
    const value = this.inputTarget.value;
    const caret = this.inputTarget.selectionStart;
    this.inputTarget.value =
      value.slice(0, this.triggerStart) + token + value.slice(caret);
    const newCaret = this.triggerStart + token.length;
    this.inputTarget.setSelectionRange(newCaret, newCaret);
    this.inputTarget.dispatchEvent(new Event("input")); // autoResize etc.
    this.inputTarget.focus();
    this.close();
  }

  // action for the at-sign button: click->mention#trigger
  trigger() {
    const caret =
      this.inputTarget.selectionStart ?? this.inputTarget.value.length;
    this.inputTarget.value = `${this.inputTarget.value.slice(0, caret)}@${this.inputTarget.value.slice(caret)}`;
    this.inputTarget.setSelectionRange(caret + 1, caret + 1);
    this.inputTarget.focus();
    this.onInput();
  }

  close() {
    this.active = false;
    this.menuTarget?.classList.add("hidden");
    delete this.element.dataset.mentionMenuOpen;
  }

  escape(s) {
    const d = document.createElement("div");
    d.textContent = s;
    return d.innerHTML;
  }
}
