# frozen_string_literal: true

require "fileutils"
require "json"
require "securerandom"
require "socket"

module LittleGhost
  module Harnesses
    # Serves Tool instances to a harness over the Model Context Protocol's
    # Streamable HTTP transport on a Unix socket, so a coding-agent tool can
    # call the same tools as the Agent that delegated to it.
    #
    #   registry = LittleGhost::ToolRegistry.new([HelpCenterLookupTool], binding:)
    #   server = LittleGhost::Harnesses::ToolServer.new(
    #     tools: registry,
    #     socket_path: "/run/harness-tools/tools.sock",
    #     context:
    #   ).start
    #   # The harness reaches the socket through a relay at http://127.0.0.1:3133/mcp.
    #   server.close
    #
    # Each call runs Tool#execute with +context+, so the Run's cancellation and
    # deadline stop it, and returns the tool's content as text with +isError+
    # set for failed calls. The server answers +initialize+, +ping+,
    # +tools/list+, and +tools/call+ with JSON responses and accepts
    # notifications; it does not open server-to-client streams.
    #
    # Anyone who can connect to the socket can call every served tool, so keep
    # +socket_path+ in a directory that only the harness can reach.
    # Harnesses::Tool#serve_tools starts one server per delegated task.
    class ToolServer
      ENDPOINT = "/mcp"
      PROTOCOL_VERSIONS = %w[2025-06-18 2025-03-26 2024-11-05].freeze # :nodoc:
      MAX_HEADER_BYTES = 32_768 # :nodoc:
      MAX_BODY_BYTES = 4 * 1024 * 1024 # :nodoc:
      MAX_CLIENTS = 32 # :nodoc:
      READ_TIMEOUT = 30 # :nodoc:
      SHUTDOWN_TIMEOUT = 1 # :nodoc:
      POLL_INTERVAL = 0.2 # :nodoc:

      # Builds a server for +tools+, a ToolRegistry or Array of Tool
      # instances, listening at +socket_path+ with permission bits +mode+.
      # +name+ is reported to clients as the server's name.
      def initialize(tools:, socket_path:, context: nil, name: "little_ghost", mode: 0o600)
        @tools = tools.to_h { |tool| [tool.tool_name, tool] }.freeze
        @socket_path = String(socket_path)
        raise ArgumentError, "tool server socket_path must be absolute" unless @socket_path.start_with?("/")

        @context = context
        @name = String(name)
        @mode = Integer(mode)
        @mutex = Mutex.new
        @clients = []
        @workers = []
        @stopping = false
      end

      # Filesystem path of the listening socket.
      attr_reader :socket_path

      # Binds the socket and serves requests on a background thread. Returns
      # +self+; call #close to stop.
      def start
        bind
        @thread = Thread.new { accept_loop }
        self
      end

      # Stops accepting, closes open connections, waits briefly for in-flight
      # calls, and removes the socket. Calling +close+ more than once is safe.
      def close
        @stopping = true
        @server&.close unless @server&.closed?
        clients, workers = @mutex.synchronize { [@clients.dup, @workers.dup] }
        clients.each { |client| client.close unless client.closed? }
        workers.each do |worker|
          next if worker.join(SHUTDOWN_TIMEOUT)

          worker.kill
          worker.join
        end
        @thread&.join unless @thread == Thread.current
        remove_socket if @bound
        @bound = false
        nil
      end

      private

      # The socket is created in a private directory with its final mode and
      # then renamed, so it is never reachable with wider permissions.
      def bind
        staging = File.join(File.dirname(socket_path), ".#{SecureRandom.hex(4)}")
        Dir.mkdir(staging, 0o700)
        staged = File.join(staging, "s")
        @server = UNIXServer.new(staged)
        @server.listen(MAX_CLIENTS)
        File.chmod(@mode, staged)
        File.rename(staged, socket_path)
        @bound = true
      rescue
        @server&.close
        @server = nil
        raise
      ensure
        FileUtils.remove_entry_secure(staging) if staging && File.exist?(staging)
      end

      def remove_socket
        stat = File.lstat(socket_path)
        File.unlink(socket_path) if stat.socket? && stat.uid == Process.euid
      rescue Errno::ENOENT
        nil
      end

      def accept_loop
        loop do
          break if @stopping

          ready, = IO.select([@server], nil, nil, POLL_INTERVAL)
          next unless ready

          client = @server.accept_nonblock(exception: false)
          next if client == :wait_readable

          accepted = @mutex.synchronize do
            next false if @clients.length >= MAX_CLIENTS

            @clients << client
            @workers << Thread.new(client) { |connection| handle(connection) }
            true
          end
          client.close unless accepted
        rescue IOError, Errno::EBADF
          break if @stopping
          raise
        end
      end

      def handle(client)
        method, path, body = read_request(client)
        if path.split("?", 2).first != ENDPOINT
          respond(client, 404)
        elsif method != "POST"
          respond(client, 405, headers: {"allow" => "POST"})
        else
          message = parse(body)
          if message.nil?
            respond(client, 400, body: {jsonrpc: "2.0", id: nil, error: {code: -32_700, message: "Parse error"}})
          elsif (reply = dispatch(message))
            respond(client, 200, body: reply)
          else
            respond(client, 202)
          end
        end
      rescue ArgumentError
        respond(client, 400)
      rescue IOError, SystemCallError
        nil
      ensure
        client.close unless client.closed?
        @mutex.synchronize do
          @clients.delete(client)
          @workers.delete(Thread.current)
        end
      end

      def parse(body)
        message = JSON.parse(body)
        message if message.is_a?(Hash)
      rescue JSON::ParserError
        nil
      end

      # Returns the JSON-RPC response for +message+, or nil for notifications
      # and client responses, which need only an acknowledgement.
      def dispatch(message)
        return unless message.key?("id") && message["method"].is_a?(String)

        id = message["id"]
        params = message["params"].is_a?(Hash) ? message["params"] : {}
        result = case message["method"]
        when "initialize" then initialize_result(params)
        when "ping" then {}
        when "tools/list" then {tools: @tools.values.map { |tool| definition(tool) }}
        when "tools/call" then call_tool(params)
        else return {jsonrpc: "2.0", id:, error: {code: -32_601, message: "Method not found"}}
        end
        {jsonrpc: "2.0", id:, result:}
      rescue ToolError => error
        {jsonrpc: "2.0", id:, error: {code: -32_602, message: error.message}}
      rescue CancelledError, DeadlineExceededError
        {jsonrpc: "2.0", id:, error: {code: -32_000, message: "The run stopped before the tool finished."}}
      end

      def initialize_result(params)
        requested = params["protocolVersion"]
        {
          protocolVersion: PROTOCOL_VERSIONS.include?(requested) ? requested : PROTOCOL_VERSIONS.first,
          capabilities: {tools: {listChanged: false}},
          serverInfo: {name: @name, version: LittleGhost::VERSION}
        }
      end

      def definition(tool)
        {name: tool.tool_name, description: tool.description, inputSchema: tool.input_schema}
      end

      def call_tool(params)
        tool = @tools.fetch(params["name"].to_s) { raise ToolError, "Unknown tool: #{params["name"]}" }
        arguments = params.fetch("arguments", nil) || {}
        raise ToolError, "Tool arguments must be an object" unless arguments.is_a?(Hash)

        result = tool.execute(arguments, context: @context)
        {content: [{type: "text", text: text(result.content)}], isError: result.error?}
      end

      def text(content)
        content.is_a?(String) ? content : JSON.generate(content)
      rescue JSON::GeneratorError
        content.to_s
      end

      def read_request(client)
        deadline = monotonic_time + READ_TIMEOUT
        buffer = +"".b
        until (index = buffer.index("\r\n\r\n"))
          raise ArgumentError, "request headers are too large" if buffer.bytesize > MAX_HEADER_BYTES

          buffer << read_chunk(client, deadline)
        end
        head = buffer.slice!(0, index + 4)
        request_line, *header_lines = head.force_encoding(Encoding::UTF_8).scrub.split("\r\n")
        method, path, version = request_line.to_s.split(" ", 3)
        raise ArgumentError, "invalid request line" unless method && path && version&.start_with?("HTTP/")

        headers = header_lines.to_h do |line|
          name, value = line.split(":", 2)
          raise ArgumentError, "invalid header" unless name && value

          [name.strip.downcase, value.strip]
        end
        raise ArgumentError, "chunked request bodies are not supported" if headers.key?("transfer-encoding")

        length = Integer(headers.fetch("content-length", "0"), 10)
        raise ArgumentError, "request body is too large" if length.negative? || length > MAX_BODY_BYTES

        buffer << read_chunk(client, deadline) while buffer.bytesize < length
        [method, path, buffer.byteslice(0, length).force_encoding(Encoding::UTF_8)]
      end

      def read_chunk(client, deadline)
        loop do
          remaining = deadline - monotonic_time
          raise ArgumentError, "request timed out" if remaining <= 0

          chunk = client.read_nonblock(16_384, exception: false)
          case chunk
          when :wait_readable then IO.select([client], nil, nil, remaining)
          when nil then raise ArgumentError, "incomplete request"
          else return chunk
          end
        end
      end

      def respond(client, status, body: nil, headers: {})
        reason = {200 => "OK", 202 => "Accepted", 400 => "Bad Request", 404 => "Not Found", 405 => "Method Not Allowed"}
        payload = body ? JSON.generate(body) : ""
        client.write(
          "HTTP/1.1 #{status} #{reason.fetch(status)}\r\n",
          *(body ? ["content-type: application/json\r\n"] : []),
          *headers.map { |name, value| "#{name}: #{value}\r\n" },
          "content-length: #{payload.bytesize}\r\nconnection: close\r\n\r\n",
          payload
        )
      end

      def monotonic_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
