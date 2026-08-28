# frozen_string_literal: true

require "mini_racer"
require "securerandom"
require_relative "../protocol"

module LittleGhost
  module CodeMode
    module Javascript # :nodoc:
    end

    module Javascript::Host # :nodoc: all
      MAX_ACTIVE_PROGRAMS = 8
      MAX_SOURCE_BYTES = 1024 * 1024
      CONTEXT_MEMORY_BYTES = 64 * 1024 * 1024
      JAVASCRIPT_TIMEOUT_MS = 10_000
      MAX_PENDING_TOOL_CALLS = 1_024
      Terminated = Class.new(StandardError)
      DEFAULT_MESSAGES = {
        "execution_limit" => "JavaScript execution exceeded its limit.",
        "memory_limit" => "JavaScript execution exceeded its memory limit.",
        "cleanup_failed" => "JavaScript context cleanup failed.",
        "pending_calls_limit" => "The code-mode program exceeded the pending Tool-call limit.",
        "active_programs_limit" => "The code-mode host has too many active programs.",
        "invalid_request" => "Invalid code-mode request: __DETAIL__",
        "unavailable_tool" => "Unavailable code-mode Tool: __TOOL_NAME__",
        "execution_failed" => "__ERROR_CLASS__: __ERROR_MESSAGE__",
        "source_size_limit" => "Code-mode source exceeds the size limit.",
        "tools_array" => "Code-mode tools must be an array."
      }.freeze

      BOOTSTRAP = <<~'JAVASCRIPT'
        const __LITTLE_GHOST_CONTROL_IDENTIFIER__ = (() => {
          "use strict";
          const definitions = __LITTLE_GHOST_TOOL_DEFINITIONS__;
          const definitionIndex = Object.fromEntries(definitions.map((definition) => [definition.name, definition]));
          const calls = [];
          const outputs = [];
          const pending = new Map();
          const exitSignal = Object.freeze({exit: true});
          const unavailableToolMessage = __LITTLE_GHOST_UNAVAILABLE_TOOL_MESSAGE__;
          let nextCallId = 0;
          let done = false;
          let failure = null;

          const stringify = (value) => {
            if (typeof value === "string") return value;
            if (value === undefined) return "undefined";
            if (typeof value === "bigint") return value.toString();
            const encoded = JSON.stringify(value);
            return encoded === undefined ? String(value) : encoded;
          };

          const enqueue = (name, args) => new Promise((resolve, reject) => {
            if (!Object.prototype.hasOwnProperty.call(definitionIndex, name)) {
              reject(new Error(unavailableToolMessage.split("__TOOL_NAME__").join(name)));
              return;
            }
            const id = String(++nextCallId);
            pending.set(id, {resolve, reject});
            calls.push({call_id: id, name, arguments: args === undefined ? {} : args});
          });

          const tools = new Proxy(Object.freeze(Object.create(null)), {
            get(_target, property) {
              if (property === "then") return undefined;
              if (typeof property !== "string") return undefined;
              return (args = {}) => enqueue(property, args);
            }
          });
          const catalog = definitions.map(({name, description}) => Object.freeze({name, description}));

          const text = (value) => { outputs.push(stringify(value)); };
          const exit = () => { throw exitSignal; };
          const errorText = (error) => {
            if (error && typeof error.stack === "string") return error.stack;
            if (error && typeof error.message === "string") return error.message;
            return stringify(error);
          };

          Object.defineProperties(globalThis, {
            tools: {value: tools, writable: false, configurable: false},
            ALL_TOOLS: {value: Object.freeze(catalog), writable: false, configurable: false},
            text: {value: text, writable: false, configurable: false},
            exit: {value: exit, writable: false, configurable: false},
            console: {value: undefined, writable: false, configurable: false},
            process: {value: undefined, writable: false, configurable: false},
            require: {value: undefined, writable: false, configurable: false},
            fetch: {value: undefined, writable: false, configurable: false},
            WebAssembly: {value: undefined, writable: false, configurable: false},
            ArrayBuffer: {value: undefined, writable: false, configurable: false},
            SharedArrayBuffer: {value: undefined, writable: false, configurable: false},
            DataView: {value: undefined, writable: false, configurable: false},
            Atomics: {value: undefined, writable: false, configurable: false},
            Int8Array: {value: undefined, writable: false, configurable: false},
            Uint8Array: {value: undefined, writable: false, configurable: false},
            Uint8ClampedArray: {value: undefined, writable: false, configurable: false},
            Int16Array: {value: undefined, writable: false, configurable: false},
            Uint16Array: {value: undefined, writable: false, configurable: false},
            Int32Array: {value: undefined, writable: false, configurable: false},
            Uint32Array: {value: undefined, writable: false, configurable: false},
            BigInt64Array: {value: undefined, writable: false, configurable: false},
            BigUint64Array: {value: undefined, writable: false, configurable: false},
            Float32Array: {value: undefined, writable: false, configurable: false},
            Float64Array: {value: undefined, writable: false, configurable: false}
          });

          return Object.freeze({
            drain: () => ({
              calls: calls.splice(0),
              outputs: outputs.splice(0),
              done,
              failure
            }),
            resolve: (id, ok, value) => {
              const continuation = pending.get(String(id));
              if (!continuation) return false;
              pending.delete(String(id));
              if (ok) continuation.resolve(value);
              else continuation.reject(new Error(String(value)));
              return true;
            },
            run: (source) => {
              let execution;
              try {
                execution = (0, eval)(`(async () => {\n${source}\n})()`);
              } catch (error) {
                done = true;
                failure = errorText(error);
                return;
              }
              Promise.resolve(execution).then(
                () => { done = true; },
                (error) => {
                  done = true;
                  failure = error === exitSignal ? null : errorText(error);
                }
              );
            },
          });
        })();
      JAVASCRIPT

      class Program
        def initialize(id:, source:, tools:, writer:, finished:, messages: nil)
          @id = id
          @source = source
          @tools = tools
          @messages = DEFAULT_MESSAGES.merge(messages || {}).freeze
          @writer = writer
          @finished = finished
          @incoming = Queue.new
          @context_mutex = Mutex.new
          @context = nil
          @control_identifier = "__littleGhost_control_#{SecureRandom.hex(32)}"
          @terminating = false
          @thread = Thread.new { run }
          @thread.report_on_exception = false
        end

        def deliver(message)
          @incoming << message
        end

        def terminate
          @incoming << {"type" => "terminate"}
          context = @context_mutex.synchronize do
            @terminating = true
            @context
          end
          context&.stop
        rescue MiniRacer::ContextDisposedError
          nil
        end

        def join(timeout = nil)
          @thread.join(timeout)
        end

        private

        def run
          context = MiniRacer::Context.new(
            max_memory: CONTEXT_MEMORY_BYTES,
            timeout: JAVASCRIPT_TIMEOUT_MS
          )
          @context_mutex.synchronize { @context = context }
          definitions = JSON.generate(@tools)
          context.eval(
            BOOTSTRAP
              .gsub("__LITTLE_GHOST_CONTROL_IDENTIFIER__", @control_identifier)
              .sub("__LITTLE_GHOST_TOOL_DEFINITIONS__", definitions)
              .sub(
                "__LITTLE_GHOST_UNAVAILABLE_TOOL_MESSAGE__",
                JSON.generate(@messages.fetch("unavailable_tool"))
              ),
            filename: "little-ghost-code-mode-bootstrap.js"
          )
          call_control(context, :run, @source)
          terminal = pump(context)
        rescue Terminated
          terminal = {type: "terminated"}
        rescue MiniRacer::ScriptTerminatedError
          terminal = if @context_mutex.synchronize { @terminating }
            {type: "terminated"}
          else
            {type: "failed", error: @messages.fetch("execution_limit"), fatal: true}
          end
        rescue MiniRacer::V8OutOfMemoryError
          terminal = {type: "failed", error: @messages.fetch("memory_limit"), fatal: true}
        rescue => error
          failure = @messages.fetch("execution_failed")
            .gsub("__ERROR_CLASS__") { error.class.to_s }
            .gsub("__ERROR_MESSAGE__") { error.message }
          terminal = {type: "failed", error: failure, fatal: true}
        ensure
          cleanup_error = dispose_context
          terminal = {type: "failed", error: @messages.fetch("cleanup_failed"), fatal: true} if cleanup_error
          begin
            emit(**terminal) if terminal
          ensure
            @finished.call(@id)
          end
        end

        def pump(context)
          loop do
            state = call_control(context, :drain)
            Array(state["outputs"]).each { |value| emit(type: "output", value:) }
            calls = Array(state["calls"])
            if calls.length > MAX_PENDING_TOOL_CALLS
              return {
                type: "failed",
                error: @messages.fetch("pending_calls_limit"),
                fatal: true
              }
            end
            emit(type: "tool_calls", calls:) unless calls.empty?
            unless calls.empty?
              wait_for_results(context, calls.length)
              next
            end

            if state["done"]
              if state["failure"]
                return {type: "failed", error: state["failure"]}
              else
                return {type: "complete"}
              end
            end

            wait_for_results(context, 0)
          end
        end

        def wait_for_results(context, expected)
          delivered = 0
          loop do
            message = @incoming.pop(timeout: 0.05)
            next unless message
            return terminate_program if message["type"] == "terminate"

            call_control(
              context, :resolve, message.fetch("call_id"), message.fetch("ok"),
              message["ok"] ? message["value"] : message["error"]
            )
            delivered += 1
            break if delivered >= expected
          end
        end

        def terminate_program
          raise Terminated
        end

        def dispose_context
          context = @context_mutex.synchronize do
            @context.tap { @context = nil }
          end
          context&.dispose
          nil
        rescue MiniRacer::ContextDisposedError
          nil
        rescue => error
          error
        end

        def call_control(context, method, *arguments)
          encoded_arguments = arguments.map { |argument| JSON.generate(argument) }.join(",")
          context.eval("#{@control_identifier}.#{method}(#{encoded_arguments})")
        end

        def emit(type:, **attributes)
          @writer.call(type:, program_id: @id, **attributes)
        end
      end

      class Runner
        def initialize(input: $stdin, output: $stdout)
          @input = input
          @output = output
          @programs = {}
          @programs_mutex = Mutex.new
          @writer_mutex = Mutex.new
        end

        def run
          while (message = Protocol.read(@input))
            receive(message)
          end
        ensure
          programs = @programs_mutex.synchronize { @programs.values.dup }
          programs.each(&:terminate)
          programs.each { |program| program.join(0.5) }
        end

        private

        def receive(message)
          case message["type"]
          when "execute" then execute(message)
          when "tool_result" then program(message.fetch("program_id"))&.deliver(message)
          when "terminate" then program(message.fetch("program_id"))&.terminate
          else raise Protocol::Error, "Unknown code-mode host request"
          end
        end

        def execute(message)
          id = message.fetch("program_id").to_s
          source = message.fetch("source").to_s
          tools = message.fetch("tools")
          messages = DEFAULT_MESSAGES.merge(message["messages"] || {})
          raise Protocol::Error, messages.fetch("source_size_limit") if source.bytesize > MAX_SOURCE_BYTES
          raise Protocol::Error, messages.fetch("tools_array") unless tools.is_a?(Array)

          created = @programs_mutex.synchronize do
            next false if @programs.key?(id) || @programs.length >= MAX_ACTIVE_PROGRAMS

            @programs[id] = Program.new(
              id:, source:, tools:, messages:, writer: method(:write),
              finished: ->(program_id) { @programs_mutex.synchronize { @programs.delete(program_id) } }
            )
            true
          end
          unless created
            write(type: "failed", program_id: id, error: messages.fetch("active_programs_limit"), fatal: true)
          end
        rescue KeyError, TypeError, Protocol::Error => error
          template = messages.fetch("invalid_request")
          detail = error.message
          write(type: "failed", program_id: id.to_s, error: template.gsub("__DETAIL__") { detail }, fatal: true)
        end

        def program(id)
          @programs_mutex.synchronize { @programs[id.to_s] }
        end

        def write(message)
          @writer_mutex.synchronize { Protocol.write(@output, message) }
        end
      end

      module_function

      def run
        MiniRacer::Platform.set_flags!(:jitless)
        Runner.new.run
      end
    end
  end
end
