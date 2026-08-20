require "test_helper"

class PaperlessScanTest < ActiveSupport::TestCase
  setup do
    @connection = paperless_connections(:one)
  end

  test "percent is zero when nothing is planned yet" do
    scan = build_running(total_count: 0, processed_count: 0)

    assert_equal 0, scan.percent
  end

  test "percent rounds progress against the planned total" do
    scan = build_running(total_count: 30, processed_count: 10)

    assert_equal 33, scan.percent
  end

  test "percent is clamped to 100" do
    scan = build_running(total_count: 5, processed_count: 9)

    assert_equal 100, scan.percent
  end

  test "in_progress? covers pending and running only" do
    assert build_running.in_progress?
    assert_not paperless_scans(:completed).in_progress?
  end

  test "stale? flags an in-progress scan whose worker stopped reporting" do
    scan = build_running(started_at: 1.minute.ago)
    assert_not scan.stale?

    scan.update!(started_at: (PaperlessScan::STALE_AFTER + 1.minute).ago)
    assert scan.stale?
  end

  test "stale? is never true for a finished scan" do
    scan = paperless_scans(:completed)
    scan.update!(started_at: 1.year.ago)

    assert_not scan.stale?
  end

  private
    def build_running(attributes = {})
      PaperlessScan.create!({
        family: @connection.family,
        paperless_connection: @connection,
        status: "running",
        started_at: Time.current
      }.merge(attributes))
    end
end
