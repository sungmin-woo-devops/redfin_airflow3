from __future__ import annotations
import os
from typing import Any, Dict
from pymongo import MongoClient

def get_mongo_client() -> MongoClient:
    uri = os.environ.get("MONGO_URI", "mongodb://redfin:password@mongodb:27017/admin")
    return MongoClient(uri)

def get_db(db_name: str = "redfin"):
    return get_mongo_client()[db_name]
