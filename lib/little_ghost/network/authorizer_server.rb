# frozen_string_literal: true

require "fileutils"
require "securerandom"
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
    #     mode: 0o660,
    #     peer_uids: [Etc.getpwnam("envoy").uid]
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
    #
    # The server answers only authorization requests that come from a listener
    # in a configuration written by EnvoyGateway: Envoy prefixes each request
    # path with the listener's origin, which tells the server whether the
    # destination comes from the inspected request's +Host+ or from a facade's
    # fixed upstream. Any other request is denied with status 503 without
    # calling +authorizer+.
    class AuthorizerServer
      MAX_HEADER_BYTES = 32_768 # :nodoc:
      MAX_CLIENTS = 64 # :nodoc:
      READ_TIMEOUT = 5 # :nodoc:
      SHUTDOWN_TIMEOUT = 1 # :nodoc:
      POLL_INTERVAL = 0.2 # :nodoc:
      ALWAYS_REMOVE = (
        CREDENTIAL_HEADERS + %w[x-forwarded-for x-forwarded-host x-forwarded-proto]
      ).freeze # :nodoc:
      ACCEPT_RETRY_ERRORS = [Errno::EMFILE, Errno::ENFILE, Errno::ENOBUFS, Errno::ENOMEM, Errno::ECONNABORTED, Errno::EINTR].freeze # :nodoc:

      # Builds a server for +socket_path+. +mode+ sets the socket's permission
      # bits so a separate Envoy user can connect. The socket is created in a
      # private directory, given +mode+, and then moved to +socket_path+, so it
      # never has wider permissions; an existing socket, file, or symbolic link
      # at +socket_path+ is replaced. Keep +socket_path+ in a directory that only
      # Envoy and the authorizer can reach.
      #
      # +peer_uids+ lists the user IDs allowed to connect; connections from any
      # other user are closed without a response. +nil+ accepts any peer that
      # can open the socket. Peer IDs are read in the authorizer's own user
      # namespace: when the authorizer runs inside a separate namespace, such as
      # a Bubblewrap sandbox, unmapped peers appear as the overflow user, so rely
      # on directory and group permissions instead.
      def initialize(socket_path:, authorizer:, run: nil, mode: 0o600, peer_uids: nil)
        @socket_path = socket_path
        @authorizer = authorizer
        @run = run
        @mode = Integer(mode)
        @peer_uids = peer_uids&.map { |uid| Integer(uid) }&.freeze
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
        remove_socket if @bound
        @bound = false
        nil
      end

      private

      def bind
        candidate = File.join(File.dirname(socket_path), ".#{SecureRandom.hex(4)}")
        Dir.mkdir(candidate, 0o700)
        staging = candidate
        staged = File.join(staging, "s")
        @server = UNIXServer.new(staged)
        @server.listen(128)
        File.chmod(@mode, staged)
        File.rename(staged, socket_path)
        @bound = true
        stat = File.lstat(socket_path)
        unless stat.socket? && stat.uid == Process.euid && (stat.mode & 0o7777) == @mode
          raise PolicyError, "authorizer socket #{socket_path} was replaced while it was created"
        end
      rescue
        @server&.close
        @server = nil
        raise
      ensure
        FileUtils.remove_entry_secure(staging) if staging
      end

      def remove_socket
        stat = File.lstat(socket_path)
        File.unlink(socket_path) if stat.socket? && stat.uid == Process.euid
      rescue Errno::ENOENT
        nil
      end

      def accept_loop(stop_io: nil)
        loop do
          break if @stopping

          if stop_io
            ready, = IO.select([@server, stop_io], nil, nil, POLL_INTERVAL)
            next unless ready
            break if ready.include?(stop_io)
          end
          client = begin
            @server.accept
          rescue *ACCEPT_RETRY_ERRORS
            sleep(POLL_INTERVAL)
            next
          end
          unless peer_allowed?(client)
            client.close
            next
          end
          accepted = @mutex.synchronize do
            next false if @clients.length >= MAX_CLIENTS

            @clients << client
            true
          end
          unless accepted
            client.close
            next
          end
          @mutex.synchronize { @workers << Thread.new(client) { |connection| handle(connection) } }
        rescue IOError, Errno::EBADF
          break if @stopping
          raise
        end
      end

      def peer_allowed?(client)
        return true unless @peer_uids

        uid, = client.getpeereid
        @peer_uids.include?(uid)
      rescue SystemCallError, NotImplementedError
        false
      end

      def handle(client)
        method, check_path, headers = read_request(client)
        upstream, path = origin(check_path, headers)
        host, port = authority(upstream)
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

      def origin(check_path, headers)
        if check_path.start_with?("#{EnvoyConfig::INSPECTED_AUTHORIZATION_PREFIX}/")
          [headers.fetch("host", ""), check_path.delete_prefix(EnvoyConfig::INSPECTED_AUTHORIZATION_PREFIX)]
        elsif check_path.start_with?(EnvoyConfig::FACADE_AUTHORIZATION_PREFIX)
          upstream, rest = check_path.delete_prefix(EnvoyConfig::FACADE_AUTHORIZATION_PREFIX).split("/", 2)
          raise ArgumentError, "invalid facade authorization request" unless upstream && rest

          [upstream, "/#{rest}"]
        else
          raise ArgumentError, "authorization request did not come from a gateway listener"
        end
      end

      def read_request(client)
        reader = LineReader.new(client, deadline: monotonic_time + READ_TIMEOUT)
        request_line = reader.line
        method, path, version = request_line.strip.split(" ", 3)
        raise ArgumentError, "invalid authorization request" unless method && path && version&.start_with?("HTTP/")

        headers = {}
        loop do
          line = reader.line
          break if line == "\r\n" || line == "\n"

          name, value = line.split(":", 2)
          raise ArgumentError, "invalid authorization header" unless name && value

          headers[name.strip.downcase] = value.strip
        end
        [method, path, headers]
      end

      def monotonic_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      class LineReader # :nodoc:
        def initialize(client, deadline:)
          @client = client
          @deadline = deadline
          @buffer = +"".b
          @consumed = 0
        end

        def line
          loop do
            if (index = @buffer.index("\n"))
              line = @buffer.slice!(0, index + 1)
              @consumed += line.bytesize
              raise ArgumentError, "authorization headers are too large" if @consumed > MAX_HEADER_BYTES

              return line
            end
            raise ArgumentError, "authorization headers are too large" if @consumed + @buffer.bytesize >= MAX_HEADER_BYTES

            fill
          end
        end

        private

        def fill
          remaining = @deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          raise Timeout::Error, "authorization request timed out" if remaining <= 0

          chunk = @client.read_nonblock(4096, exception: false)
          case chunk
          when :wait_readable
            raise Timeout::Error, "authorization request timed out" unless IO.select([@client], nil, nil, remaining)
          when nil
            raise ArgumentError, "incomplete authorization request"
          else
            @buffer << chunk
          end
        end
      end
      private_constant :LineReader

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
