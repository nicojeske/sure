class Provider::Anthropic::AnnotationSuggester
  include Provider::Anthropic::Concerns::UsageRecorder
  include Provider::Anthropic::Concerns::StructuredOutput

  TOOL_NAME = "report_transaction_annotation".freeze

  attr_reader :client, :model, :prompt, :langfuse_trace, :family

  def initialize(client, model:, prompt:, langfuse_trace: nil, family: nil)
    @client = client
    @model = model
    @prompt = prompt
    @langfuse_trace = langfuse_trace
    @family = family
  end

  def suggest
    span = langfuse_trace&.generation(name: "suggest_transaction_annotation_api_call", model: model, input: prompt.usage_metadata)

    response = create_structured_message(
      tool_name: TOOL_NAME,
      operation: "suggest_transaction_annotation",
      model: model,
      max_tokens: ENV.fetch("ANTHROPIC_MAX_TOKENS", 4096).to_i,
      system_: Provider::Anthropic.structured_output_system(instructions, model, TOOL_NAME),
      messages: [ { role: "user", content: prompt.user_message } ],
      tools: [ output_tool ],
      tool_choice: Provider::Anthropic.structured_output_tool_choice(model, TOOL_NAME)
    )

    result = Provider::TransactionAnnotationPrompt.annotation_from(extract_input(response))

    record_usage(model, response.usage, operation: "suggest_transaction_annotation", metadata: prompt.usage_metadata)

    span&.end(output: result.to_h, usage: usage_hash(response.usage))
    result
  rescue => e
    span&.end(output: { error: e.message }, level: "ERROR")
    record_usage_error(model, operation: "suggest_transaction_annotation", error: e, metadata: prompt.usage_metadata)
    raise
  end

  private
    def instructions
      "#{prompt.rules}\n\nReport the proposal via the #{TOOL_NAME} tool."
    end

    def output_tool
      nullable_string = { type: [ "string", "null" ] }
      nullable_number = { type: [ "number", "null" ] }
      tag_list = { type: "array", items: { type: "string" } }

      {
        name: TOOL_NAME,
        description: "Report the proposed annotation for the transaction.",
        input_schema: {
          type: "object",
          properties: {
            name: nullable_string,
            merchant_name: nullable_string,
            category_name: nullable_string,
            tag_names: tag_list,
            notes: nullable_string,
            receipt_total: nullable_number,
            split: {
              type: [ "array", "null" ],
              items: {
                type: "object",
                properties: {
                  name: { type: "string" },
                  amount: { type: "number" },
                  category_name: nullable_string,
                  tag_names: tag_list,
                  notes: nullable_string
                },
                required: %w[name amount category_name tag_names notes],
                additionalProperties: false
              }
            },
            confidence: nullable_number,
            rationale: nullable_string
          },
          required: Provider::TransactionAnnotationPrompt::OUTPUT_KEYS,
          additionalProperties: false
        }
      }
    end

    def extract_input(response)
      tool_use = Array(response.content).find { |block| structured_block_type(block) == :tool_use }
      raise Provider::Anthropic::Error, "Model did not invoke #{TOOL_NAME} (stop_reason: #{response.stop_reason})" unless tool_use

      input = structured_block_input(tool_use)
      input = JSON.parse(input) if input.is_a?(String)
      input.is_a?(Hash) ? input.stringify_keys : {}
    end
end
