module MessagesHelper
  # Replaces mention tokens with styled chips in rendered user messages.
  # Escapes surrounding content first so only our chip markup is HTML.
  def render_mention_chips(text)
    escaped = ERB::Util.html_escape(text.to_s)
    safe = escaped.gsub(Mention::Parser::TOKEN_REGEX) do
      label = ERB::Util.html_escape(Regexp.last_match(1))
      %(<span class="inline-flex items-center px-1.5 py-0.5 rounded-md bg-surface-inset text-xs font-medium">@#{label}</span>)
    end
    safe.html_safe
  end
end
