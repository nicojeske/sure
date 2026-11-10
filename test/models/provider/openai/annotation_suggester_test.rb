require "test_helper"

class Provider::Openai::AnnotationSuggesterTest < ActiveSupport::TestCase
  test "parses fenced JSON and coerces wrong types to nil" do
    content = "```json\n{\"name\": \"Lunch\", \"category_name\": \"Food\", \"tag_names\": \"Work\", \"receipt_total\": \"12.5\", \"confidence\": \"high\", \"split\": {}}\n```"
    client = mock
    client.expects(:chat).with do |parameters:|
      assert_equal({ type: "json_object" }, parameters[:response_format])
      assert_includes parameters[:messages].last[:content], "RECEIPT TEXT:\nBurger 12,50"
      true
    end.returns({ "choices" => [ { "message" => { "content" => content } } ], "usage" => nil })

    result = Provider::Openai::AnnotationSuggester.new(client, model: "gpt-4.1", prompt: prompt).suggest

    assert_equal "Lunch", result.name
    assert_equal [ "Work" ], result.tag_names
    assert_equal 12.5, result.receipt_total
    assert_nil result.confidence
    assert_nil result.split
  end

  private
    def prompt
      Provider::TransactionAnnotationPrompt.new(
        transaction: { date: "2026-10-03", amount: "12.50", currency: "EUR", name: "BURGER" },
        receipt_text: "Burger 12,50", hint: nil, examples: [],
        categories: [ "Food" ], merchants: [], tags: [ "Work" ], locale: "en"
      )
    end
end
