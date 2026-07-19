module MessagesHelper
  # Renders user-message content through the standard markdown pipeline while
  # displaying mention tokens as chips. Tokens are swapped for opaque
  # placeholders BEFORE markdown (so Redcarpet can't mangle them — a raw
  # token like "@[Groceries](category:uuid)" is syntactically a markdown
  # link), then the placeholders are replaced with chip spans in the
  # rendered HTML. Raw HTML in user input is neutralized via
  # markdown(escape_html: true) since this content is untrusted, unlike
  # assistant message content which still calls markdown() with its default.
  def render_message_content(text)
    placeholders = {}
    masked = text.to_s.gsub(Mention::Parser::TOKEN_REGEX) do
      label = Regexp.last_match(1)
      key = "MENTIONCHIP#{SecureRandom.hex(6)}"
      placeholders[key] = %(<span class="inline-flex items-center px-1.5 py-0.5 rounded-md bg-surface-inset text-xs font-medium">@#{ERB::Util.html_escape(label)}</span>)
      key
    end
    html = markdown(masked, escape_html: true)
    placeholders.each { |key, chip| html = html.gsub(key, chip) }
    html.html_safe
  end
end
