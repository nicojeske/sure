require "test_helper"

class PaperlessAutoLinkJobTest < ActiveJob::TestCase
  setup do
    @transaction = transactions(:one)
    @connection = paperless_connections(:one)
  end

  test "calls the matcher and broadcasts the updated frame" do
    PaperlessConnection::Matcher.any_instance.expects(:match!).with(@transaction).once

    Turbo::StreamsChannel.expects(:broadcast_replace_to).with(
      @connection.family,
      target: ActionView::RecordIdentifier.dom_id(@transaction, :receipt_links),
      html: anything
    )
    # The row's receipt pill lives outside the drawer's receipt_links frame above, in the
    # transactions list — broadcast a second replace so a background match shows up there live.
    Turbo::StreamsChannel.expects(:broadcast_replace_to).with(
      @connection.family,
      target: ActionView::RecordIdentifier.dom_id(@transaction, :receipt_pill),
      html: anything
    )

    PaperlessAutoLinkJob.perform_now(@transaction.id)
  end

  test "logs and swallows provider errors, still broadcasting" do
    PaperlessConnection::Matcher.any_instance.expects(:match!)
      .raises(Provider::Paperless::Error.new("down", :unreachable))

    DebugLogEntry.expects(:capture).with(has_entries(provider_key: "paperless"))
    Turbo::StreamsChannel.expects(:broadcast_replace_to).twice

    assert_nothing_raised do
      PaperlessAutoLinkJob.perform_now(@transaction.id)
    end
  end

  test "no-ops when the transaction no longer exists" do
    PaperlessConnection::Matcher.any_instance.expects(:match!).never

    assert_nothing_raised do
      PaperlessAutoLinkJob.perform_now("nonexistent")
    end
  end

  test "no-ops when the family has no configured connection" do
    @connection.destroy

    PaperlessConnection::Matcher.any_instance.expects(:match!).never

    PaperlessAutoLinkJob.perform_now(@transaction.id)
  end
end
