# Embeddings

Use `LittleGhost.embed` to turn text into numeric representations for search,
clustering, or another similarity-based feature:

```ruby
response = LittleGhost.embed(
  model: "primary:openai/text-embedding-3-small",
  inputs: ["Reset a password", "Track a transfer"]
)

response.vectors.length # => 2
response.dimensions
response.usage.input_tokens
```

The response keeps vectors in the same order as the inputs. LittleGhost rejects
an incomplete or malformed response instead of returning a partial batch.
Embedding text is sent to the selected provider, so choose one appropriate for
that data. [Provider Support](providers.md) identifies adapters with embedding
support; `LittleGhost::Embeddings::Request` documents settings and request
bounds. See [Models and Providers](models_and_providers.md) for model targets,
shared roles, and capabilities.
