class Provider::Openai::AnnotationSuggester
  include Provider::Openai::Concerns::UsageRecorder

  attr_reader :client, :model, :prompt, :custom_provider, :langfuse_trace, :family

  def initialize(client, model:, prompt:, custom_provider: false, langfuse_trace: nil, family: nil)
    @client = client
    @model = model
    @prompt = prompt
    @custom_provider = custom_provider
    @langfuse_trace = langfuse_trace
    @family = family
  end

  # json_object first, then no format constraint for OpenAI-compatible hosts
  # that reject it (same fallback as BillSetupSuggester).
  def suggest
    suggest_with_format({ type: "json_object" })
  rescue Faraday::BadRequestError => e
    Rails.logger.warn("json_object mode failed for transaction annotation, retrying without: #{e.message}")
    suggest_with_format(nil)
  end

  private
    def suggest_with_format(response_format)
      span = langfuse_trace&.generation(name: "suggest_transaction_annotation_api_call", model: model, input: usage_metadata)

      params = {
        model: model,
        messages: [
          { role: "system", content: instructions },
          { role: "user", content: prompt.user_message }
        ]
      }
      params[:response_format] = response_format if response_format

      response = client.chat(parameters: params)
      result = Provider::TransactionAnnotationPrompt.annotation_from(parse_json_flexibly(response.dig("choices", 0, "message", "content")))

      record_usage(model, response.dig("usage"), operation: "suggest_transaction_annotation", metadata: usage_metadata)

      span&.end(output: result.to_h, usage: response.dig("usage"))
      result
    rescue => e
      span&.end(output: { error: e.message }, level: "ERROR")
      raise
    end

    def usage_metadata
      { receipt: prompt.receipt_text.present?, hint: prompt.hint.present?, example_count: prompt.examples.size }
    end

    def instructions
      <<~INSTRUCTIONS.strip
        #{prompt.rules}

        Output JSON only, exactly this shape (no markdown, no explanation):
        {"name": ..., "merchant_name": ..., "category_name": ..., "tag_names": [...], "notes": ...,
         "receipt_total": ..., "split": null or [{"name": ..., "amount": ..., "category_name": ...,
         "tag_names": [...], "notes": ...}], "confidence": ..., "rationale": ...}
      INSTRUCTIONS
    end

    # LLM output may wrap JSON in markdown fences or thinking tags.
    def parse_json_flexibly(raw)
      raise Provider::Openai::Error, "No message content in response" if raw.blank?

      cleaned = raw.include?("</think>") ? raw.split("</think>").last : raw

      begin
        JSON.parse(cleaned)
      rescue JSON::ParserError
        if cleaned =~ /```(?:json)?\s*(\{[\s\S]*\})\s*```/m
          JSON.parse(Regexp.last_match(1))
        elsif cleaned =~ /(\{[\s\S]*\})/m
          JSON.parse(Regexp.last_match(1))
        else
          raise Provider::Openai::Error, "Could not parse JSON from response: #{raw.truncate(200)}"
        end
      end
    end
end
