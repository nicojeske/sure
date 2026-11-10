# Borderless inset box on a card: a status line ("Reading the receipt…"), a
# short notice, or a scrolling block of text such as a receipt. Use DS::Note
# for standing explanatory copy, which gets a border and a title, and
# DS::Alert for something that just became true.
#
#   <%= render DS::Inset.new(text_size: :xs, class: "flex items-center gap-2") do %>
#     <%= icon "loader-circle", size: "sm", class: "animate-spin" %> <%= t(".loading") %>
#   <% end %>
#
# Layout (flex, gap, visibility) and a height cap come in through `class:`;
# other options become attributes of the box.
class DS::Inset < DesignSystemComponent
  TAGS = %i[div p].freeze
  TEXT_SIZES = { sm: "text-sm", xs: "text-xs" }.freeze

  attr_reader :tag_name, :text_size, :scroll_label, :opts

  # @param tag [Symbol] :div, or :p for a box that holds only a sentence
  # @param text_size [Symbol] :sm, or :xs for a box beside small print
  # @param scroll_label [String, nil] makes the box scroll when its content
  #   overflows a height cap passed in `class:`, and lets keyboard users focus
  #   it to scroll; the label names it for screen readers
  def initialize(tag: :div, text_size: :sm, scroll_label: nil, **opts)
    raise ArgumentError, "tag: must be one of #{TAGS.join(", ")}" unless TAGS.include?(tag)

    @tag_name = tag
    @text_size = TEXT_SIZES.fetch(text_size)
    @scroll_label = scroll_label
    @opts = opts
  end

  def call
    content_tag(tag_name, content, class: classes, **html_options)
  end

  private
    def classes
      class_names("rounded-lg bg-container-inset p-3 text-secondary", text_size, opts[:class], "overflow-auto": scroll_label)
    end

    def html_options
      options = opts.except(:class)
      return options unless scroll_label

      options.deep_merge(tabindex: 0, aria: { label: scroll_label })
    end
end
