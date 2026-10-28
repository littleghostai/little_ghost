# frozen_string_literal: true

require "socket"
require "timeout"
require "uri"
require_relative "../network"

module LittleGhost
  module Network
    # Answers Envoy's headers-only external authorization requests on a Unix
    # socket by calling a trusted authorizer.
    #
    # EnvoyGateway starts one for each run that needs it. An application that
    # supervises Envoy itself can run the server in a separate, less privileged
    # process so credentials stay out of both the sandbox and Envoy:
    #
    #   hosts = LittleGhost::Network::HostPolicy.new do
    #     host("api.example.com") { inject { {"x-api-key" => ENV.fetch("HELP_CENTER_API_KEY")} } }
    #   end
    #   server = LittleGhost::Network::AuthorizerServer.new(
    #     socket_path: "/run/egress-private/authorizer.sock",
    #     authorizer: hosts.authorizer,
    #     mode: 0o660
    #   )
    #   stop_reader, stop_writer = IO.pipe
    #   Signal.trap("TERM") { stop_writer.write_nonblock(".", exception: false) }
    #   server.serve(stop_io: stop_reader)
    #
    # +authorizer+ receives <tt>request:</tt>, a Network::Request, and an
    # optional <tt>run:</tt> keyword, and returns a Network::Decision. It may be
    # called from several threads at once. An exception or any other return
    # value denies the request with status 503; the response never includes
    # the exception message.
    #
    # Every allowed request also loses its Network::CREDENTIAL_HEADERS and
    # forwarding headers unless the decision sets them.
    class AuthorizerServer
      MAX_HEADER_BYTES = 32_768 # :nodoc:
      MAX_CLIENTS = 64 # :nodoc:
      READ_TIMEOUT = 5 # :nodoc:
      SHUTDOWN_TIMEOUT = 1 # :nodoc:
      POLL_INTERVAL = 0.2 # :nodoc:
      ALWAYS_REMOVE = (
        CREDENTIAL_HEADERS + %w[x-forwarded-for x-forwarded-host x-forwarded-proto] + [EnvoyConfig::FACADE_UPSTREAM_HEADER]
      ).freeze # :nodoc:

      # Builds a server for +socket_path+. +mode+ sets the socket's permission
      # bits so a separate Envoy user can connect.
      def initialize(socket_path:, authorizer:, run: nil, mode: 0o600)
        @socket_path = socket_path
        @authorizer = authorizer
        @run = run
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

      # Binds the socket when needed and serves requests on the calling thread
      # until +stop_io+ becomes readable or #close is called, then closes the
      # server. Use it as the main loop of a standalone authorizer process.
      def serve(stop_io: nil)
        bind unless @server
        accept_loop(stop_io:)
        nil
      ensure
        close
      end

      # Stops accepting, closes open connections, waits briefly for in-flight
      # requests, and removes the socket. Calling +close+ more than once is safe.
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
        File.unlink(socket_path) if File.exist?(socket_path)
        nil
      end

      private

      def bind
        File.unlink(socket_path) if File.exist?(socket_path)
        @server = UNIXServer.new(socket_path)
        @server.listen(128)
        File.chmod(@mode, socket_path)
      end

      def accept_loop(stop_io: nil)
        loop do
          break if @stopping

          if stop_io
            ready, = IO.select([@server, stop_io], nil, nil, POLL_INTERVAL)
            next unless ready
            break if ready.include?(stop_io)
          end
          client = @server.accept
          accepted = @mutex.synchronize do
            next false if @clients.length >= MAX_CLIENTS

            @clients << client
            true
          end
          unless accepted
            client.close
            next
          end
          worker = Thread.new(client) { |connection| handle(connection) }
          @mutex.synchronize { @workers << worker }
        rescue IOError, Errno::EBADF
          break if @stopping
          raise
        end
      end

      def handle(client)
        method, path, headers = read_request(client)
        upstream = headers.delete(EnvoyConfig::FACADE_UPSTREAM_HEADER)
        host, port = authority(upstream || headers.fetch("host", ""))
        request = Request.new(
          method:,
          scheme: "https",
          host:,
          port:,
          path:,
          headers:
        )
        decision = call_authorizer(request)
        raise TypeError, "network authorizer must return LittleGhost::Network::Decision" unless decision.is_a?(Decision)

        write_response(client, decision)
      rescue => error
        write_response(client, Decision.deny(status: 503, reason: error.class.name))
      ensure
        client.close unless client.closed?
        @mutex.synchronize do
          @clients.delete(client)
          @workers.delete(Thread.current)
        end
      end

      def call_authorizer(request)
        parameters = @authorizer.method(:call).parameters
        accepts_run = parameters.any? { |kind, name| kind == :keyrest || (%i[key keyreq].include?(kind) && name == :run) }
        accepts_run ? @authorizer.call(request:, run: @run) : @authorizer.call(request:)
      end

      def read_request(client)
        total = 0
        request_line = read_line(client, total)
        total += request_line.bytesize
        method, path, version = request_line.strip.split(" ", 3)
        raise ArgumentError, "invalid authorization request" unless method && path && version&.start_with?("HTTP/")

        headers = {}
        loop do
          line = read_line(client, total)
          total += line.bytesize
          break if line == "\r\n" || line == "\n"

          name, value = line.split(":", 2)
          raise ArgumentError, "invalid authorization header" unless name && value

          headers[name.strip.downcase] = value.strip
        end
        [method, path, headers]
      end

      def read_line(client, total)
        raise ArgumentError, "authorization headers are too large" if total >= MAX_HEADER_BYTES
        raise Timeout::Error, "authorization request timed out" unless IO.select([client], nil, nil, READ_TIMEOUT)

        line = client.gets("\n", MAX_HEADER_BYTES - total + 1)
        raise ArgumentError, "incomplete authorization request" unless line
        raise ArgumentError, "authorization headers are too large" if total + line.bytesize > MAX_HEADER_BYTES

        line
      end

      def authority(value)
        uri = URI("https://#{value}")
        raise ArgumentError, "invalid request authority" unless uri.host && uri.userinfo.nil?

        [uri.host.downcase, uri.port]
      rescue URI::InvalidURIError
        raise ArgumentError, "invalid request authority"
      end

      def write_response(client, decision)
        status = decision.allowed ? 200 : decision.status
        reason = {200 => "OK", 400 => "Bad Request", 403 => "Forbidden", 429 => "Too Many Requests", 503 => "Service Unavailable"}.fetch(status, "Forbidden")
        client.write("HTTP/1.0 #{status} #{reason}\r\n")
        removals = (ALWAYS_REMOVE + decision.remove_headers).uniq - decision.set_headers.keys
        client.write("x-envoy-auth-headers-to-remove: #{removals.join(", ")}\r\n") unless removals.empty?
        decision.set_headers.each { |name, value| client.write("#{name}: #{value}\r\n") }
        client.write("content-length: 0\r\n\r\n")
      rescue IOError, Errno::EPIPE
        nil
      end
    end
  end
end
