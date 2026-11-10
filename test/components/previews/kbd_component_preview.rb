class KbdComponentPreview < ViewComponent::Preview
  # @param key text
  def default(key: "o")
    render DS::Kbd.new(key: key)
  end

  # A row of shortcut hints, as under the monthly review card.
  def shortcut_hints
    hints = [ [ "⏎", "accept" ], [ "Esc", "skip" ], [ "Alt+←", "back" ], [ "1–5", "fields" ] ]
    render_with_template(locals: { hints: hints })
  end
end
