# frozen_string_literal: true

require "yaml"

module ERBLint
  module Linters
    # Enforces the mechanical design-system rules from docs/llm-guides/design-system.md.
    # Files that already broke a rule are listed per check in the baseline file, so only
    # new violations fail; remove a file from the baseline once it is fixed.
    class DesignSystemGuard < Linter
      include LinterRegistry

      PALETTE_PREFIXES = %w[bg text border ring fill stroke from to via divide outline placeholder decoration shadow accent caret].freeze
      PALETTE_COLORS = %w[slate gray zinc neutral stone red orange amber yellow lime green emerald teal cyan sky blue indigo violet purple fuchsia pink rose].freeze

      CHECKS = {
        "lucide_icon" => [ /\blucide_icon\b/, "Use the `icon` helper instead of `lucide_icon`." ],
        "palette" => [
          /\b(?:#{PALETTE_PREFIXES.join("|")})-(?:#{PALETTE_COLORS.join("|")})-\d{2,3}\b/,
          "Use a functional token (bg-container, text-primary, text-destructive, …) instead of a raw palette class."
        ],
        "hex" => [ /#(?:\h{8}|\h{6})\b/, "Use a functional token instead of a hex colour literal." ],
        "svg" => [ /<svg\b/, "Render icons with the `icon` helper; raw SVG belongs in DS primitives." ]
      }.freeze

      DS_COMPONENTS = "app/components/DS/"

      class ConfigSchema < LinterConfig
        property :baseline_file, accepts: String, default: ".erb_linters/design_system_baseline.yml"
      end
      self.config_schema = ConfigSchema

      def run(processed_source)
        path = relative_path(processed_source.filename)

        CHECKS.each do |check, (pattern, message)|
          next if skipped?(check, path)

          processed_source.file_content.to_enum(:scan, pattern).each do
            match = Regexp.last_match
            range = processed_source.to_source_range(match.begin(0)...match.end(0))
            add_offense(range, "#{message} See docs/llm-guides/design-system.md.", check)
          end
        end
      end

      private
        def skipped?(check, path)
          return true if check == "svg" && path.start_with?(DS_COMPONENTS)

          baseline.fetch(check, []).include?(path)
        end

        def baseline
          @baseline ||= begin
            file = File.expand_path(@config.baseline_file, @file_loader.base_path)
            File.exist?(file) ? YAML.safe_load_file(file) || {} : {}
          end
        end

        def relative_path(filename)
          filename.to_s.delete_prefix("#{@file_loader.base_path}/").delete_prefix("./")
        end
    end
  end
end
