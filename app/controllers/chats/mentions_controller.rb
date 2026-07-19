class Chats::MentionsController < ApplicationController
  guard_feature unless: -> { Current.user.ai_enabled? }

  LIMIT = 5

  def index
    q = params[:q].to_s.strip
    like = "%#{ActiveRecord::Base.sanitize_sql_like(q)}%"
    family = Current.family

    render json: {
      accounts:   family.accounts.where("accounts.name ILIKE ?", like).limit(LIMIT).map { |r| { id: r.id, label: r.name } },
      categories: family.categories.where("categories.name ILIKE ?", like).limit(LIMIT).map { |r| { id: r.id, label: r.name } },
      merchants:  mention_merchants(family, like),
      tags:       family.tags.where("tags.name ILIKE ?", like).limit(LIMIT).map { |r| { id: r.id, label: r.name } }
    }
  end

  private
    # Mirrors AssistantProposal::Resolver#family_merchants exactly (app/models/assistant_proposal/resolver.rb)
    # so mentionable merchants == proposable merchants.
    def mention_merchants(family, like)
      Merchant.where(id: family.merchants.select(:id)).or(Merchant.where(id: family.assigned_merchants.select(:id)))
              .where("merchants.name ILIKE ?", like).limit(LIMIT).map { |r| { id: r.id, label: r.name } }
    end
end
