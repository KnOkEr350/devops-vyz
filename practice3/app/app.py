import os

import psycopg2
from flask import Flask, jsonify

app = Flask(__name__)
app.json.ensure_ascii = False


def get_items():
    conn = psycopg2.connect(
        host=os.environ["DB_HOST"],
        port=os.environ["DB_PORT"],
        dbname=os.environ["DB_NAME"],
        user=os.environ["DB_USER"],
        password=os.environ["DB_PASSWORD"],
    )
    with conn, conn.cursor() as cur:
        cur.execute("SELECT id, name FROM items ORDER BY id")
        rows = cur.fetchall()
    conn.close()
    return rows


@app.route("/health")
def health():
    return jsonify(status="ok")


@app.route("/api/data")
def api_data():
    return jsonify([{"id": i, "name": n} for i, n in get_items()])


@app.route("/api/items/count")
def api_count():
    return str(len(get_items()))


@app.route("/")
def index():
    items = "".join(f"<li>{name}</li>" for _, name in get_items())
    return f"<meta charset=\"utf-8\"><h1>Список товаров</h1><ul>{items}</ul>"


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
