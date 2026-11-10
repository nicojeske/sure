class InsetComponentPreview < ViewComponent::Preview
  RECEIPT = ([ "BEAN BAR", "Flat white        4,80" ] + (1..30).map { |line| "Item #{line}            0,10" } + [ "SUMME EUR         7,80" ]).join("\n")

  # @param text_size select ["sm", "xs"]
  # @display container_classes max-w-[480px]
  def default(text_size: "sm")
    render DS::Inset.new(text_size: text_size.to_sym) do
      "Couldn't read the receipt text. Try again later."
    end
  end

  # A status line with an icon; layout comes in through class:.
  # @display container_classes max-w-[480px]
  def status
    render_with_template
  end

  # Height-capped and scrolling, focusable from the keyboard.
  # @display container_classes max-w-[480px]
  def scrolling
    render DS::Inset.new(scroll_label: "Receipt text", class: "max-h-48") do
      content_tag(:pre, RECEIPT, class: "whitespace-pre-wrap break-words font-mono text-xs text-primary")
    end
  end
end
