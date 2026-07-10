require "minitest/autorun"
require_relative "../token"

class RunnerTokenTest < Minitest::Test
  def test_passes_a_clean_token_through
    assert_equal "abc123", RunnerToken.normalize("abc123")
  end

  def test_trims_surrounding_whitespace
    assert_equal "abc123", RunnerToken.normalize("  abc123\n")
  end

  def test_strips_surrounding_double_quotes
    assert_equal "abc123", RunnerToken.normalize('"abc123"')
  end

  def test_strips_surrounding_single_quotes
    assert_equal "abc123", RunnerToken.normalize("'abc123'")
  end

  def test_strips_quotes_then_padding
    assert_equal "abc123", RunnerToken.normalize(%(  "abc123"  ))
  end

  def test_keeps_interior_and_mismatched_quotes
    assert_equal 'ab"c', RunnerToken.normalize('ab"c')
    assert_equal %("abc'), RunnerToken.normalize(%("abc'))
  end

  def test_blank_and_nil_normalize_to_empty
    assert_equal "", RunnerToken.normalize(nil)
    assert_equal "", RunnerToken.normalize("   ")
  end
end
