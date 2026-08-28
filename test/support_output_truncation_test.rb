# frozen_string_literal: true

require "test_helper"

class SupportOutputTruncationTest < Minitest::Test
  def test_estimates_tokens_from_utf8_bytes
    assert_equal 0, truncation.approx_token_count("")
    assert_equal 1, truncation.approx_token_count("a")
    assert_equal 1, truncation.approx_token_count("abcd")
    assert_equal 2, truncation.approx_token_count("abcde")
    assert_equal 1, truncation.approx_token_count("🙂")
    assert_equal 8, truncation.approx_bytes_for_tokens(2)
  end

  def test_returns_content_unchanged_within_the_budget
    assert_equal ["abcd", nil], truncation.truncate_middle_with_token_budget("abcd", 1)
  end

  def test_truncates_ascii_content_from_the_middle
    assert_equal ["…3", 3],
      truncation.truncate_middle_with_token_budget("abcdefghij", 1)
  end

  def test_truncates_only_at_utf8_boundaries
    assert_equal ["…3 tok", 3],
      truncation.truncate_middle_with_token_budget("🙂🙂🙂", 2)
  end

  def test_marker_uses_the_configured_byte_budget_when_boundaries_retain_less
    assert_equal ["…3", 3],
      truncation.truncate_middle_with_token_budget("€€€", 1)
  end

  def test_custom_marker_is_rendered_within_the_output_budget
    Dir.mktmpdir do |directory|
      prompt = File.join(directory, "little_ghost", "output", "truncation", "marker.erb")
      FileUtils.mkdir_p(File.dirname(prompt))
      File.write(prompt, "[removed=<%= removed_tokens %>]")
      framework_prompts = LittleGhost::FrameworkPrompts.new(paths: [directory])

      result, original_tokens = truncation.truncate_middle_with_token_budget(
        "abcdefghijklmnopqrst",
        3,
        framework_prompts:
      )

      assert_equal "[removed=5]t", result
      assert_equal 5, original_tokens
      assert_operator result.bytesize, :<=, 12
    end
  end

  def test_normalizes_invalid_and_binary_content_to_utf8
    invalid = "prefix\xffsuffix".b

    result, = truncation.truncate_middle_with_token_budget(invalid, 100)

    assert_equal Encoding::UTF_8, result.encoding
    assert_predicate result, :valid_encoding?
    assert_equal "prefix�suffix", result
  end

  def test_preserves_valid_utf8_bytes_tagged_as_binary
    result, = truncation.truncate_middle_with_token_budget("caf\xc3\xa9".b, 100)

    assert_equal "café", result
    assert_equal Encoding::UTF_8, result.encoding
  end

  private

  def truncation
    LittleGhost::Support::OutputTruncation
  end
end
