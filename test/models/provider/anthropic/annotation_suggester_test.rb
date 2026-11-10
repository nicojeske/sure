require "test_helper"
require "ostruct"

class Provider::Anthropic::AnnotationSuggesterTest < ActiveSupport::TestCase
  test "forces the report tool and maps the annotation with its split" do
    messages = mock
    messages.expects(:create).with do |params|
      assert_equal({ type: "tool", name: "report_transaction_annotation", disable_parallel_tool_use: true }, params[:tool_choice])
      assert_includes params[:messages].first[:content], "USER HINT:\nApfelentkerner 12 + Handwärmer 8"
      true
    end.returns(OpenStruct.new(
      id: "msg_test",
      model: "claude-haiku-4-5",
      content: [ OpenStruct.new(type: :tool_use, id: "toolu_1", name: "report_transaction_annotation", input: tool_input) ],
      usage: OpenStruct.new(input_tokens: 100, output_tokens: 50)
    ))
    client = stub(messages: messages)

    result = Provider::Anthropic::AnnotationSuggester.new(client, model: "claude-haiku-4-5", prompt: prompt).suggest

    assert_equal "Apfelentkerner und Handwärmer", result.name
    assert_equal [ "Küche", "Outdoor" ], result.split.map(&:category_name)
    assert_equal [ 12.0, 8.0 ], result.split.map(&:amount)
    assert_equal [], result.tag_names
  end

  test "the report tool accepts an optional rule proposal and maps it" do
    messages = mock
    messages.expects(:create).with do |params|
      schema = params[:tools].first[:input_schema]
      rule = schema[:properties][:rule_proposal]
      assert_includes schema[:required], "rule_proposal"
      assert_equal %w[conditions actions], rule[:properties].keys.map(&:to_s)
      assert_includes params[:system_], "rule_proposal"
      true
    end.returns(OpenStruct.new(
      id: "msg_test", model: "claude-haiku-4-5",
      content: [ OpenStruct.new(type: :tool_use, id: "toolu_1", name: "report_transaction_annotation", input: tool_input.merge(
        "rule_proposal" => {
          "conditions" => [ { "field" => "merchant", "operator" => "=", "value" => "Amazon" } ],
          "actions" => [ { "field" => "category", "value" => "Küche" } ]
        }
      )) ],
      usage: OpenStruct.new(input_tokens: 100, output_tokens: 50)
    ))

    result = Provider::Anthropic::AnnotationSuggester.new(stub(messages: messages), model: "claude-haiku-4-5", prompt: prompt).suggest

    assert_equal [ { "field" => "merchant", "operator" => "=", "value" => "Amazon" } ], result.rule_proposal.conditions
    assert_equal [ { "field" => "category", "value" => "Küche" } ], result.rule_proposal.actions
  end

  private
    def prompt
      Provider::TransactionAnnotationPrompt.new(
        transaction: { date: "2026-10-03", amount: "20.00", currency: "EUR", name: "AMAZON MKTPL" },
        receipt_text: nil, hint: "Apfelentkerner 12 + Handwärmer 8", examples: [],
        categories: [ "Küche", "Outdoor" ], merchants: [ "Amazon" ], tags: [], locale: "de"
      )
    end

    def tool_input
      {
        "name" => "Apfelentkerner und Handwärmer", "merchant_name" => "Amazon", "category_name" => "Küche",
        "tag_names" => [], "notes" => nil, "receipt_total" => nil, "confidence" => 0.8, "rationale" => "Hinweis",
        "split" => [
          { "name" => "Apfelentkerner", "amount" => 12, "category_name" => "Küche", "tag_names" => [], "notes" => nil },
          { "name" => "Handwärmer", "amount" => 8, "category_name" => "Outdoor", "tag_names" => [], "notes" => nil }
        ]
      }
    end
end
