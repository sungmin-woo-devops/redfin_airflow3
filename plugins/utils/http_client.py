from __future__ import annotations
import time
import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

def create_session(timeout: int = 20, retries: int = 3, backoff: float = 0.5, user_agent: str | None = None) -> requests.Session:
    s = requests.Session()
    retry = Retry(
        total=retries, connect=retries, read=retries,
        backoff_factor=backoff,
        status_forcelist=(429, 500, 502, 503, 504),
        allowed_methods=frozenset(["GET", "HEAD"])
    )
    s.mount("http://", HTTPAdapter(max_retries=retry))
    s.mount("https://", HTTPAdapter(max_retries=retry))
    if user_agent:
        s.headers.update({"User-Agent": user_agent})
    s.request = _with_timeout(s.request, timeout)
    return s

def _with_timeout(fn, timeout: int):
    def _wrapped(method, url, **kw):
        kw.setdefault("timeout", timeout)
        return fn(method, url, **kw)
    return _wrapped

def polite_delay(seconds: float):
    time.sleep(seconds)
