require "test_helper"

class Provider::Openai::BillSetupSuggesterTest < ActiveSupport::TestCase
  test "asks for the bill name in the content language" do
    content = { name: "Fitnessstudio", amount: 40, frequency: "monthly" }.to_json
    client = mock
    client.expects(:chat).with do |parameters:|
      assert_match(/name: .*language of locale "de"/, parameters[:messages].first[:content].squish)
      true
    end.returns({ "choices" => [ { "message" => { "content" => content } } ], "usage" => nil })

    result = Provider::Openai::BillSetupSuggester.new(
      client, model: "gpt-4.1", charges: [ { date: "2026-10-03", amount: "40", name: "GYM" } ],
      categories: [], content_locale: "de"
    ).suggest

    assert_equal "Fitnessstudio", result.name
  end
end
