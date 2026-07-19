require "test_helper"

class Mention::ParserTest < ActiveSupport::TestCase
  setup do
    @family = users(:family_admin).family
    @category = @family.categories.create!(name: "Groceries", color: "#4da568")
  end

  test "extracts well-formed tokens" do
    content = "move @[Groceries](category:#{@category.id}) and @[Chase](account:11111111-1111-1111-1111-111111111111) please"
    tokens = Mention::Parser.new(content).tokens
    assert_equal 2, tokens.size
    assert_equal({ label: "Groceries", type: "category", id: @category.id }, tokens.first)
  end

  test "malformed and unknown-type tokens are ignored" do
    content = "@[broken](category:) @[weird](wormhole:abc) @[ok](tag:not-a-uuid) plain @text"
    assert_equal [], Mention::Parser.new(content).tokens.select { |t| t[:type] == "wormhole" }
    # not-a-uuid is extracted but will fail resolution; broken (empty id) is not extracted
    assert_equal [], Mention::Parser.new(content).tokens.select { |t| t[:id].blank? }
  end

  test "resolve returns only family-owned existing records" do
    other_family_cat = Category.create!(family: families(:empty), name: "Foreign", color: "#db5a54")
    content = "a @[Groceries](category:#{@category.id}) b @[Foreign](category:#{other_family_cat.id}) c @[Gone](category:11111111-1111-1111-1111-111111111111)"
    resolved = Mention::Parser.new(content).resolve(@family)
    assert_equal 1, resolved.size
    assert_equal @category, resolved.first[:record]
  end
end
