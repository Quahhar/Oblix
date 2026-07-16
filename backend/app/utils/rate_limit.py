"""Tiny in-memory rate limiting for the auth endpoints.

Scope: the app runs as a single uvicorn process (see Dockerfile CMD), so a
process-local sliding window is enough to blunt credential brute-force and
signup abuse without adding Redis. If the deployment ever moves to multiple
workers, this must move to shared storage.

Client identity comes from X-Forwarded-For / X-Real-IP (set by the nginx or
Caddy front — the API is only reachable through the reverse proxy or
localhost, so those headers are trustworthy here), falling back to the socket
peer address.
"""
import time
from collections import deque

from fastapi import HTTPException, Request, status

from app.config import settings


def client_ip(request: Request) -> str:
    xff = request.headers.get("x-forwarded-for")
    if xff:
        return xff.split(",")[0].strip()
    real_ip = request.headers.get("x-real-ip")
    if real_ip:
        return real_ip.strip()
    return request.client.host if request.client else "unknown"


class SlidingWindowLimiter:
    def __init__(self, limit: int, window_seconds: float):
        self.limit = limit
        self.window = window_seconds
        self._hits: dict[str, deque] = {}

    def check(self, key: str) -> None:
        """Record one attempt for `key`; raise 429 once limit/window is exceeded."""
        if not settings.RATE_LIMIT_ENABLED:
            return
        now = time.monotonic()
        cutoff = now - self.window
        dq = self._hits.get(key)
        if dq is None:
            dq = self._hits[key] = deque()
        while dq and dq[0] <= cutoff:
            dq.popleft()
        if len(dq) >= self.limit:
            retry_after = max(1, int(dq[0] + self.window - now) + 1)
            raise HTTPException(
                status_code=status.HTTP_429_TOO_MANY_REQUESTS,
                detail="Too many attempts. Please try again later.",
                headers={"Retry-After": str(retry_after)},
            )
        dq.append(now)
        # Opportunistic cleanup so abandoned keys can't accumulate forever.
        if len(self._hits) > 10_000:
            self._hits = {k: v for k, v in self._hits.items() if v and v[-1] > cutoff}


# Login attempts (successful or not) are capped per (client, email) pair:
# 10 tries per 5 minutes stops password brute-force cold while never
# inconveniencing a human retyping a password.
login_limiter = SlidingWindowLimiter(limit=10, window_seconds=300)
# Account creation and Google sign-in are capped per client only.
register_limiter = SlidingWindowLimiter(limit=20, window_seconds=3600)
google_limiter = SlidingWindowLimiter(limit=20, window_seconds=60)
