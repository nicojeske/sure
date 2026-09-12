class StripNamePrefixesJob < ApplicationJob
  queue_as :medium_priority

  def perform(family)
    result = Family::NamePrefixBackfill.new(family).call

    DebugLogEntry.capture(
      category: "name_prefix_backfill",
      level: "info",
      message: "Transaction name prefix cleanup completed",
      source: self.class.name,
      family: family,
      metadata: {
        entries_updated: result.entries_updated,
        merchants_renamed: result.merchants_renamed,
        merchants_merged: result.merchants_merged
      }
    )
  end
end
