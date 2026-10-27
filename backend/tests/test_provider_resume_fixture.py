"""The loopback-only fixture must not wait on external name resolution."""
import importlib.util
from http.server import BaseHTTPRequestHandler
from pathlib import Path
import socket
import sys

ROOT = Path(__file__).resolve().parents[2] / "benchmarks"
sys.path.insert(0, str(ROOT))
try:
    SPEC = importlib.util.spec_from_file_location("provider_resume_fixture", ROOT / "native_provider_resume.py")
    provider = importlib.util.module_from_spec(SPEC)
    SPEC.loader.exec_module(provider)
finally:
    sys.path.pop(0)


def test_provider_fixture_binds_without_reverse_dns(monkeypatch):
    def forbidden(*_):
        raise AssertionError("Loopback fixture tried reverse DNS")
    monkeypatch.setattr(socket, "getfqdn", forbidden)
    with provider.LoopbackProviderServer(("127.0.0.1", 0), BaseHTTPRequestHandler) as server:
        assert server.server_address[0] == "127.0.0.1"
        assert server.server_name == "127.0.0.1"
        assert server.server_port > 0
