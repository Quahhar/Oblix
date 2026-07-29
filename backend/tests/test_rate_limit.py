from starlette.requests import Request

from app.utils.rate_limit import client_ip


def _request(headers=(), client=("127.0.0.1", 12345)):
    return Request(
        {
            "type": "http",
            "method": "GET",
            "path": "/",
            "headers": [
                (name.lower().encode(), value.encode()) for name, value in headers
            ],
            "client": client,
            "server": ("testserver", 80),
            "scheme": "http",
            "query_string": b"",
        }
    )


def test_real_ip_from_proxy_wins_over_spoofed_forwarded_chain():
    request = _request(
        [
            ("X-Forwarded-For", "198.51.100.4, 192.0.2.10"),
            ("X-Real-IP", "203.0.113.8"),
        ]
    )

    assert client_ip(request) == "203.0.113.8"


def test_forwarded_fallback_uses_last_valid_hop():
    request = _request(
        [("X-Forwarded-For", "attacker-value, 198.51.100.20")]
    )

    assert client_ip(request) == "198.51.100.20"


def test_invalid_proxy_headers_fall_back_to_socket_peer():
    request = _request(
        [
            ("X-Forwarded-For", "not-an-ip"),
            ("X-Real-IP", "also-not-an-ip"),
        ],
        client=("127.0.0.9", 12345),
    )

    assert client_ip(request) == "127.0.0.9"
