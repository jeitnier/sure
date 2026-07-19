class Mention::Parser
  TYPES = %w[account category merchant tag].freeze
  TOKEN_REGEX = /@\[([^\]]+)\]\((account|category|merchant|tag):([0-9a-f\-]+)\)/

  def initialize(content)
    @content = content.to_s
  end

  def tokens
    @tokens ||= @content.scan(TOKEN_REGEX).map do |label, type, id|
      { label: label, type: type, id: id }
    end
  end

  def resolve(family)
    tokens.filter_map do |token|
      record = lookup(family, token[:type], token[:id])
      { type: token[:type], record: record, label: token[:label] } if record
    end
  end

  private
    def lookup(family, type, id)
      case type
      when "account"  then family.accounts.find_by(id: id)
      when "category" then family.categories.find_by(id: id)
      when "merchant" then family_merchants(family).find_by(id: id)
      when "tag"      then family.tags.find_by(id: id)
      end
    rescue ActiveRecord::StatementInvalid
      nil # malformed uuid cast on some adapters — treat as unresolvable
    end

    # Mirrors AssistantProposal::Resolver#family_merchants exactly (app/models/assistant_proposal/resolver.rb)
    # so mentionable merchants == proposable merchants.
    def family_merchants(family)
      Merchant.where(id: family.merchants.select(:id)).or(Merchant.where(id: family.assigned_merchants.select(:id)))
    end
end
