# Provider Support

Use this page to connect a hosted provider or local model server. If you are
still deciding how Agents should choose models, start with [Models and
Providers](models_and_providers.md).

## Compare provider support

Every connection uses the same configuration shape:

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

`primary` is a name chosen by the application, and `adapter` selects the wire
protocol. An Agent can now use a target such as
`primary:openai/gpt-5.6-luna`.

| Provider or endpoint | Adapter | Generation | Decisions | Embeddings |
| --- | --- | --- | --- | --- |
| OpenRouter | `:openrouter` | Chat Completions | Typed decision endpoints | When the model supports it |
| TypeSafe | `:typesafe` | No | System One decisions | No |
| OpenAI | `:openai` | Responses or Chat Completions | No | Yes |
| Compatible API | `:openai_compatible` | Responses or Chat Completions | No | When the endpoint implements it |
| Ollama | `:openai_compatible` | Responses or Chat Completions | No | When the model supports it |
| Anthropic | `:anthropic` | Messages | No | No |
| Gemini | `:gemini` | Gemini API | No | No |
| Vertex AI | `:vertex_ai` | Gemini on Vertex AI | No | No |
| Bedrock | `:bedrock` | Converse | No | Titan Text Embeddings V2 |
| LM Studio | `:lm_studio` | Responses or Chat Completions | No | Yes |

TypeSafe Jev is a decision model that returns structured answers to typed
questions. Its API and OpenRouter's Jev routes support the same question
types.
These operations return structured answers directly and do not create an Agent
Run. See [Decisions](decisions.md) for the question and answer model.

Capabilities can vary by model, account, and server version. Handle provider
failures even when a model is expected to support a feature.

## Hosted providers

### OpenRouter

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

Use OpenRouter's `publisher/model` form, such as
`openrouter:anthropic/claude-sonnet-4`. `app_name` and `site_url` are optional.
The selected model must support embeddings before you call
`LittleGhost.embed`.

For Jev decisions, OpenRouter supports both decision endpoints. The default
uses the Decisions API and namespaced model identifiers such as
`openrouter:typesafe/jev-latest`:

```ruby
LittleGhost.configure do |config|
  config.providers = {
    openrouter: {
      adapter: :openrouter,
      api_key: ENV.fetch("OPENROUTER_API_KEY"),
      decision_api: :decisions
    }
  }
end
```

Set `decision_api: :system_one` to use `/api/v1/systemone`; that route
accepts a bare TypeSafe model identifier such as `jev-latest`, used as
`openrouter:jev-latest`.
OpenRouter describes these routes in its [Jev guide](https://openrouter.ai/blog/insights/what-is-jev/).

### TypeSafe

Connect directly to TypeSafe's System One endpoint with a TypeSafe API key:

```ruby
LittleGhost.configure do |config|
  config.providers = {
    typesafe: {
      adapter: :typesafe,
      api_key: ENV.fetch("TYPESAFE_API_KEY")
    }
  }
end
```

Use a Jev identifier such as `typesafe:jev-latest`. This adapter supports
typed decisions only. See the [TypeSafe API reference](https://docs.typesafe.ai/api)
for question and answer fields.

### OpenAI

```ruby
config.providers = {
  openai: {
    adapter: :openai,
    api_key: ENV.fetch("OPENAI_API_KEY")
  }
}
```

Generation uses the Responses API by default. Use `openai:gpt-5.6-luna` for
generation or `openai:text-embedding-3-small` for embeddings. Set
`api: :chat_completions` only when required.

### Anthropic

```ruby
config.providers = {
  anthropic: {
    adapter: :anthropic,
    api_key: ENV.fetch("ANTHROPIC_API_KEY")
  }
}
```

Use a target such as `anthropic:claude-sonnet-4-6`. The adapter uses the
Messages API. LittleGhost does not provide Anthropic embeddings.

### Gemini

```ruby
config.providers = {
  gemini: {
    adapter: :gemini,
    api_key: ENV.fetch("GEMINI_API_KEY")
  }
}
```

Use `gemini:gemini-2.5-flash`, for example. LittleGhost does not provide Gemini
embeddings.

### Vertex AI

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

Use a target such as `vertex:gemini-2.5-flash`. The credential resolver can
obtain Google credentials, or startup can supply an access token. LittleGhost
does not provide Vertex AI embeddings.

### Amazon Bedrock

```ruby
config.providers = {
  bedrock: {
    adapter: :bedrock,
    region: ENV.fetch("AWS_REGION")
  }
}
```

Use a model available in the region, such as
`bedrock:us.anthropic.claude-sonnet-4-6-v1:0`. The adapter resolves AWS
credentials and signs requests without an AWS SDK.

Bedrock embeddings support `amazon.titan-embed-text-v2:0`. Its `dimensions`
setting accepts 256, 512, or 1024, and `normalize` defaults to `true`.

## Compatible APIs and local servers

### Another OpenAI-compatible API

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

Use the model identifier expected by the endpoint, such as
`models:example-model`. Choose `api: :responses` or
`api: :chat_completions` to match the server. `LittleGhost.embed` uses the
connection's `embeddings` endpoint and supports `dimensions` when the server
and model accept it.

Tool calls, structured results, reasoning, attachments, and embeddings depend
on the compatible server and model.

Ollama and LM Studio normally listen on loopback HTTP. LittleGhost requires
`allow_insecure_http: true` as an explicit opt-in because HTTP does not protect
prompts, output, or credentials in transit. Use this setting only for a local
or otherwise trusted endpoint; use HTTPS for a remote server.

### Ollama

Pull a model, start Ollama, and use the existing OpenAI-compatible adapter:

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

Use the pulled model name in the target, such as `ollama:qwen3`. The `api_key`
is a placeholder for a local server without authentication.

Ollama added its Responses endpoint in version 0.13.3. Set
`api: :chat_completions` for an earlier release or when the selected model does
not support the Responses features you need. See Ollama's [OpenAI compatibility
reference](https://docs.ollama.com/api/openai-compatibility) for release-specific
fields.

For embeddings, pull an embedding model and pass its target to
`LittleGhost.embed`. LittleGhost does not list, pull, or delete Ollama models.

### LM Studio

Start LM Studio's local server after downloading or loading the model you want
to use. The dedicated adapter supplies the usual local endpoint and a
placeholder credential:

```ruby
config.providers = {
  lm_studio: {
    adapter: :lm_studio,
    allow_insecure_http: true
  }
}
```

Use the model key shown by LM Studio, for example
`lm_studio:google/gemma-3-4b`. Generation uses the Responses API by default.

Set `api: :chat_completions` with LM Studio releases earlier than 0.3.29, or
when required by the selected model. `LittleGhost.embed` uses the same
connection with an embedding model. See LM Studio's [compatibility
reference](https://lmstudio.ai/docs/developer/openai-compat) for its current
generation and embedding endpoints.

When LM Studio authentication is enabled, add
`api_key: ENV.fetch("LM_STUDIO_API_TOKEN")` to the connection.

The native model list and API-token authentication require LM Studio 0.4.0 or
newer. LittleGhost reads the list; it does not load, unload, or download models.

## Discover current model details

Call `refresh!` when you need current availability, loaded state, or
capabilities. Ordinary model requests do not make discovery calls.

```ruby
resolver = LittleGhost.model_resolver
result = resolver.refresh!(target: "lm_studio:google/gemma-3-4b")
result[:errors]

details = resolver.details("lm_studio:google/gemma-3-4b")
details[:loaded]
details.context_window
details.input_modalities
details.supported_parameters
```

Pass `target:` for one model, or omit it for every configured source. On
failure, `result[:errors]` describes the problem and previous details remain.

Hosted adapters can combine models.dev data with their provider's model API.
LM Studio reads its native model list. The generic compatible adapter and
Ollama do not have built-in model discovery.

LM Studio details can include downloaded and loaded state, active context
length, input types, tools, and reasoning. An unloaded model has no active
context length. See `LittleGhost::Models::Details` for every field.

## Keep connection settings in application code

Choose keys, tokens, headers, base URLs, model identifiers, and API variants at
startup. Read secrets from deployment configuration or a secret manager. Do
not copy public request parameters into provider settings.

The selected provider may receive prompts, conversation history, Tool results,
schemas, and attachments. Choose one appropriate for that data.

Continue with [Running in Production](production.md) to place connections,
roles, sessions, and observability into a long-running application.
