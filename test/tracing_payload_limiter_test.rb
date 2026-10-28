# frozen_string_literal: true

require "test_helper"

class TracingPayloadLimiterTest < Minitest::Test
  def test_leaves_content_under_the_limit_unchanged
    messages = JSON.generate([{role: "user", parts: [{type: "text", content: "hello"}]}])
    attributes = {"gen_ai.input.messages" => messages, "metadata" => JSON.generate(source: "test")}

    assert_same attributes, limiter.call(attributes)
  end

  def test_prioritizes_the_recent_message_suffix
    messages = [
      canonical_message("system", "instructions " * 35),
      canonical_message("user", "old request " * 35),
      canonical_message("assistant", "old response " * 35),
      canonical_message("user", "recent request " * 35),
      canonical_message("assistant", "recent response " * 35)
    ]
    attributes = {"gen_ai.input.messages" => JSON.generate(messages)}

    transformed = limiter.call(attributes)

    captured = JSON.parse(transformed.fetch("gen_ai.input.messages"))
    assert_equal ["assistant"], captured.map { |message| message.fetch("role") }
    assert_includes captured.last.dig("parts", 0, "content"), "recent response"
    refute_includes captured.to_s, "old request"
    details = truncation_details(transformed, "gen_ai.input.messages")
    assert_equal "recent_suffix", details.fetch("selection")
    assert_equal 4, details.fetch("omitted_messages")
  end

  def test_keeps_a_recent_tool_call_and_its_result_together
    messages = [
      {
        "role" => "assistant",
        "parts" => [{
          "type" => "tool_call",
          "id" => "call-1",
          "name" => "lookup",
          "arguments" => {"query" => "x" * 4_000}
        }]
      },
      {
        "role" => "tool",
        "parts" => [{
          "type" => "tool_call_response",
          "id" => "call-1",
          "response" => {"result" => "y" * 4_000}
        }]
      }
    ]
    attributes = {"gen_ai.input.messages" => JSON.generate(messages)}

    transformed = limiter.call(attributes)

    serialized = transformed.fetch("gen_ai.input.messages")
    captured = JSON.parse(serialized)
    assert_operator serialized.bytesize, :<=, 1_024
    assert_equal %w[assistant tool], captured.map { |message| message.fetch("role") }
    assert_equal ["call-1", "call-1"], captured.map { |message| message.dig("parts", 0, "id") }
    assert_includes serialized, "...[truncated]..."
  end

  def test_keeps_only_matched_recent_pairs_when_tool_structure_exceeds_the_limit
    calls = 40.times.map do |index|
      {"type" => "tool_call", "id" => "call-#{index}", "name" => "lookup", "arguments" => {}}
    end
    results = 40.times.map do |index|
      {
        "role" => "tool",
        "parts" => [{"type" => "tool_call_response", "id" => "call-#{index}", "response" => {}}]
      }
    end
    messages = [{"role" => "assistant", "parts" => calls}, *results]
    attributes = {"gen_ai.input.messages" => JSON.generate(messages)}

    transformed = limiter.call(attributes)

    serialized = transformed.fetch("gen_ai.input.messages")
    captured = JSON.parse(serialized)
    captured_call_ids = captured.flat_map do |message|
      message.fetch("parts").filter_map { |part| part["id"] if part["type"] == "tool_call" }
    end
    captured_result_ids = captured.flat_map do |message|
      message.fetch("parts").filter_map { |part| part["id"] if part["type"] == "tool_call_response" }
    end
    assert_operator serialized.bytesize, :<=, 1_024
    assert_equal captured_call_ids, captured_result_ids
    assert_operator captured_call_ids.length, :>, 0
    assert_equal "call-39", captured_call_ids.last
  end

  def test_truncates_a_single_oversized_unicode_message_without_losing_its_role
    attributes = {
      "gen_ai.input.messages" => JSON.generate([canonical_message("user", "é" * 10_000)])
    }

    transformed = limiter.call(attributes)

    serialized = transformed.fetch("gen_ai.input.messages")
    captured = JSON.parse(serialized)
    assert_operator serialized.bytesize, :<=, 1_024
    assert_equal "user", captured.first.fetch("role")
    assert_predicate captured.first.dig("parts", 0, "content"), :valid_encoding?
    assert_includes captured.first.dig("parts", 0, "content"), "...[truncated]..."
  end

  def test_preserves_existing_metadata_when_recording_truncation
    metadata = JSON.generate("request_source" => "support")
    attributes = {
      "gen_ai.tool.call.result" => JSON.generate("result" => "x" * 10_000),
      "metadata" => metadata
    }

    transformed = limiter.call(attributes)

    captured_metadata = JSON.parse(transformed.fetch("metadata"))
    assert_equal "support", captured_metadata.fetch("request_source")
    details = captured_metadata.fetch("telemetry_truncation").fetch("gen_ai.tool.call.result")
    assert_operator details.fetch("original_bytes"), :>, details.fetch("captured_bytes")
    assert_operator transformed.fetch("gen_ai.tool.call.result").bytesize, :<=, 1_024
  end

  def test_limits_openinference_values_and_other_large_string_attributes
    attributes = {
      "input.value" => JSON.generate("messages" => [canonical_message("user", "x" * 10_000)]),
      "output.value" => JSON.generate([canonical_message("assistant", "y" * 10_000)]),
      "custom.large_value" => "prefix-" + ("é" * 10_000) + "-suffix"
    }

    transformed = limiter.call(attributes)

    assert_operator transformed.fetch("input.value").bytesize, :<=, 1_024
    assert_operator transformed.fetch("output.value").bytesize, :<=, 1_024
    assert_equal "recent_suffix", truncation_details(transformed, "input.value").fetch("selection")
    assert_equal "leading_choices", truncation_details(transformed, "output.value").fetch("selection")
    custom_value = transformed.fetch("custom.large_value")
    assert_operator custom_value.bytesize, :<=, 1_024
    assert_predicate custom_value, :valid_encoding?
    assert_includes custom_value, "...[truncated]..."
  end

  def test_prioritizes_recent_messages_in_openinference_input
    messages = [
      canonical_message("user", "old request " * 35),
      canonical_message("assistant", "old response " * 35),
      canonical_message("user", "recent request " * 35),
      canonical_message("assistant", "recent response " * 35)
    ]
    attributes = {"input.value" => JSON.generate(messages)}

    transformed = limiter.call(attributes)

    captured = JSON.parse(transformed.fetch("input.value"))
    assert_equal ["assistant"], captured.map { |message| message.fetch("role") }
    assert_includes captured.first.dig("parts", 0, "content"), "recent response"
    refute_includes captured.to_s, "old request"
  end

  def test_keeps_openinference_tool_call_and_result_together
    messages = [
      {
        "role" => "assistant",
        "parts" => [{
          "type" => "tool_call",
          "id" => "call-1",
          "name" => "lookup",
          "arguments" => {"query" => "x" * 4_000}
        }]
      },
      {
        "role" => "tool",
        "parts" => [{
          "type" => "tool_call_response",
          "id" => "call-1",
          "response" => {"result" => "y" * 4_000}
        }]
      }
    ]
    attributes = {"input.value" => JSON.generate("messages" => messages, "source" => "model")}

    transformed = limiter.call(attributes)

    captured = JSON.parse(transformed.fetch("input.value"))
    assert_equal "model", captured.fetch("source")
    assert_equal %w[assistant tool], captured.fetch("messages").map { |message| message.fetch("role") }
    assert_equal ["call-1", "call-1"],
      captured.fetch("messages").map { |message| message.dig("parts", 0, "id") }
  end

  def test_limits_non_message_openinference_tool_values_as_structured_json
    attributes = {
      "output.value" => JSON.generate("status" => "ok", "result" => "x" * 10_000)
    }

    transformed = limiter.call(attributes)

    captured = JSON.parse(transformed.fetch("output.value"))
    assert_equal "ok", captured.fetch("status")
    assert_includes captured.fetch("result"), "...[truncated]..."
  end

  def test_preserves_a_tool_only_openinference_model_output
    output = [{
      "role" => "assistant",
      "parts" => [{
        "type" => "tool_call",
        "id" => "call-1",
        "name" => "lookup_orders",
        "arguments" => {"order_ids" => Array.new(500, "order-1")}
      }]
    }]
    attributes = {"output.value" => JSON.generate(output)}

    transformed = limiter.call(attributes)

    serialized = transformed.fetch("output.value")
    captured = JSON.parse(serialized)
    assert_operator serialized.bytesize, :<=, 1_024
    assert_equal "assistant", captured.first.fetch("role")
    assert_equal "tool_call", captured.first.dig("parts", 0, "type")
    assert_equal "call-1", captured.first.dig("parts", 0, "id")
    assert_equal "lookup_orders", captured.first.dig("parts", 0, "name")
    assert_equal true, captured.first.dig("parts", 0, "arguments", "truncated")
  end

  def test_malformed_metadata_cannot_make_the_limiter_raise
    invalid_metadata = "bad\xFFmetadata".dup.force_encoding(Encoding::UTF_8)
    attributes = {
      "gen_ai.input.messages" => "[#{invalid_metadata * 1_000}",
      "metadata" => invalid_metadata
    }

    transformed = limiter.call(attributes)

    refute transformed.key?("gen_ai.input.messages")
    metadata = transformed.fetch("metadata")
    assert_predicate metadata, :valid_encoding?
    assert_kind_of Hash, JSON.parse(metadata)
  end

  def test_rejects_a_budget_below_the_minimum
    error = assert_raises(ArgumentError) { LittleGhost::Tracing::PayloadLimiter.new(max_bytes: 512) }

    assert_equal "max_bytes must be at least 1024", error.message
  end

  def test_leaves_non_string_attributes_alone
    attributes = {"tag.tags" => Array.new(2_000, "support"), "gen_ai.usage.input_tokens" => 10}

    assert_same attributes, limiter.call(attributes)
  end

  def test_warns_when_an_attribute_has_to_be_omitted
    events = []
    listener = Object.new
    listener.define_singleton_method(:emit) { |event| events << event }
    attributes = {"gen_ai.input.messages" => JSON.generate({"role" => "user"}) + (" " * 2_000)}

    transformed = LittleGhost::Events.subscribed(listener) { limiter.call(attributes) }

    refute transformed.key?("gen_ai.input.messages")
    assert_equal ["little_ghost.tracing.payload_limit_failed"], events.map { |event| event[:name] }
  end

  private

  def limiter
    @limiter ||= LittleGhost::Tracing::PayloadLimiter.new(max_bytes: 1_024)
  end

  def canonical_message(role, content)
    {
      "role" => role,
      "parts" => [{"type" => "text", "content" => content}]
    }
  end

  def truncation_details(attributes, attribute)
    JSON.parse(attributes.fetch("metadata"))
      .fetch("telemetry_truncation")
      .fetch(attribute)
  end
end
