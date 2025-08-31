#!/usr/bin/env bash
set -euo pipefail

# 프로젝트 루트(필요시 수정)
ROOT="${PWD}"

mkdir -p "${ROOT}/dags/ingestion"
mkdir -p "${ROOT}/dags/config"
mkdir -p "${ROOT}/plugins/utils"
mkdir -p "${ROOT}/data/rss/raw"

# requirements.txt
cat > "${ROOT}/requirements.txt" <<'REQ'
feedparser==6.0.11
requests==2.32.3
pymongo==4.8.0
beautifulsoup4==4.12.3
REQ

# rss_feeds.yaml
cat > "${ROOT}/dags/config/rss_feeds.yaml" <<'YAML'
feeds:
  - name: OpenAI Blog
    url: https://openai.com/blog/rss
  - name: Google AI Blog
    url: https://ai.googleblog.com/feeds/posts/default
  - name: NVIDIA Technical Blog
    url: https://developer.nvidia.com/blog/feed/
  - name: Anthropic
    url: https://www.anthropic.com/news/rss
per_feed_limit: 200
http:
  timeout: 20
  retries: 3
  backoff: 0.5
  user_agent: "RedFinRSSBot/1.0 (+https://example.com/contact)"
YAML

# plugins/utils/http.py
cat > "${ROOT}/plugins/utils/http.py" <<'PY'
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
PY

# plugins/utils/mongo.py
cat > "${ROOT}/plugins/utils/mongo.py" <<'PY'
from __future__ import annotations
import os
from typing import Any, Dict
from pymongo import MongoClient

def get_mongo_client() -> MongoClient:
    uri = os.environ.get("MONGO_URI", "mongodb://redfin:password@mongodb:27017/admin")
    return MongoClient(uri)

def get_db(db_name: str = "redfin"):
    return get_mongo_client()[db_name]
PY

# dags/ingestion/prd__01_rss_fetch_full__v1.py
cat > "${ROOT}/dags/ingestion/prd__01_rss_fetch_full__v1.py" <<'PY'
# -*- coding: utf-8 -*-
from __future__ import annotations
import os, json, hashlib, pendulum, pathlib, datetime
import feedparser
from typing import Any, Dict, List

from airflow.decorators import dag, task
from airflow.models import Variable
from airflow.exceptions import AirflowSkipException

from plugins.utils.http import create_session, polite_delay
from plugins.utils.mongo import get_db

KST = pendulum.timezone("Asia/Seoul")
DAG_ID = "prd__01_rss_fetch_full__v1"

DEFAULT_SCHEDULE = "0 * * * *"
DEFAULT_START = pendulum.now("Asia/Seoul").subtract(hours=1)
DATA_ROOT = "/opt/airflow/data/rss/raw"

def _today_dir() -> str:
    d = datetime.datetime.now(tz=KST).strftime("%Y%m%d")
    p = pathlib.Path(DATA_ROOT) / d
    p.mkdir(parents=True, exist_ok=True)
    return str(p)

def _hash_id(text: str) -> str:
    import hashlib
    return hashlib.sha256(text.encode("utf-8", "ignore")).hexdigest()

@dag(
    dag_id=DAG_ID,
    schedule=DEFAULT_SCHEDULE,
    start_date=DEFAULT_START,
    catchup=False,
    max_active_runs=1,
    default_args={"owner": "airflow", "retries": 1},
    tags=["rss","feedparser","full-source","ingestion"]
)
def rss_fetch_full_v1():

    @task
    def load_config() -> Dict[str, Any]:
        cfg_var = Variable.get("RSS_FEEDS_CONFIG_JSON", default_var=None)
        if cfg_var:
            return json.loads(cfg_var)

        cfg_path = os.environ.get("RSS_FEEDS_YAML", "/opt/airflow/dags/config/rss_feeds.yaml")
        import yaml
        with open(cfg_path, "r", encoding="utf-8") as f:
            cfg = yaml.safe_load(f)
        if not cfg.get("feeds"):
            raise AirflowSkipException("No feeds configured.")
        return cfg

    @task
    def init_runtime(cfg: Dict[str, Any]) -> Dict[str, Any]:
        run = {
            "data_dir": _today_dir(),
            "per_feed_limit": int(cfg.get("per_feed_limit", 200)),
            "http": cfg.get("http", {}),
        }
        run["feeds_jsonl"] = os.path.join(run["data_dir"], "feeds.jsonl")
        run["articles_jsonl"] = os.path.join(run["data_dir"], "articles.jsonl")
        return run

    @task
    def list_feeds(cfg: Dict[str, Any]) -> List[Dict[str, str]]:
        return [{"name": f["name"], "url": f["url"]} for f in cfg["feeds"]]

    @task
    def fetch_and_parse_feed(feed: Dict[str, str], run: Dict[str, Any]) -> Dict[str, Any]:
        session = create_session(
            timeout=run["http"].get("timeout", 20),
            retries=run["http"].get("retries", 3),
            backoff=run["http"].get("backoff", 0.5),
            user_agent=run["http"].get("user_agent", "RedFinRSSBot/1.0")
        )
        r = session.get(feed["url"])
        r.raise_for_status()
        parsed = feedparser.parse(r.content)

        feed_meta = {
            "name": feed["name"],
            "url": feed["url"],
            "fetched_at": pendulum.now("Asia/Seoul").to_iso8601_string(),
            "bozo": int(getattr(parsed, "bozo", 0)),
            "version": getattr(parsed, "version", ""),
            "feed": dict(parsed.feed) if getattr(parsed, "feed", None) else {},
            "entries_count": len(parsed.entries),
        }
        with open(run["feeds_jsonl"], "a", encoding="utf-8") as f:
            f.write(json.dumps(feed_meta, ensure_ascii=False) + "\n")

        entries = []
        for e in parsed.entries:
            entries.append({
                "feed_name": feed["name"],
                "feed_url": feed["url"],
                "title": e.get("title"),
                "link": e.get("link"),
                "published": e.get("published"),
                "published_parsed": str(e.get("published_parsed")),
                "summary": e.get("summary"),
                "id": e.get("id") or e.get("guid") or e.get("link"),
                "raw_entry": dict(e),
            })
        return {"feed_meta": feed_meta, "entries": entries}

    @task
    def persist_feed_meta_to_mongo(feed_result: Dict[str, Any]) -> str:
        db = get_db("redfin")
        db["rss_feeds_raw"].insert_one(feed_result["feed_meta"])
        return feed_result["feed_meta"]["url"]

    @task
    def expand_entries(feed_result: Dict[str, Any], run: Dict[str, Any]) -> List[Dict[str, Any]]:
        return feed_result["entries"][: int(run["per_feed_limit"])]

    @task
    def fetch_article_html(entry: Dict[str, Any], run: Dict[str, Any]) -> Dict[str, Any]:
        session = create_session(
            timeout=run["http"].get("timeout", 20),
            retries=run["http"].get("retries", 3),
            backoff=run["http"].get("backoff", 0.5),
            user_agent=run["http"].get("user_agent", "RedFinRSSBot/1.0")
        )
        url = entry.get("link")
        html = None
        status = None
        if url:
            try:
                polite_delay(0.2)
                resp = session.get(url)
                status = resp.status_code
                if resp.ok:
                    html = resp.text
            except Exception as e:
                status = f"error:{type(e).__name__}"

        record = {
            **entry,
            "fetched_at": pendulum.now("Asia/Seoul").to_iso8601_string(),
            "http_status": status,
            "html": html,
        }
        with open(run["articles_jsonl"], "a", encoding="utf-8") as f:
            f.write(json.dumps(record, ensure_ascii=False) + "\n")
        return record

    @task
    def persist_article_to_mongo(record: Dict[str, Any]) -> str:
        db = get_db("redfin")
        key_base = f"{record.get('link','')}{record.get('published','')}{record.get('id','')}"
        doc_id = _hash_id(key_base) if key_base else _hash_id(json.dumps(record)[:200])
        doc = {"_id": doc_id, **record}
        db["rss_articles_raw"].update_one({"_id": doc_id}, {"$set": doc}, upsert=True)
        return doc_id

    cfg = load_config()
    run = init_runtime(cfg)
    feeds = list_feeds(cfg)

    feed_results = fetch_and_parse_feed.expand(feed=feeds, run=[run] * feeds.map(len))
    _ = persist_feed_meta_to_mongo.expand(feed_result=feed_results)

    entries = expand_entries.expand(feed_result=feed_results, run=[run] * feed_results.map(len))
    articles = fetch_article_html.expand(entry=entries, run=[run] * entries.map(len))
    _ = persist_article_to_mongo.expand(record=articles)

rss_fetch_full_v1()
PY

echo "[OK] RSS DAG 스캐폴딩 생성 완료"
echo "다음 환경변수를 Compose 등에 추가하세요:"
echo "  - MONGO_URI=mongodb://redfin:password@mongodb:27017/redfin?authSource=admin"
echo "  - RSS_FEEDS_YAML=/opt/airflow/dags/config/rss_feeds.yaml"

