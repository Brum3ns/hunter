require "test_helper"

class MongoStreamCursorTest < ActiveSupport::TestCase
  test "save_token upserts and token_for reads it back" do
    assert_nil MongoStreamCursor.token_for("katana")
    MongoStreamCursor.save_token("katana", { "_data" => "abc" })
    assert_equal({ "_data" => "abc" }, MongoStreamCursor.token_for("katana"))
    MongoStreamCursor.save_token("katana", { "_data" => "def" })
    assert_equal({ "_data" => "def" }, MongoStreamCursor.token_for("katana"))
    assert_equal 1, MongoStreamCursor.where(collection: "katana").count
  end
end
