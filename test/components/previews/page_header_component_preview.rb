class PageHeaderComponentPreview < ViewComponent::Preview
  # @param title text
  # @param subtitle text
  # @param preview toggle
  # @param size select ["lg", "md"]
  def default(title: "October 2026", subtitle: "October 1, 2026 – October 31, 2026", preview: true, size: "lg")
    render DS::PageHeader.new(title: title, subtitle: subtitle.presence, preview: preview, size: size.to_sym) do |header|
      header.with_status { render DS::Pill.new(label: "Not started", tone: :neutral, marker: false, icon: "circle") }
      header.with_action { render DS::Link.new(text: "Include transfers", variant: :ghost, size: :sm, icon: "arrow-right-left", href: "#") }
      header.with_action { render DS::Link.new(text: "Start review", variant: :primary, icon: "list-checks", href: "#") }
    end
  end

  # A working page: the smaller title, no subtitle, the actions centred on it.
  def working_page
    render DS::PageHeader.new(title: "Review October 2026", preview: true, size: :md) do |header|
      header.with_action { render DS::Link.new(text: "Summary", variant: :ghost, size: :sm, icon: "clipboard-list", href: "#") }
      header.with_action { render DS::Button.new(text: "Refresh suggestions", variant: :outline, size: :sm, icon: "refresh-cw") }
    end
  end
end
