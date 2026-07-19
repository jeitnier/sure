class Assistant::Function
  class << self
    def name
      raise NotImplementedError, "Subclasses must implement the name class method"
    end

    def description
      raise NotImplementedError, "Subclasses must implement the description class method"
    end
  end

  def initialize(user, chat: nil)
    @user = user
    @chat = chat
  end

  def call(params = {})
    raise NotImplementedError, "Subclasses must implement the call method"
  end

  def name
    self.class.name
  end

  def description
    self.class.description
  end

  def params_schema
    build_schema
  end

  # (preferred) when in strict mode, the schema needs to include all properties in required array
  def strict_mode?
    true
  end

  def to_definition
    {
      name: name,
      description: description,
      params_schema: params_schema,
      strict: strict_mode?
    }
  end

  private
    attr_reader :user, :chat

    def build_schema(properties: {}, required: [])
      {
        type: "object",
        properties: properties,
        required: required,
        additionalProperties: false
      }
    end

    def family_account_names
      @family_account_names ||= user.accessible_accounts.visible.pluck(:name)
    end

    def family_category_names
      @family_category_names ||= begin
        names = family.categories.pluck(:name)
        names << "Uncategorized"
        names
      end
    end

    def family_merchant_names
      @family_merchant_names ||= family.merchants.pluck(:name)
    end

    def family_tag_names
      @family_tag_names ||= family.tags.pluck(:name)
    end

    def family
      user.family
    end

    def error(key, message)
      { success: false, error: key, message: message }
    end

    # Shared by the propose_* functions: validates + stages an AssistantProposal
    # (never applies anything — apply/undo happen elsewhere via the domain ops).
    def create_proposal(kind:, params:)
      return error("no_chat", "Proposals require an active chat context.") unless chat

      resolver = AssistantProposal::Resolver.new(family: family, kind: kind, params: params)
      if resolver.over_cap?
        return error("over_cap",
          "This would affect #{resolver.affected_ids.size} records (max #{AssistantProposal.max_records}). Narrow the filter and try again.")
      end
      preview = resolver.build_preview
      return error("empty", "No records match \u2014 nothing to propose.") if preview["count"].zero?

      proposal = AssistantProposal.create!(
        family: family, chat: chat, kind: kind,
        params: params, preview: preview, status: "proposed"
      )
      proposal.broadcast_card_append

      { success: true, proposal_id: proposal.id, count: preview["count"],
        breakdown: preview["breakdown"], notes: preview["notes"],
        message: "Proposal staged \u2014 the user must click Apply on the card to execute." }
    rescue AssistantProposal::Resolver::InvalidParams => e
      error("invalid_params", e.message)
    end

    def valid_uuid?(str)
      UuidFormat.valid?(str)
    end

    # To save tokens, we provide the AI metadata about the series and a flat array of
    # raw, formatted values which it can infer dates from
    def to_ai_time_series(series)
      {
        start_date: series.start_date,
        end_date: series.end_date,
        interval: series.interval,
        values: series.values.map { |v| v.trend.current.format }
      }
    end
end
