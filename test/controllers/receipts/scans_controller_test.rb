require "test_helper"

class Receipts::ScansControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @connection = paperless_connections(:one)
    sign_in @user
  end

  test "create starts a scan and enqueues the job" do
    assert_difference "PaperlessScan.count", 1 do
      assert_enqueued_jobs 1, only: PaperlessScanFamilyJob do
        post receipts_scan_path, as: :turbo_stream
      end
    end

    assert_response :success
    scan = PaperlessScan.recent.first
    assert_equal "manual", scan.trigger
    assert_equal "pending", scan.status
  end

  test "create does not start a second scan while one is in progress" do
    PaperlessScan.create!(family_id: @connection.family_id, paperless_connection: @connection, status: "running")

    assert_no_difference "PaperlessScan.count" do
      assert_no_enqueued_jobs(only: PaperlessScanFamilyJob) do
        post receipts_scan_path, as: :turbo_stream
      end
    end

    assert_response :success
  end

  test "create sweeps a stale scan and starts a new one" do
    stale = PaperlessScan.create!(
      family_id: @connection.family_id,
      paperless_connection: @connection,
      status: "running",
      started_at: (PaperlessScan::STALE_AFTER + 1.minute).ago
    )

    assert_difference "PaperlessScan.count", 1 do
      post receipts_scan_path, as: :turbo_stream
    end

    assert_response :success
    assert_equal "failed", stale.reload.status
  end

  test "create redirects when Paperless is not configured" do
    @connection.destroy

    assert_no_difference "PaperlessScan.count" do
      post receipts_scan_path, as: :turbo_stream
    end

    assert_redirected_to receipts_path
  end
end
