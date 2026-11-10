require "test_helper"

class DS::PageHeaderTest < ViewComponent::TestCase
  test "renders the title as the page's h1" do
    render_inline(DS::PageHeader.new(title: "Monthly review"))

    assert_selector "header h1.text-2xl.font-semibold.text-primary", exact_text: "Monthly review"
    assert_no_selector "h1.truncate"
    assert_selector "header.items-center"
    assert_no_selector "header p"
    assert_no_text "Preview"
  end

  test "adds the subtitle and aligns the actions with the title" do
    render_inline(DS::PageHeader.new(title: "October 2026", subtitle: "October 1 – October 31")) do |header|
      header.with_action { "<a href='/cards'>Start review</a>".html_safe }
    end

    assert_selector "header.items-start p.text-sm.text-secondary", exact_text: "October 1 – October 31"
    assert_selector "header > div.flex > a[href='/cards']", text: "Start review"
  end

  test "marks a preview feature and shows the status after the title" do
    render_inline(DS::PageHeader.new(title: "October 2026", preview: true)) do |header|
      header.with_status { "<span data-status>Not started</span>".html_safe }
    end

    assert_selector :xpath, "//h1/following-sibling::span[1]", text: /Preview/i
    assert_selector :xpath, "//h1/following-sibling::span[2][@data-status]", text: "Not started"
  end

  test "renders the actions in order" do
    render_inline(DS::PageHeader.new(title: "Review")) do |header|
      header.with_action { "<a>Summary</a>".html_safe }
      header.with_action { "<button>Refresh</button>".html_safe }
    end

    assert_selector :xpath, "//header/div[last()]/a/following-sibling::button", text: "Refresh"
  end

  test "a medium header is smaller and takes header attributes" do
    render_inline(DS::PageHeader.new(title: "Review October 2026", size: :md, class: "mb-4", id: "review-header"))

    assert_selector "header#review-header.mb-4.flex h1.text-xl.truncate", exact_text: "Review October 2026"
    assert_no_selector "h1.text-2xl"
  end

  test "refuses an unknown size" do
    assert_raises(ArgumentError) { DS::PageHeader.new(title: "Review", size: :xl) }
  end
end
