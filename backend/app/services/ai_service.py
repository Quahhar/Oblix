"""AI groundwork: a thin, provider-shaped completion layer plus the first
user feature built on it (note summarization).

Design
------
- Disabled unless ANTHROPIC_API_KEY is set; the client discovers this via
  GET /api/ai/status instead of a failing call.
- Speaks the Anthropic Messages API directly over httpx (no SDK dependency).
  AI_BASE_URL is configurable so self-hosters can point it at a proxy or any
  Messages-API-compatible gateway — it also makes the whole feature testable
  against a local stub.
- `complete()` is the seam for future features (tag suggestions, note titles,
  Q&A over a notebook): build them on it rather than issuing raw HTTP.
- Note content is sent to the configured provider ONLY when the user
  explicitly invokes an AI action, is never logged here, and nothing is stored.
"""
from typing import Optional

import httpx
from fastapi import HTTPException, status

from app.config import settings
from app.models.note import Note

_ANTHROPIC_VERSION = "2023-06-01"

_STYLE_INSTRUCTIONS = {
    "short": "Write a 2-3 sentence summary capturing the essential points.",
    "detailed": "Write a thorough summary in one or two short paragraphs, "
                "keeping every substantive point.",
    "bullets": "Write the summary as a concise bullet list (max 8 bullets), "
               "one point per bullet.",
}

_SYSTEM = (
    "You summarize a user's personal note. Respond with ONLY the summary — no "
    "preamble, no headings, no commentary. Respond in the same language the "
    "note is written in. If the note contains HTML or markdown markup, "
    "summarize the text content and ignore the markup."
)


class AIService:

    @property
    def enabled(self) -> bool:
        return bool(settings.ANTHROPIC_API_KEY)

    @property
    def model(self) -> Optional[str]:
        return settings.AI_MODEL if self.enabled else None

    async def complete(self, system: str, prompt: str, max_tokens: int = 1024) -> str:
        """One-shot completion against the configured Messages API."""
        if not self.enabled:
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail="AI features are not configured on this server",
            )
        try:
            async with httpx.AsyncClient(
                base_url=settings.AI_BASE_URL,
                timeout=settings.AI_TIMEOUT_SECONDS,
            ) as client:
                resp = await client.post(
                    "/v1/messages",
                    headers={
                        "x-api-key": settings.ANTHROPIC_API_KEY,
                        "anthropic-version": _ANTHROPIC_VERSION,
                    },
                    json={
                        "model": settings.AI_MODEL,
                        "max_tokens": max_tokens,
                        "system": system,
                        "messages": [{"role": "user", "content": prompt}],
                    },
                )
        except httpx.TimeoutException:
            raise HTTPException(status_code=status.HTTP_504_GATEWAY_TIMEOUT,
                                detail="AI provider timed out")
        except httpx.HTTPError:
            raise HTTPException(status_code=status.HTTP_502_BAD_GATEWAY,
                                detail="AI provider is unreachable")

        if resp.status_code != 200:
            # Don't relay provider error bodies (they can echo request content).
            raise HTTPException(status_code=status.HTTP_502_BAD_GATEWAY,
                                detail=f"AI provider error (HTTP {resp.status_code})")
        try:
            data = resp.json()
            text = "".join(
                block.get("text", "") for block in data["content"] if block.get("type") == "text"
            ).strip()
        except (KeyError, TypeError, ValueError):
            raise HTTPException(status_code=status.HTTP_502_BAD_GATEWAY,
                                detail="AI provider returned an unexpected response")
        if not text:
            raise HTTPException(status_code=status.HTTP_502_BAD_GATEWAY,
                                detail="AI provider returned an empty response")
        return text

    async def summarize_note(self, note: Note, style: str = "short") -> str:
        content = note.content or ""
        # Cap what we send: a pathological note shouldn't turn into a huge
        # provider bill. The head of a note carries most of its meaning.
        if len(content) > settings.AI_MAX_INPUT_CHARS:
            content = content[: settings.AI_MAX_INPUT_CHARS] + "\n\n[note truncated]"
        instruction = _STYLE_INSTRUCTIONS.get(style, _STYLE_INSTRUCTIONS["short"])
        prompt = f"{instruction}\n\nNote title: {note.title}\n\nNote content:\n{content}"
        return await self.complete(_SYSTEM, prompt)


ai_service = AIService()
