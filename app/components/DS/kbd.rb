# Key cap for a keyboard shortcut hint, such as "o open" or "Esc skip". The
# key is shown as given, so translate names like "Esc" before passing them.
#
#   <%= render DS::Kbd.new(key: "o") %> <%= t(".open") %>
class DS::Kbd < DesignSystemComponent
  attr_reader :key

  def initialize(key:)
    @key = key
  end

  def call
    tag.kbd key, class: "inline-flex h-5 min-w-5 items-center justify-center rounded border border-secondary bg-container-inset px-1 font-mono text-xs leading-none text-secondary"
  end
end
