require "test_helper"
require "erb_lint/all"
require Rails.root.join(".erb_linters/design_system_guard").to_s

class DesignSystemGuardTest < ActiveSupport::TestCase
  setup do
    @baseline = Tempfile.new([ "baseline", ".yml" ])
    write_baseline({})
  end

  teardown { @baseline.close! }

  test "flags lucide_icon calls" do
    assert_equal [ "lucide_icon" ], checks_for(%(<%= lucide_icon "plus", class: "w-4" %>))
  end

  test "flags raw palette classes, including variants and opacity" do
    assert_equal [ "palette" ] * 3, checks_for(%(<div class="bg-red-500 hover:text-blue-600 border-gray-200/50"></div>))
  end

  test "flags hex colour literals" do
    assert_equal [ "hex" ], checks_for(%(<div style="color: #1a2b3c"></div>))
  end

  test "flags raw svg outside DS components" do
    assert_equal [ "svg" ], checks_for(%(<svg viewBox="0 0 10 10"></svg>))
  end

  test "allows raw svg inside DS components" do
    assert_empty checks_for(%(<svg viewBox="0 0 10 10"></svg>), filename: "app/components/DS/thing.html.erb")
  end

  test "accepts functional tokens, the icon helper and anchor links" do
    assert_empty checks_for(%(<a href="#add" class="bg-container text-primary"><%= icon "plus" %></a>))
  end

  test "skips only the baselined checks for a baselined file" do
    write_baseline("palette" => [ "app/views/foo/_bar.html.erb" ])

    assert_equal [ "lucide_icon" ], checks_for(%(<div class="bg-red-500"><%= lucide_icon "x" %></div>))
  end

  private
    def checks_for(content, filename: "app/views/foo/_bar.html.erb")
      file_loader = ERBLint::FileLoader.new(Rails.root.to_s)
      config = ERBLint::Linters::DesignSystemGuard.config_schema.new(baseline_file: @baseline.path)
      linter = ERBLint::Linters::DesignSystemGuard.new(file_loader, config)
      linter.run(ERBLint::ProcessedSource.new(Rails.root.join(filename).to_s, content.dup))
      linter.offenses.map(&:context)
    end

    def write_baseline(baseline)
      File.write(@baseline.path, baseline.to_yaml)
    end
end
