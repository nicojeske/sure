require "test_helper"

class PaperlessScanAllJobTest < ActiveJob::TestCase
  test "enqueues a family scan for each configured, auto-link-enabled connection" do
    connection = paperless_connections(:one)

    assert_enqueued_with(job: PaperlessScanFamilyJob, args: [ connection.family_id ]) do
      PaperlessScanAllJob.perform_now
    end
  end

  test "skips connections with auto_link_enabled false" do
    paperless_connections(:one).update!(auto_link_enabled: false)

    assert_no_enqueued_jobs(only: PaperlessScanFamilyJob) do
      PaperlessScanAllJob.perform_now
    end
  end

  test "skips connections missing an api_token" do
    paperless_connections(:one).update!(api_token: nil)

    assert_no_enqueued_jobs(only: PaperlessScanFamilyJob) do
      PaperlessScanAllJob.perform_now
    end
  end

  test "continues enqueueing other families when one raises" do
    PaperlessScanFamilyJob.expects(:perform_later).raises(StandardError.new("boom"))

    assert_nothing_raised do
      PaperlessScanAllJob.perform_now
    end
  end
end
