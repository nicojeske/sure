require "test_helper"

class Paperless::DocumentsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @connection = paperless_connections(:one)
    sign_in @user
  end

  test "thumbnail returns the upstream bytes and content type" do
    Provider::Paperless.any_instance.expects(:file).with("101", kind: :thumb).returns([ "bytes", "image/webp" ])

    get thumbnail_paperless_document_path(101)

    assert_response :success
    assert_equal "image/webp", response.media_type
    assert_equal "bytes", response.body
    assert_match(/inline/, response.headers["Content-Disposition"])
  end

  test "preview streams inline" do
    Provider::Paperless.any_instance.expects(:file).with("101", kind: :preview).returns([ "pdf-bytes", "application/pdf" ])

    get preview_paperless_document_path(101)

    assert_response :success
    assert_match(/inline/, response.headers["Content-Disposition"])
  end

  test "download streams as an attachment" do
    Provider::Paperless.any_instance.expects(:file).with("101", kind: :download).returns([ "pdf-bytes", "application/pdf" ])

    get download_paperless_document_path(101)

    assert_response :success
    assert_match(/attachment/, response.headers["Content-Disposition"])
  end

  test "returns 404 when the family has no configured connection" do
    @connection.destroy

    get thumbnail_paperless_document_path(101)

    assert_response :not_found
  end

  test "maps a not_found provider error to a 404" do
    Provider::Paperless.any_instance.expects(:file).raises(Provider::Paperless::Error.new("nope", :not_found))

    get preview_paperless_document_path(999)

    assert_response :not_found
  end

  test "maps an unreachable provider error to a 502" do
    Provider::Paperless.any_instance.expects(:file).raises(Provider::Paperless::Error.new("down", :unreachable))

    get preview_paperless_document_path(101)

    assert_response :bad_gateway
  end

  test "unauthenticated request is redirected" do
    sign_out

    get thumbnail_paperless_document_path(101)

    assert_redirected_to new_session_url
  end

  test "thumbnail is cached and does not hit the provider twice" do
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new

    Provider::Paperless.any_instance.expects(:file).with("101", kind: :thumb).once.returns([ "bytes", "image/webp" ])

    get thumbnail_paperless_document_path(101)
    assert_response :success

    get thumbnail_paperless_document_path(101)
    assert_response :success
  ensure
    Rails.cache = original_cache
  end

  private
    def sign_out
      @user.sessions.each do |session|
        delete session_path(session)
      end
    end
end
