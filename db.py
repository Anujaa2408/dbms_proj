"""
HostelMS — MySQL Connection Pool Helper
"""
import os
import mysql.connector
from mysql.connector import pooling
from dotenv import load_dotenv

load_dotenv()

DB_CONFIG = {
    'host':     os.getenv('DB_HOST', 'localhost'),
    'user':     os.getenv('DB_USER', 'root'),
    'password': os.getenv('DB_PASSWORD', 'anu_jaa@242'),
    'database': os.getenv('DB_NAME', 'HostelDB'),
}

_pool = None

def _get_pool():
    global _pool
    if _pool is None:
        _pool = pooling.MySQLConnectionPool(
            pool_name="hostelms_pool",
            pool_size=5,
            pool_reset_session=True,
            **DB_CONFIG,
        )
    return _pool

def get_db():
    """Return a pooled MySQL connection. Caller must close it."""
    return _get_pool().get_connection()
