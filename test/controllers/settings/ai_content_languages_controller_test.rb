require "test_helper"

class Settings::AiContentLanguagesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:family_admin)
  end

  test "the AI settings page offers the content language by native name, defaulting to the interface language" do
    @admin.family.update!(ai_content_language: nil)
    sign_in @admin

    get settings_ai_prompts_path

    assert_select "form[action='#{settings_ai_content_language_path}'] select[name='family[ai_content_language]']" do
      assert_select "option[value='']", text: I18n.t("settings.ai_content_languages.form.same_as_interface")
      assert_select "option[value='de']", text: "Deutsch"
      assert_select "option[selected]", count: 0
    end
  end

  test "admin sets the family's AI content language" do
    sign_in @admin

    patch settings_ai_content_language_path, params: { family: { ai_content_language: "de" } }

    assert_redirected_to settings_ai_prompts_path
    assert_equal "de", @admin.family.reload.ai_content_language
  end

  test "choosing the interface language clears the setting" do
    @admin.family.update!(ai_content_language: "de")
    sign_in @admin

    patch settings_ai_content_language_path, params: { family: { ai_content_language: "" } }

    assert_redirected_to settings_ai_prompts_path
    assert_nil @admin.family.reload.ai_content_language
  end

  test "rejects a language the app does not offer" do
    sign_in @admin

    patch settings_ai_content_language_path, params: { family: { ai_content_language: "xx" } }

    assert_redirected_to settings_ai_prompts_path
    assert flash[:alert].present?
    assert_nil @admin.family.reload.ai_content_language
  end

  test "a non-admin member cannot change the AI content language" do
    member = users(:family_member)
    sign_in member

    patch settings_ai_content_language_path, params: { family: { ai_content_language: "de" } }

    assert_redirected_to accounts_path
    assert_nil member.family.reload.ai_content_language
  end
end
