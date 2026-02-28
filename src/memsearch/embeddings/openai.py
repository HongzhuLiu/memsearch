"""OpenAI embedding provider.

Requires: ``pip install memsearch`` (openai is included by default)
Environment variables:
    OPENAI_API_KEY   — required
    OPENAI_BASE_URL  — optional, override API base URL
"""

from __future__ import annotations

import os


class OpenAIEmbedding:
    """OpenAI text-embedding provider."""

    _DEFAULT_BATCH_SIZE = 2048

    def __init__(
        self, model: str = "text-embedding-3-small", *, batch_size: int = 0,
    ) -> None:
        import httpx
        import openai

        kwargs: dict = {}
        base_url = os.environ.get("OPENAI_BASE_URL")
        if base_url:
            kwargs["base_url"] = base_url

        # 忽略 ALL_PROXY (socks5h 不支持)，仅使用 HTTP_PROXY/HTTPS_PROXY
        http_proxy = os.environ.get("HTTP_PROXY") or os.environ.get("http_proxy")
        https_proxy = os.environ.get("HTTPS_PROXY") or os.environ.get("https_proxy")
        proxy = https_proxy or http_proxy  # 优先 HTTPS 代理
        http_client = httpx.AsyncClient(proxy=proxy)
        self._client = openai.AsyncOpenAI(**kwargs, http_client=http_client)  # reads OPENAI_API_KEY
        self._model = model
        self._dimension = _detect_dimension(model, kwargs)
        self._batch_size = batch_size if batch_size > 0 else self._DEFAULT_BATCH_SIZE

    @property
    def model_name(self) -> str:
        return self._model

    @property
    def dimension(self) -> int:
        return self._dimension

    async def embed(self, texts: list[str]) -> list[list[float]]:
        from .utils import batched_embed

        return await batched_embed(texts, self._embed_batch, self._batch_size)

    async def _embed_batch(self, texts: list[str]) -> list[list[float]]:
        resp = await self._client.embeddings.create(input=texts, model=self._model)
        return [item.embedding for item in resp.data]


_KNOWN_DIMENSIONS: dict[str, int] = {
    "text-embedding-3-small": 1536,
    "text-embedding-3-large": 3072,
    "text-embedding-ada-002": 1536,
}


def _detect_dimension(model: str, client_kwargs: dict) -> int:
    """Return the embedding dimension for *model*.

    Uses a lookup table for well-known OpenAI models.  For unknown models
    (e.g. custom models via OPENAI_BASE_URL), a trial embed is performed.
    """
    if model in _KNOWN_DIMENSIONS:
        return _KNOWN_DIMENSIONS[model]
    import httpx
    import openai

    http_proxy = os.environ.get("HTTP_PROXY") or os.environ.get("http_proxy")
    https_proxy = os.environ.get("HTTPS_PROXY") or os.environ.get("https_proxy")
    proxy = https_proxy or http_proxy
    http_client = httpx.Client(proxy=proxy)
    sync_client = openai.OpenAI(**client_kwargs, http_client=http_client)
    trial = sync_client.embeddings.create(input=["dim"], model=model)
    return len(trial.data[0].embedding)
