# A page's h1 with its pills and an optional subtitle on the left, and the
# page's actions on the right. On a narrow screen the actions wrap below.
#
#   <%= render DS::PageHeader.new(title: t(".title"), subtitle: t(".subtitle"), preview: true) do |header| %>
#     <% header.with_status { review_status_pill(status) } %>
#     <% header.with_action { render DS::Link.new(...) } %>
#   <% end %>
class DS::PageHeader < DesignSystemComponent
  SIZES = { lg: "text-2xl", md: "text-xl" }.freeze

  renders_one :status
  renders_many :actions

  attr_reader :title, :subtitle, :preview, :size, :opts

  # @param title [String] the page's h1
  # @param subtitle [String, nil] a line under the title, such as the period
  # @param preview [Boolean] mark a preview feature with the Preview pill
  # @param size [Symbol] :lg, or :md for a working page whose content should
  #   start higher, such as a card the user steps through. A long :md title
  #   truncates; a long :lg one wraps.
  # @param opts [Hash] attributes of the header, such as a bottom margin
  def initialize(title:, subtitle: nil, preview: false, size: :lg, **opts)
    raise ArgumentError, "size: must be one of #{SIZES.keys.join(", ")}" unless SIZES.key?(size)

    @title = title
    @subtitle = subtitle
    @preview = preview
    @size = size
    @opts = opts
  end

  # A header with a subtitle is two lines tall, so its actions line up with
  # the title rather than between the lines.
  def container_classes
    class_names("flex flex-wrap justify-between gap-3", subtitle.present? ? "items-start" : "items-center", opts[:class])
  end

  def container_opts
    opts.except(:class)
  end

  def title_classes
    class_names(SIZES.fetch(size), "font-semibold text-primary", truncate: size == :md)
  end
end
