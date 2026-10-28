# frozen_string_literal: true

require "uri"

module LittleGhost
  module Network
    # Declares which HTTPS requests each host accepts and which credentials the
    # gateway adds before forwarding them.
    #
    # A HostPolicy turns a short Ruby description into the authorizer that an
    # inspecting gateway or a Facade consults for every request. Rules match
    # exact host names; a +default+ rule covers any other host the network
    # policy lets through, and a host without a rule is denied.
    #
    #   hosts = LittleGhost::Network::HostPolicy.new do
    #     host "api.example.com" do
    #       methods :post
    #       paths "/v1/answers", "/v1/answers/*"
    #       inject { |request| {"x-api-key" => ENV.fetch("HELP_CENTER_API_KEY")} }
    #       timeout 0
    #     end
    #
    #     default do
    #       methods :get, :head
    #     end
    #   end
    #
    #   hosts.authorizer.call(request:)  # => LittleGhost::Network::Decision
    #
    # Inside +host+ and +default+ blocks:
    #
    # [<tt>methods(*names)</tt>]
    #   Accepts only these HTTP methods. Without it, every method is accepted.
    # [<tt>paths(*patterns)</tt>]
    #   Accepts only matching paths. A String matches exactly, or as a prefix
    #   when it ends in <tt>*</tt>; a Regexp matches anywhere it applies, so
    #   anchor it with <tt>\A</tt> and <tt>\z</tt> to match the whole path.
    #   Without it, every path is accepted.
    # [<tt>deny_paths(*patterns)</tt>]
    #   Rejects matching paths before +paths+ is consulted. Deny patterns also
    #   match the lowercase path.
    # [<tt>pass_headers(:all_except_credentials)</tt> or <tt>pass_headers(*names)</tt>]
    #   Chooses which client headers reach the upstream. The default passes
    #   every header except credentials. A name list removes every other
    #   header. Client credentials such as +authorization+ and +x-api-key+ never
    #   reach the upstream; use +inject+ to supply them.
    # [<tt>inject(*names) { |request| headers }</tt>]
    #   Adds the returned Hash of headers to the upstream request. Declare the
    #   names when the block sets anything other than a credential header from
    #   Network::CREDENTIAL_HEADERS.
    # [<tt>require { |request| condition }</tt>]
    #   Rejects the request unless the block returns a truthy value. Every
    #   +require+ block must pass.
    # [<tt>timeout(seconds)</tt>]
    #   Bounds each request to this host. +0+ disables the bound for streaming
    #   responses.
    #
    # Paths are matched after the query string is removed and percent-encoding
    # is decoded. A path that still contains encoded characters after three
    # rounds of decoding, a backslash, a control character such as a NUL byte
    # or line break, an empty segment, or a <tt>.</tt> or <tt>..</tt> segment
    # (including one followed by <tt>;</tt> parameters) is rejected with
    # status 400. When a rule declares +methods+, method-override headers such
    # as <tt>x-http-method-override</tt> are removed and a request with a
    # <tt>_method</tt> query parameter is rejected.
    #
    # Blocks run in the authorizer's process for every matching request, so
    # they can read a credential that changes over time. They must be
    # thread-safe. A HostPolicy never includes header values in errors or
    # decision reasons; keep credentials out of exception messages raised from
    # your own blocks as well.
    class HostPolicy
      METHOD = /\A[A-Z][A-Z-]*\z/ # :nodoc:
      HEADER = /\A[a-z0-9][a-z0-9-]*\z/ # :nodoc:
      UNMANAGED_HEADER_PREFIXES = %w[x-envoy-].freeze # :nodoc:
      UNMANAGED_HEADERS = (Decision::FORBIDDEN_MUTATIONS + %w[x-request-id x-forwarded-for x-forwarded-proto]).freeze # :nodoc:
      METHOD_OVERRIDE_HEADERS = %w[x-http-method-override x-http-method x-method-override].freeze # :nodoc:
      METHOD_OVERRIDE_PARAMETER = "_method" # :nodoc:
      CONTROL_CHARACTER = /[\x00-\x1f\x7f]/ # :nodoc:

      Rule = Data.define(:http_methods, :paths, :deny_paths, :pass_headers, :injections, :inject_headers, :requirements, :timeout) # :nodoc:

      # Builds a policy from the +host+ and +default+ declarations in the block.
      def initialize(&)
        raise PolicyError, "network host policy requires a definition block" unless block_given?

        definition = Definition.new
        definition.instance_exec(&)
        @rules = definition.rules.freeze
        @default = definition.default_rule
        raise PolicyError, "network host policy must declare at least one host or a default" if @rules.empty? && @default.nil?

        @authorizer = ->(request:) { authorize(request) }
        freeze
      end

      # Exact host names with their own rule.
      def hosts = @rules.keys

      # Returns a callable <tt>(request:) -> Decision</tt> for
      # Sandbox::NetworkPolicy and AuthorizerServer.
      attr_reader :authorizer

      # Returns the Decision for one Network::Request.
      #
      # Denials use status 403, or 400 for a path that cannot be matched safely.
      # Exceptions raised by +require+ and +inject+ blocks propagate; gateways
      # turn them into a 503 response.
      def authorize(request)
        rule = @rules.fetch(request.host, @default)
        return Decision.deny(reason: "host is not allowed") unless rule
        return Decision.deny(reason: "method is not allowed") unless rule.http_methods.nil? || rule.http_methods.include?(request.method)
        if rule.http_methods && method_override_parameter?(request.path)
          return Decision.deny(reason: "method override is not allowed")
        end

        path = canonical_path(request.path)
        return Decision.deny(status: 400, reason: "path is not canonical") unless path

        lowercase = path.downcase
        if rule.deny_paths.any? { |pattern| path_match?(pattern, path) || path_match?(pattern, lowercase, fold: true) }
          return Decision.deny(reason: "path is not allowed")
        end
        unless rule.paths.nil? || rule.paths.any? { |pattern| path_match?(pattern, path) }
          return Decision.deny(reason: "path is not allowed")
        end
        return Decision.deny(reason: "request requirement was not met") unless rule.requirements.all? { |check| check.call(request) }

        set_headers = injected_headers(rule, request)
        Decision.allow(set_headers:, remove_headers: removed_headers(rule, request, set_headers))
      end

      # Per-host request timeouts in seconds, for hosts that declare one.
      def timeouts
        @rules.filter_map { |name, rule| [name, rule.timeout] unless rule.timeout.nil? }.to_h
      end

      # Returns +:all+ when a rule needs to see every client header name to
      # remove the ones it does not pass, and otherwise an empty Array.
      def forward_headers
        rules = @rules.values + [@default].compact
        (rules.any? { |rule| rule.pass_headers.is_a?(Array) }) ? :all : []
      end

      # Header names an +inject+ block may set on an upstream request.
      def mutation_headers
        rules = @rules.values + [@default].compact
        rules.reject { |rule| rule.injections.empty? }.flat_map(&:inject_headers).uniq.sort
      end

      # Builds a Sandbox::NetworkPolicy that applies this policy.
      #
      # +allow+ lists the <tt>host:443</tt> destinations a sandboxed process
      # may reach through the explicit proxy; those requests are inspected and
      # authorized by this policy. +facades+ lists Network::Facade declarations
      # whose requests this policy also authorizes. A host can appear in this
      # policy without appearing in +allow+, which makes it reachable only
      # through a facade.
      def network_policy(allow: [], facades: [])
        Sandbox::NetworkPolicy.new(
          mode: :allowlist,
          allow:,
          inspection: Array(allow).empty? ? :connect : :http,
          authorizer:,
          forward_headers:,
          mutation_headers:,
          timeouts:,
          facades:
        )
      end

      private

      def injected_headers(rule, request)
        rule.injections.each_with_object({}) do |injection, headers|
          values = injection.call(request)
          raise PolicyError, "network host policy injection must return a Hash" unless values.is_a?(Hash)

          values.each do |name, value|
            name = String(name).downcase
            unless rule.inject_headers.include?(name)
              raise PolicyError, "network host policy injected undeclared header #{name}"
            end
            raise PolicyError, "network host policy injected an empty #{name} header" if value.nil? || String(value).empty?

            headers[name] = String(value)
          end
        end
      end

      def removed_headers(rule, request, set_headers)
        present = request.headers.keys
        removed = present.select { |name| CREDENTIAL_HEADERS.include?(name) }
        removed += present.select { |name| METHOD_OVERRIDE_HEADERS.include?(name) } if rule.http_methods
        if rule.pass_headers.is_a?(Array)
          removed += present.reject do |name|
            rule.pass_headers.include?(name) || UNMANAGED_HEADERS.include?(name) ||
              name.start_with?(*UNMANAGED_HEADER_PREFIXES)
          end
        end
        removed.uniq - set_headers.keys
      end

      def canonical_path(raw)
        path = raw.split(/[?#]/, 2).first.to_s
        3.times do
          decoded = URI.decode_uri_component(path)
          break if decoded == path

          path = decoded
        end
        return if URI.decode_uri_component(path) != path
        return unless path.valid_encoding? && path.start_with?("/")
        return if path.include?("\\") || CONTROL_CHARACTER.match?(path) || path.include?("//")
        return if path.split("/").any? { |segment| %w[. ..].include?(segment.split(";", 2).first) }

        path
      rescue ArgumentError
        nil
      end

      def method_override_parameter?(raw)
        query = raw.split("#", 2).first.to_s.split("?", 2)[1]
        return false unless query

        query.split(/[&;]/).any? do |pair|
          name = pair.split("=", 2).first.to_s
          3.times { name = URI.decode_uri_component(name) }
          name.strip.downcase == METHOD_OVERRIDE_PARAMETER
        rescue ArgumentError
          true
        end
      end

      def path_match?(pattern, path, fold: false)
        return pattern.match?(path) if pattern.is_a?(Regexp)

        pattern = pattern.downcase if fold
        return path.start_with?(pattern.delete_suffix("*")) if pattern.end_with?("*")

        path == pattern
      end

      class Definition # :nodoc:
        def initialize
          @rules = {}
          @default_rule = nil
        end

        attr_reader :rules, :default_rule

        def host(*names, &)
          raise PolicyError, "network host rules require at least one host name" if names.empty?

          rule = RuleBuilder.build(&)
          names.flatten.each do |name|
            host, = EnvoyConfig.parse_endpoint("#{String(name).downcase}:443")
            raise PolicyError, "network host #{host} is declared more than once" if @rules.key?(host)

            @rules[host.freeze] = rule
          end
          nil
        end

        def default(&)
          raise PolicyError, "network host policy declares default more than once" if @default_rule

          @default_rule = RuleBuilder.build(&)
          nil
        end
      end

      class RuleBuilder # :nodoc:
        def self.build(&block)
          builder = new
          if block
            (block.arity == 1) ? block.call(builder) : builder.instance_exec(&block)
          end
          builder.rule
        end

        def initialize
          @methods = nil
          @paths = nil
          @deny_paths = []
          @pass_headers = :all_except_credentials
          @injections = []
          @inject_headers = []
          @requirements = []
          @timeout = nil
        end

        def methods(*names)
          normalized = names.flatten.map do |name|
            value = String(name).upcase
            raise PolicyError, "network host methods must be HTTP method tokens" unless METHOD.match?(value)

            value.freeze
          end
          raise PolicyError, "network host methods require at least one method" if normalized.empty?

          @methods = ((@methods || []) + normalized).uniq
          nil
        end

        def paths(*patterns)
          @paths = (@paths || []) + normalize_patterns(patterns)
          nil
        end

        def deny_paths(*patterns)
          @deny_paths += normalize_patterns(patterns)
          nil
        end

        def pass_headers(*names)
          names = names.flatten
          if names == [:all_except_credentials]
            @pass_headers = :all_except_credentials
            return
          end

          @pass_headers = names.map do |name|
            value = String(name).downcase
            raise PolicyError, "network host headers must be lowercase HTTP tokens" unless HEADER.match?(value)
            if CREDENTIAL_HEADERS.include?(value)
              raise PolicyError, "network host policy cannot pass client credential header #{value}; inject it instead"
            end

            value.freeze
          end.uniq
          nil
        end

        def inject(*names, &block)
          raise PolicyError, "network host inject requires a block" unless block

          declared = names.flatten.map do |name|
            value = String(name).downcase
            raise PolicyError, "network host headers must be lowercase HTTP tokens" unless HEADER.match?(value)

            value.freeze
          end
          @inject_headers = (@inject_headers + (declared.empty? ? CREDENTIAL_HEADERS : declared)).uniq
          @injections << block
          nil
        end

        def require(&block)
          raise PolicyError, "network host require needs a block" unless block

          @requirements << block
          nil
        end

        def timeout(seconds)
          @timeout = Network.timeout_seconds(seconds)
          nil
        end

        def rule
          Rule.new(
            http_methods: @methods&.freeze,
            paths: @paths&.freeze,
            deny_paths: @deny_paths.freeze,
            pass_headers: @pass_headers.is_a?(Array) ? @pass_headers.freeze : @pass_headers,
            injections: @injections.freeze,
            inject_headers: @inject_headers.freeze,
            requirements: @requirements.freeze,
            timeout: @timeout
          )
        end

        private

        def normalize_patterns(patterns)
          patterns.flatten.map do |pattern|
            next pattern if pattern.is_a?(Regexp)

            value = String(pattern)
            unless value.start_with?("/") && !value.delete_suffix("*").include?("*")
              raise PolicyError, "network host paths must start with / and may use * only as a trailing prefix marker"
            end

            value.freeze
          end
        end
      end

      private_constant :Definition, :RuleBuilder, :Rule
    end
  end
end
