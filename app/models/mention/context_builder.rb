class Mention::ContextBuilder
  def initialize(message, family)
    @message = message
    @family = family
  end

  def context
    resolved = Mention::Parser.new(@message.content).resolve(@family)
    return "" if resolved.empty?

    lines = resolved.map { |m| line_for(m[:type], m[:record]) }
    "\n\n[Mentioned entities]\n#{lines.join("\n")}"
  end

  private
    def line_for(type, record)
      case type
      when "category"
        parent = record.parent&.name || "none"
        children = record.subcategories.map(&:name).join(", ").presence || "none"
        %(- category "#{record.name}" id=#{record.id} parent=#{parent} children=#{children})
      when "account"
        %(- account "#{record.name}" id=#{record.id} type=#{record.accountable_type} balance=#{record.balance_money.format})
      when "merchant"
        %(- merchant "#{record.name}" id=#{record.id})
      when "tag"
        %(- tag "#{record.name}" id=#{record.id})
      end
    end
end
