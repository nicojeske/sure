namespace :transactions do
  desc "Strip card-aggregator prefixes (e.g. Curve's CRV*) from Enable Banking transaction/merchant names. Args: family_id, dry_run=true"
  task :strip_name_prefixes, [ :family_id, :dry_run ] => :environment do |_t, args|
    family_id = args[:family_id]

    if family_id.blank?
      puts "Usage: bin/rails 'transactions:strip_name_prefixes[family_id,dry_run=true]'"
      exit 1
    end

    # Default to dry_run=true (like lib/tasks/simplefin_backfill.rake) so a bare
    # invocation never mutates data by accident; pass dry_run=false to apply.
    dry_run = args[:dry_run].to_s.downcase != "false"
    family = Family.find(family_id)

    puts "#{dry_run ? "[dry run] " : ""}Stripping name prefixes for family #{family_id}..."

    result = Family::NamePrefixBackfill.new(family).call(dry_run: dry_run)

    puts "Entries #{dry_run ? "that would be " : ""}updated: #{result.entries_updated}"
    puts "Merchants #{dry_run ? "that would be " : ""}renamed: #{result.merchants_renamed}"
    puts "Merchants #{dry_run ? "that would be " : ""}merged: #{result.merchants_merged}"
  end
end
