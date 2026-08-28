# frozen_string_literal: true

module LittleGhost
  module CodeMode
    module Ruby # :nodoc:
      module Host # :nodoc:
        SOURCE = <<~'RUBY'
            require "json"
            protocol_output = STDOUT.dup
            protocol_output.sync = true
            STDOUT.reopen(STDERR)
            STDOUT.sync = true
            begin
            read_exactly = lambda do |length|
              value = +"".b
              value << (STDIN.read(length - value.bytesize) || raise("incomplete protocol frame")) while value.bytesize < length
              value
            end
            read_frame = lambda do
              length = read_exactly.call(4).unpack1("N")
              raise "protocol frame too large" if length > 64 * 1024 * 1024
              JSON.parse(read_exactly.call(length))
            end
            write_frame = lambda do |value|
              payload = JSON.generate(value)
              raise "protocol frame too large" if payload.bytesize > 64 * 1024 * 1024
              protocol_output.write([payload.bytesize].pack("N"))
              protocol_output.write(payload)
              protocol_output.flush
            end
            request = read_frame.call
            catalog = request.fetch("catalog")
            write_lock = Mutex.new
            queues_lock = Mutex.new
            response_queues = {}
            calls = 0
            max_calls = request.fetch("tool_calls")
            messages = request.fetch("messages")
            output_buffer = +""
            flush_output = lambda do
              unless output_buffer.empty?
                value = output_buffer.dup
                output_buffer.clear
                write_frame.call(type: "text", value: value)
              end
            end
            emit = lambda do |value|
              write_lock.synchronize do
                flush_output.call
                write_frame.call(value)
              end
            end
            program_output = Object.new
            program_output.define_singleton_method(:write) do |value|
              value = String(value)
              write_lock.synchronize do
                output_buffer << value
                flush_output.call if output_buffer.bytesize >= 16_384 || value.include?("\n")
              end
              value.bytesize
            end
            program_output.define_singleton_method(:flush) do
              write_lock.synchronize { flush_output.call }
              self
            end
            program_output.define_singleton_method(:sync) { false }
            program_output.define_singleton_method(:sync=) do |value|
              flush if value
              value
            end
            program_output.define_singleton_method(:tty?) { false }
            $stdout = program_output
            reader = Thread.new do
              loop do
                response = read_frame.call
                if response["id"]
                  queue = queues_lock.synchronize { response_queues[response["id"]] }
                  queue << response if queue
                end
              end
            end
            invoke = lambda do |name, arguments|
              id, queue = queues_lock.synchronize do
                calls += 1
                raise messages.fetch("tool_calls_limit") if calls > max_calls
                id = "call-#{calls}"
                queue = Queue.new
                response_queues[id] = queue
                [id, queue]
              end
              emit.call(type: "call", id: id, name: name, arguments: arguments)
              response = queue.pop
              queues_lock.synchronize { response_queues.delete(id) }
              raise response.fetch("error") if response["error"]
              response["value"]
            end
            tools = Object.new
            tools.define_singleton_method(:call) { |name, arguments = {}| invoke.call(name.to_s, arguments) }
            catalog.each do |specification|
              name = specification.fetch("name")
              method_name = name.gsub(/[^a-zA-Z0-9_]/, "_").sub(/\A(?=\d)/, "tool_")
              tools.define_singleton_method(method_name) { |**arguments| invoke.call(name, arguments) }
            end
            concurrency = request.fetch("concurrency")
            tools.define_singleton_method(:parallel) do |*operations|
              raise ArgumentError, messages.fetch("parallel_callables") unless operations.all? { |operation| operation.respond_to?(:call) }
              operations.each_slice(concurrency).flat_map do |batch|
                batch.map { |operation| Thread.new { operation.call } }.map(&:value)
              end
            end
            Object.const_set(:ALL_TOOLS, catalog.freeze) unless Object.const_defined?(:ALL_TOOLS)
            Object.const_set(:FRAME, request["frame"].freeze) if request["frame"] && !Object.const_defined?(:FRAME)
            evaluation_context = Class.new do
              def evaluate(source)
                instance_eval(source, "(code-mode)", 1)
              end
            end
            context = evaluation_context.new
            finished = false
            finish_value = nil
            context.define_singleton_method(:tools) { tools }
            context.define_singleton_method(:text) { |value| emit.call(type: "text", value: value.to_s); nil }
            context.define_singleton_method(:finish) do |value = nil|
              finished = true
              finish_value = value
              throw :little_ghost_finish
            end
            value = catch(:little_ghost_finish) { context.evaluate(request.fetch("source")) }
            value = finish_value if finished
            emit.call(type: "done", value: value)
          rescue SignalException
            exit 0
          rescue Exception => error
            failure = messages.fetch("execution_failed")
              .gsub("__ERROR_CLASS__") { error.class.to_s }
              .gsub("__ERROR_MESSAGE__") { error.message }
            STDERR.puts(failure)
            error_frame = {type: "error", error: failure}
            emit ? emit.call(error_frame) : write_frame&.call(error_frame)
            exit 1
            end
        RUBY
      end
    end
  end
end
