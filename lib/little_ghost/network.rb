# frozen_string_literal: true

module LittleGhost
  # Network policy helpers used by sandbox backends. These controls apply only
  # to processes launched through the sandbox, not to providers or Ruby Tools.
  # A proxy enforces policy only when the Sandbox blocks every direct socket path.
  module Network
    # Header names treated as client credentials. Gateways never forward them
    # to an authorizer and remove them from upstream requests unless the
    # authorizer sets them.
    CREDENTIAL_HEADERS = %w[authorization proxy-authorization cookie x-api-key api-key x-auth-token x-goog-api-key].freeze

    # Normalized, headers-only request metadata passed to a trusted authorizer.
    class Request < Data.define(:method, :scheme, :host, :port, :path, :headers)
      # Builds normalized request metadata without a body.
      def initialize(method:, scheme:, host:, port:, path:, headers: {})
        super(
          method: String(method).upcase.freeze,
          scheme: String(scheme).downcase.freeze,
          host: String(host).downcase.freeze,
          port: Integer(port),
          path: String(path).freeze,
          headers: headers.to_h { |name, value| [String(name).downcase.freeze, String(value).freeze] }.freeze
        )
      end
    end

    # Trusted authorization result and tightly scoped upstream header changes.
    class Decision < Data.define(:allowed, :status, :reason, :set_headers, :remove_headers)
      HEADER_NAME = /\A[a-z0-9!#$%&'*+.^_`|~-]+\z/ # :nodoc:
      FORBIDDEN_MUTATIONS = %w[host connection content-length transfer-encoding upgrade proxy-connection].freeze # :nodoc:

      # Allows a request and optionally changes its upstream headers.
      def self.allow(set_headers: {}, remove_headers: [])
        new(allowed: true, status: 200, reason: nil, set_headers:, remove_headers:)
      end

      # Rejects a request with an HTTP +status+ and optional safe reason.
      def self.deny(status: 403, reason: nil)
        new(allowed: false, status:, reason:, set_headers: {}, remove_headers: [])
      end

      # Builds a normalized trusted authorization decision.
      def initialize(allowed:, status:, reason: nil, set_headers: {}, remove_headers: [])
        super(
          allowed: !!allowed,
          status: Integer(status),
          reason: reason&.to_s&.freeze,
          set_headers: normalize_headers(set_headers),
          remove_headers: Array(remove_headers).map { |name| normalize_header_name(name) }.uniq.freeze
        )
      end

      private

      def normalize_headers(headers)
        headers.to_h do |name, value|
          name = normalize_header_name(name)
          value = String(value)
          raise PolicyError, "network header values cannot contain control characters" if value.match?(/[\x00-\x1f\x7f]/)

          [name, value.freeze]
        end.freeze
      end

      def normalize_header_name(name)
        name = String(name).downcase
        if !HEADER_NAME.match?(name) || FORBIDDEN_MUTATIONS.include?(name) || name.start_with?("x-envoy-")
          raise PolicyError, "network authorizer returned an unsafe header mutation"
        end

        name.freeze
      end
    end

    # A plaintext listener that forwards every request to one HTTPS host.
    #
    # A facade gives a client that honors a base URL, such as a command-line
    # tool pointed at <tt>http://127.0.0.1:3130</tt>, a way to reach exactly one
    # upstream without trusting a proxy certificate. The gateway originates TLS
    # to +upstream+ and asks the policy's authorizer about every request before
    # forwarding it, so the authorizer can restrict methods and paths and
    # replace a placeholder credential with a real one. Responses stream back
    # without buffering.
    #
    #   LittleGhost::Network::Facade.new(
    #     name: :help_center,
    #     upstream: "api.example.com",
    #     port: 3130,
    #     timeout: 0
    #   )
    #
    # Exactly one of +port+ or +socket+ is required. +port+ listens on
    # <tt>127.0.0.1</tt>; +socket+ is an absolute Unix socket path that the
    # application makes reachable from the sandbox. +timeout+ bounds each
    # request in seconds; +0+ disables the bound for streaming responses, and
    # +nil+ uses the policy's timeout for the upstream host or no bound.
    class Facade < Data.define(:name, :upstream, :port, :socket, :timeout)
      NAME = /\A[a-z][a-z0-9_]{0,62}\z/ # :nodoc:

      # Returns +value+ unchanged or builds a facade from a Hash.
      def self.coerce(value)
        return value if value.is_a?(self)
        raise PolicyError, "network facades must be Hashes or LittleGhost::Network::Facade values" unless value.is_a?(Hash)

        new(**value.transform_keys(&:to_sym))
      end

      # Builds a normalized facade declaration.
      def initialize(name:, upstream:, port: nil, socket: nil, timeout: nil)
        name = String(name)
        raise PolicyError, "network facade names must be lowercase identifiers" unless NAME.match?(name)
        raise PolicyError, "network facades require exactly one of port or socket" if port.nil? == socket.nil?

        upstream = String(upstream)
        upstream = "#{upstream}:443" unless upstream.match?(/:\d+\z/)
        host, upstream_port = EnvoyConfig.parse_endpoint(upstream)
        if !port.nil? && !(port.is_a?(Integer) && port.between?(1, 65_535))
          raise PolicyError, "network facade ports must be integers between 1 and 65535"
        end
        unless socket.nil?
          socket = String(socket)
          raise PolicyError, "network facade sockets must be absolute paths" unless socket.start_with?("/")
        end
        super(
          name: name.freeze,
          upstream: "#{host}:#{upstream_port}".freeze,
          port:,
          socket: socket&.freeze,
          timeout: timeout.nil? ? nil : Network.timeout_seconds(timeout)
        )
      end

      # The upstream DNS name without its port.
      def host = upstream.rpartition(":").first

      # The upstream TLS port.
      def upstream_port = Integer(upstream.rpartition(":").last)
    end

    def self.timeout_seconds(value) # :nodoc:
      seconds = Float(value)
      raise PolicyError, "network timeouts must be finite and non-negative" unless seconds.finite? && seconds >= 0

      (seconds == seconds.floor) ? seconds.to_i : seconds
    rescue ArgumentError, TypeError
      raise PolicyError, "network timeouts must be numbers of seconds"
    end

    # Lifecycle contract implemented by filtered-egress gateways. A Gateway is
    # one part of enforcement; the Sandbox must also prevent direct networking.
    class Gateway
      # Builds a gateway for a normalized network +policy+.
      def initialize(policy:)
        @policy = policy
      end

      # Network policy enforced by this gateway.
      attr_reader :policy

      # Starts run-scoped gateway resources.
      def open(run: nil) = self
      # Stops owned resources. Calling +close+ more than once must be safe.
      def close = nil
      # Fails closed when the gateway is no longer ready for a child process.
      def validate! = self
      # Returns child-process proxy and trust environment variables.
      def environment = {}.freeze
      # Returns read-only mounts required by child processes.
      def mounts = [].freeze
      # Returns an isolated container network name when applicable.
      def client_network = nil
    end
  end
end

require_relative "network/envoy_config"
require_relative "network/host_policy"
