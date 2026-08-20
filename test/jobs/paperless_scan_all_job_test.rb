require "test_helper"

class PaperlessScanAllJobTest < ActiveJob::TestCase
  test "creates a scan and enqueues a family run for each configured, auto-link-enabled connection" do
    connection = paperless_connections(:one)

    assert_difference "PaperlessScan.count", 1 do
      assert_enqueued_jobs 1, only: PaperlessScanFamilyJob do
        PaperlessScanAllJob.perform_now
      end
    end

    scan = PaperlessScan.recent.first
    assert_equal connection, scan.paperless_connection
    assert_equal "scheduled", scan.trigger
    assert_equal "pending", scan.status
  end

  test "skips connections with auto_link_enabled false" do
    paperless_connections(:one).update!(auto_link_enabled: false)

    assert_no_difference "PaperlessScan.count" do
      assert_no_enqueued_jobs(only: PaperlessScanFamilyJob) do
        PaperlessScanAllJob.perform_now
      end
    end
  end

  test "skips connections missing an api_token" do
    paperless_connections(:one).update!(api_token: nil)

    assert_no_difference "PaperlessScan.count" do
      assert_no_enqueued_jobs(only: PaperlessScanFamilyJob) do
        PaperlessScanAllJob.perform_now
      end
    end
  end

  test "skips a family that already has a scan in progress" do
    connection = paperless_connections(:one)
    PaperlessScan.create!(family_id: connection.family_id, paperless_connection: connection, status: "running")

    assert_no_difference "PaperlessScan.count" do
      assert_no_enqueued_jobs(only: PaperlessScanFamilyJob) do
        PaperlessScanAllJob.perform_now
      end
    end
  end

  test "continues enqueueing other families when one raises" do
    PaperlessScanFamilyJob.expects(:perform_later).raises(StandardError.new("boom"))

    assert_nothing_raised do
      PaperlessScanAllJob.perform_now
    end
  end
end
