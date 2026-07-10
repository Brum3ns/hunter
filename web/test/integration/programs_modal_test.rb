require "test_helper"

class ProgramsModalTest < ActionDispatch::IntegrationTest
  setup { sign_in_as(users(:one)) }

  test "modal renders and strips script tags from policy html" do
    program = Program.new("_sid" => "1", "name" => "Acme", "platform" => "hackerone",
                          "policy" => { "rules_html" => "<p>ok</p><script>alert(1)</script>" })
    stub_methods(Programs::Source, find: ->(_sid) { program }) do
      get programs_modal_path(sid: "1"), headers: { "X-Requested-With" => "XMLHttpRequest" }
    end
    assert_response :success
    assert_match "Acme", response.body
    assert_match "<p>ok</p>", response.body
    assert_no_match(/<script>alert/, response.body)
  end

  test "modal 404s for a missing program" do
    stub_methods(Programs::Source, find: ->(_sid) { nil }) do
      get programs_modal_path(sid: "nope"), headers: { "X-Requested-With" => "XMLHttpRequest" }
    end
    assert_response :not_found
  end
end
