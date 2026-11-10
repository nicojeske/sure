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

  test "asks for a rule proposal in the JSON shape and parses it" do
    content = {
      "name" => "Strom", "rule_proposal" => {
        "conditions" => [ { "field" => "name", "operator" => "like", "value" => "EON" }, "junk", { "field" => "name" } ],
        "actions" => [ { "field" => "category", "value" => "Strom" }, { "field" => "tags", "value" => "Fixed" } ]
      }
    }.to_json
    client = mock
    client.expects(:chat).with do |parameters:|
      instructions = parameters[:messages].first[:content]
      assert_includes instructions, '"rule_proposal": null or {"conditions"'
      assert_includes instructions, "never notes"
      true
    end.returns({ "choices" => [ { "message" => { "content" => content } } ], "usage" => nil })

    result = Provider::Openai::AnnotationSuggester.new(client, model: "gpt-4.1", prompt: prompt).suggest

    assert_equal [ { "field" => "name", "operator" => "like", "value" => "EON" } ], result.rule_proposal.conditions
    assert_equal [ { "field" => "category", "value" => "Strom" }, { "field" => "tags", "value" => [ "Fixed" ] } ], result.rule_proposal.actions
  end

  test "a missing or empty rule proposal parses to nil" do
    assert_nil Provider::TransactionAnnotationPrompt.annotation_from({}).rule_proposal
    assert_nil Provider::TransactionAnnotationPrompt.annotation_from("rule_proposal" => { "conditions" => [], "actions" => [] }).rule_proposal
    assert_nil Provider::TransactionAnnotationPrompt.annotation_from("rule_proposal" => "yes").rule_proposal
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
