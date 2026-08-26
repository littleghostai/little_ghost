# Provider Support

Connect LittleGhost to a supported hosted API or local model server with the
appropriate adapter and settings. Configure each connection once. Then select
its models with a direct target made from the connection name and provider
model identifier, or use an application-facing model role.

[Models and Providers](models_and_providers.md) explains how Agents choose
between configured connections and model roles. This page covers the concrete
adapter support, credentials, endpoints, embeddings, and catalog behavior for
each connection.

## Compare provider support

The same configuration shape works for hosted services and local servers:

```ruby
LittleGhost.configure do |config|
  config.providers = {
    primary: {
      adapter: :openrouter,
      api_key: ENV.fetch("OPENROUTER_API_KEY")
    }
  }
end
```

`primary` is an application-defined connection name. `adapter` selects the
wire protocol, and the remaining values configure that connection. An Agent
can now use a target such as `primary:openai/gpt-5.6-luna`.

LittleGhost supports these providers and compatible endpoints:

| Provider or endpoint | Adapter | Generation | Embeddings | Model catalog after `refresh!` |
| --- | --- | --- | --- | --- |
| OpenRouter | `:openrouter` | Chat Completions | When the model supports it | models.dev and OpenRouter |
| OpenAI | `:openai` | Responses or Chat Completions | Yes | models.dev |
| Compatible API | `:openai_compatible` | Responses or Chat Completions | When the endpoint implements it | Not built in |
| Ollama | `:openai_compatible` | Responses or Chat Completions | When the model supports it | Not built in |
| Anthropic | `:anthropic` | Messages | No | models.dev and Anthropic |
| Gemini | `:gemini` | Gemini API | No | models.dev and Gemini |
| Vertex AI | `:vertex_ai` | Gemini on Vertex AI | No | models.dev |
| Bedrock | `:bedrock` | Converse | Titan Text Embeddings V2 | models.dev and Bedrock |
| LM Studio | `:lm_studio` | Responses or Chat Completions | Yes | LM Studio |

Catalog metadata and model capabilities change over time. A catalog entry is
useful for validation and request shaping, but it does not guarantee that a
provider account, server version, or selected model accepts every advertised
feature. Handle provider failures for generation and embeddings.

## Connect OpenRouter

OpenRouter gives one connection access to models from several providers:

```ruby
config.providers = {
  openrouter: {
    adapter: :openrouter,
    api_key: ENV.fetch("OPENROUTER_API_KEY"),
    app_name: "Support Console",
    site_url: "https://support.example.com"
  }
}
```

Use targets in OpenRouter's `publisher/model` form, such as
`openrouter:anthropic/claude-sonnet-4`. `app_name` and `site_url` are optional
attribution values. Embeddings use OpenRouter's OpenAI-compatible embeddings
endpoint; the selected model must support that operation.

## Connect OpenAI

The OpenAI adapter uses the Responses API by default:

```ruby
config.providers = {
  openai: {
    adapter: :openai,
    api_key: ENV.fetch("OPENAI_API_KEY")
  }
}
```

A generation target looks like `openai:gpt-5.6-luna`. An embedding role can
target an embedding model such as `openai:text-embedding-3-small`. Set
`api: :chat_completions` on the connection only when the selected model or an
intermediary requires that wire API.

## Connect another OpenAI-compatible API

Use `:openai_compatible` for a hosted service, gateway, or local server that
implements OpenAI-style endpoints:

```ruby
config.providers = {
  models: {
    adapter: :openai_compatible,
    base_url: "https://models.example.com/v1/",
    api_key: ENV.fetch("MODEL_API_KEY"),
    api: :responses
  }
}
```

Use the model identifier expected by the endpoint, for example
`models:example-model`. Choose `api: :responses` or
`api: :chat_completions` to match the server. `LittleGhost.embed` uses the
connection's `embeddings` endpoint and supports `dimensions` when the server
and model accept it.

LittleGhost treats compatible endpoints permissively because the protocol
does not provide one standard capability catalog. Tool calls, structured
results, reasoning settings, attachments, and embeddings still depend on the
specific server version and model.

## Run Ollama locally

Ollama uses the existing OpenAI-compatible adapter. Pull a model, start Ollama,
and configure its loopback endpoint:

```sh
$ ollama pull qwen3
```

```ruby
config.providers = {
  ollama: {
    adapter: :openai_compatible,
    base_url: "http://localhost:11434/v1/",
    api_key: "ollama",
    api: :responses,
    allow_insecure_http: true
  }
}
```

Use the pulled Ollama name in the target, such as `ollama:qwen3`. The
`api_key` value is a placeholder for a local server without authentication.
Ollama added its Responses endpoint in version 0.13.3. Set
`api: :chat_completions` for an earlier release or when the selected model does
not support the Responses features you need. See Ollama's [OpenAI compatibility
reference](https://docs.ollama.com/api/openai-compatibility) for the fields
supported by the installed release.

For embeddings, target an embedding model already pulled into Ollama and call
`LittleGhost.embed`. LittleGhost does not query or modify Ollama's local model
inventory. Pulling, deleting, and listing models remain Ollama operations.

## Run LM Studio locally

Start LM Studio's local server after downloading or loading the model you want
to use. The dedicated adapter supplies the standard local endpoint and a
placeholder credential:

```ruby
config.providers = {
  lm_studio: {
    adapter: :lm_studio,
    allow_insecure_http: true
  }
}
```

Use the model key shown by LM Studio in the target, for example
`lm_studio:google/gemma-3-4b`. Generation uses the Responses API by default. Set
`api: :chat_completions` with LM Studio releases earlier than 0.3.29, or when
required by the selected model. `LittleGhost.embed` uses the same connection
with an embedding model. The [LM Studio compatibility
reference](https://lmstudio.ai/docs/developer/openai-compat) describes its
current generation and embeddings endpoints.

When LM Studio authentication is enabled, replace the placeholder with the
token configured in LM Studio:

```ruby
config.providers = {
  lm_studio: {
    adapter: :lm_studio,
    api_key: ENV.fetch("LM_STUDIO_API_TOKEN"),
    allow_insecure_http: true
  }
}
```

The LM Studio adapter adds its read-only native model catalog through the v1
REST API introduced in LM Studio 0.4.0. API-token authentication also requires
0.4.0 or newer. It does not load, unload, or download models.

## Connect Anthropic

```ruby
config.providers = {
  anthropic: {
    adapter: :anthropic,
    api_key: ENV.fetch("ANTHROPIC_API_KEY")
  }
}
```

Use an Anthropic model identifier in the target, such as
`anthropic:claude-sonnet-4-6`. The adapter uses the Messages API. LittleGhost
does not provide Anthropic embeddings.

## Connect Gemini

```ruby
config.providers = {
  gemini: {
    adapter: :gemini,
    api_key: ENV.fetch("GEMINI_API_KEY")
  }
}
```

Use a Gemini model identifier such as `gemini:gemini-2.5-flash`. The adapter
uses Google's Gemini API directly. LittleGhost does not provide Gemini
embeddings.

## Connect Vertex AI

Vertex AI uses Gemini's request format with a Google Cloud project and
location:

```ruby
config.providers = {
  vertex: {
    adapter: :vertex_ai,
    project: ENV.fetch("GOOGLE_CLOUD_PROJECT"),
    location: "global"
  }
}
```

Use a target such as `vertex:gemini-2.5-flash`. The adapter can obtain Google
credentials through its credential resolver, or trusted configuration can
supply an access token. LittleGhost does not provide Vertex AI embeddings.

## Connect Amazon Bedrock

```ruby
config.providers = {
  bedrock: {
    adapter: :bedrock,
    region: ENV.fetch("AWS_REGION")
  }
}
```

Use the Bedrock model identifier available in the selected region, for example
`bedrock:us.anthropic.claude-sonnet-4-6-v1:0`. The adapter resolves AWS
credentials from its supported credential chain and signs requests without an
AWS SDK.

Bedrock embeddings currently support `amazon.titan-embed-text-v2:0`. Its
`dimensions` setting accepts 256, 512, or 1024, and `normalize` defaults to
`true`.

## Refresh model details explicitly

Catalog sources do not perform network work during configuration or ordinary
model resolution. Refresh them when your application wants current provider
facts:

```ruby
resolver = LittleGhost.model_resolver
result = resolver.refresh!(target: "lm_studio:google/gemma-3-4b")
result[:updated]
result[:errors]

details = resolver.details("lm_studio:google/gemma-3-4b")
details.context_window
details.input_modalities
details.supported_parameters
details[:max_context_length]
details[:loaded_instances]
```

Omit `target:` to ask every configured catalog source for its current models.
A targeted refresh lets each source narrow its response to one canonical
target. The catalog keeps stale data when one source fails and reports the
refresh failure to the caller.

For LM Studio, refreshed details can include downloaded model metadata,
reasoning options, modalities, supported parameters, and every loaded
instance. `context_window` is the smallest context length among active loaded
instances. An unloaded model has no active `context_window`, but may still
report its maximum supported context length.

## Keep endpoint and credential choices trusted

LittleGhost requires HTTPS by default. A local `http://localhost` endpoint
still requires `allow_insecure_http: true`; that opt-in is visible because
plain HTTP does not protect prompts, model output, or credentials in transit.
Do not reuse the local examples for an untrusted remote endpoint.

Keep API keys, access tokens, custom headers, base URLs, model identifiers, and
wire API choices in application configuration rather than accepting them from
a public request. The selected provider can receive prompts, conversation
history, Tool results, schemas, and attachments.

Continue with [Running in Production](production.md) to place connections,
roles, sessions, and observability into a long-running application.
