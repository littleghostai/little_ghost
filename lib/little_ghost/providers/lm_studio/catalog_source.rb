# frozen_string_literal: true

require "json"
require "time"
require "uri"

module LittleGhost
  module Providers
    class LMStudio < OpenAICompatible
      # Refreshes downloaded model metadata from LM Studio's native read-only
      # model listing endpoint.
      class CatalogSource < Models::Catalog::Source
        MAX_CATALOG_BYTES = 25 * 1024 * 1024 # :nodoc:

        # Creates a source for one named LM Studio connection. Credentials are
        # resolved only when the application explicitly refreshes its catalog.
        def initialize(provider:, credential_resolver:, clock: -> { Time.now.utc }, http_client: nil)
          super(name: "lm_studio")
          @provider = provider.to_s
          @credential_resolver = credential_resolver
          @clock = clock
          @known_targets = []
          @known_targets_mutex = Mutex.new
          @http_client = http_client || Support::HTTPClient.new(
            open_timeout: 5,
            read_timeout: 30,
            max_response_bytes: MAX_CATALOG_BYTES
          )
        end

        def refresh(target: nil)
          return {} if target && target.provider != @provider

          configuration = @credential_resolver.call
          raise TypeError, "credentials must be a mapping" unless configuration.is_a?(Hash)

          configuration = configuration.to_h.transform_keys(&:to_s)
          models = JSON.parse(request(configuration)).fetch("models")
          raise TypeError, "models must be an array" unless models.is_a?(Array)

          observed_at = @clock.call.iso8601
          return refresh_target(models, target:, observed_at:) if target

          records = models.to_h do |model|
            attributes = normalize(model).merge(observed_at:)
            ["#{@provider}:#{model.fetch("key")}", attributes]
          end
          reconcile(records, observed_at:)
        rescue JSON::ParserError, KeyError, TypeError, ArgumentError
          raise ProviderError, "LM Studio returned an invalid model catalog"
        end

        private

        def request(configuration)
          api_key = configuration.fetch("api_key", DEFAULT_API_KEY)
          @http_client.request(
            uri: catalog_uri(configuration.fetch("base_url", DEFAULT_BASE_URL)),
            headers: {"Authorization" => "Bearer #{api_key}"},
            allow_insecure_http: configuration.fetch("allow_insecure_http", false),
            label: "LM Studio catalog"
          )
        end

        def catalog_uri(base_url)
          uri = URI(base_url)
          uri.path = "/api/v1/models"
          uri.query = nil
          uri.fragment = nil
          uri
        end

        def normalize(model)
          raise TypeError, "model must be a mapping" unless model.is_a?(Hash)

          type = model.fetch("type")
          raise ArgumentError, "unsupported model type" unless %w[llm embedding].include?(type)

          instances = normalize_instances(model.fetch("loaded_instances"))
          capabilities = normalize_capabilities(model["capabilities"])
          attributes = {
            available: true,
            model_type: type,
            display_name: model.fetch("display_name"),
            publisher: model.fetch("publisher"),
            architecture: model["architecture"],
            format: model["format"],
            quantization: normalize_quantization(model["quantization"]),
            size_bytes: model.fetch("size_bytes"),
            parameter_size: model["params_string"],
            loaded: !instances.empty?,
            loaded_instances: instances,
            context_window: instances.filter_map { |instance| instance[:context_window] }.min,
            max_context_length: model.fetch("max_context_length"),
            input_modalities: input_modalities(capabilities, type:),
            output_modalities: (["text"] if type == "llm"),
            supported_parameters: supported_parameters(capabilities, type:),
            reasoning: capabilities[:reasoning],
            description: model["description"],
            variants: model["variants"],
            selected_variant: model["selected_variant"]
          }.compact
          attributes[:context_window] = instances.filter_map { |instance| instance[:context_window] }.min
          attributes
        end

        def refresh_target(models, target:, observed_at:)
          key = target.to_s
          model = models.find { |candidate| candidate.is_a?(Hash) && candidate["key"] == target.model_id }
          attributes = model ? normalize(model).merge(observed_at:) : unavailable(observed_at:)
          @known_targets_mutex.synchronize do
            model ? @known_targets |= [key] : @known_targets.delete(key)
          end
          {key => attributes}
        end

        def reconcile(records, observed_at:)
          current_targets = records.keys
          missing_targets = @known_targets_mutex.synchronize do
            missing = @known_targets - current_targets
            @known_targets = current_targets
            missing
          end

          missing_targets.each { |key| records[key] = unavailable(observed_at:) }
          records
        end

        def unavailable(observed_at:)
          {available: false, loaded: false, loaded_instances: [], context_window: nil, observed_at:}
        end

        def normalize_instances(instances)
          raise TypeError, "loaded_instances must be an array" unless instances.is_a?(Array)

          instances.map do |instance|
            raise TypeError, "loaded instance must be a mapping" unless instance.is_a?(Hash)

            config = instance.fetch("config")
            raise TypeError, "loaded instance config must be a mapping" unless config.is_a?(Hash)

            {
              id: instance.fetch("id"),
              context_window: config.fetch("context_length"),
              eval_batch_size: config["eval_batch_size"],
              parallel: config["parallel"],
              flash_attention: config["flash_attention"],
              num_experts: config["num_experts"],
              offload_kv_cache_to_gpu: config["offload_kv_cache_to_gpu"]
            }.compact
          end
        end

        def normalize_capabilities(value)
          return {} if value.nil?
          raise TypeError, "capabilities must be a mapping" unless value.is_a?(Hash)

          reasoning = value["reasoning"]
          if reasoning
            raise TypeError, "reasoning must be a mapping" unless reasoning.is_a?(Hash)

            allowed_options = reasoning.fetch("allowed_options")
            raise TypeError, "reasoning options must be an array" unless allowed_options.is_a?(Array)

            reasoning = {
              allowed_options:,
              default: reasoning.fetch("default")
            }
          end
          {
            vision: value.fetch("vision"),
            trained_for_tool_use: value.fetch("trained_for_tool_use"),
            reasoning:
          }.compact
        end

        def normalize_quantization(value)
          return unless value
          raise TypeError, "quantization must be a mapping" unless value.is_a?(Hash)

          {name: value["name"], bits_per_weight: value["bits_per_weight"]}.compact
        end

        def input_modalities(capabilities, type:)
          modalities = ["text"]
          modalities << "image" if type == "llm" && capabilities[:vision]
          modalities
        end

        def supported_parameters(capabilities, type:)
          return [] if type == "embedding"

          parameters = %w[structured_outputs temperature]
          parameters.concat(%w[tools tool_choice]) if capabilities[:trained_for_tool_use]
          parameters << "reasoning" if capabilities[:reasoning]
          parameters
        end
      end
    end
  end
end
