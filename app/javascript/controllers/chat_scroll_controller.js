import { Controller } from "@hotwired/stimulus"

const PIN_THRESHOLD = 64 // px from bottom under which we consider "pinned"

// Messenger-standard scroll anchoring for the chat messages pane.
// Pinned-to-bottom by default (including as broadcasts append messages);
// a deliberate scroll-up is remembered per-chat in sessionStorage and
// restored across page hops / re-mounts.
export default class extends Controller {
  static values = { chatId: String }

  connect() {
    this.onScroll = this.handleScroll.bind(this)
    this.element.addEventListener("scroll", this.onScroll, { passive: true })
    this.observer = new MutationObserver(() => this.handleAppend())
    this.observer.observe(this.element, { childList: true, subtree: true })
    this.restore()
  }

  disconnect() {
    this.element.removeEventListener("scroll", this.onScroll)
    this.observer?.disconnect()
  }

  restore() {
    const state = this.readState()
    if (state && !state.pinned) {
      this.element.scrollTop = state.top
    } else {
      this.scrollToBottom()
    }
  }

  handleAppend() {
    const state = this.readState()
    if (!state || state.pinned) this.scrollToBottom()
  }

  handleScroll() {
    clearTimeout(this.persistTimer)
    this.persistTimer = setTimeout(() => {
      const distance = this.element.scrollHeight - this.element.scrollTop - this.element.clientHeight
      this.writeState({ pinned: distance <= PIN_THRESHOLD, top: this.element.scrollTop })
    }, 150)
  }

  scrollToBottom() {
    this.element.scrollTop = this.element.scrollHeight
    this.writeState({ pinned: true, top: this.element.scrollTop })
  }

  storageKey() { return `chat-scroll:${this.chatIdValue}` }

  readState() {
    try { return JSON.parse(sessionStorage.getItem(this.storageKey())) } catch { return null }
  }

  writeState(state) {
    try { sessionStorage.setItem(this.storageKey(), JSON.stringify(state)) } catch { /* storage unavailable — degrade to always-pin */ }
  }
}
