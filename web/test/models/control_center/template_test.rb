require "test_helper"

class ControlCenter::TemplateTest < ActiveSupport::TestCase
  def valid_attrs(**over)
    { name: "probe", kind: "cmdscript", commands: [{ "command" => "httpx", "args" => ["-silent"], "operator" => "" }] }.merge(over)
  end

  test "valid template saves" do
    assert ControlCenter::Template.new(valid_attrs).valid?
  end

  test "name is required and unique" do
    ControlCenter::Template.create!(valid_attrs)
    dup = ControlCenter::Template.new(valid_attrs)
    assert_not dup.valid?
    assert_includes dup.errors[:name], "has already been taken"
  end

  test "kind must be known" do
    t = ControlCenter::Template.new(valid_attrs(kind: "bogus"))
    assert_not t.valid?
  end

  test "commands are validated through TemplateValidator" do
    t = ControlCenter::Template.new(valid_attrs(commands: [{ "command" => "httpx", "args" => ["a\nb"], "operator" => "" }]))
    assert_not t.valid?
    assert(t.errors[:commands].any? { |m| m.include?("forbidden character") })
  end
end
