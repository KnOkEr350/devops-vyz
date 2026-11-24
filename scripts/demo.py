#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import struct
import sys
import uuid
import zlib
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen

BASE = "http://127.0.0.1:8065"
LOGIN = "admin@mattermost.example"
TEAM = "devops-practice4"
CHANNEL = "migration-check"
MESSAGE_TEXTS = (
    "01. Исходный стенд Mattermost 9.5.2 работает на MySQL 8.0.",
    "02. Этот приватный канал переносится из MySQL в PostgreSQL.",
    "03. Проверяем сохранность текста, автора и порядка сообщений.",
    "04. Контрольное вложение: сверяем SHA-256 после миграции.",
)
ATTACHMENT = "Mattermost migration evidence\nИсточник: Mattermost 9.5.2 / MySQL 8.0\n".encode()


class Mattermost:
    def __init__(self):
        self.token = None

    def request(self, path, payload=None, *, upload=None, method=None, raw=False):
        headers = {"Authorization": f"Bearer {self.token}"} if self.token else {}
        if upload:
            field, name, content_type, content = upload
            boundary = uuid.uuid4().hex
            headers["Content-Type"] = f"multipart/form-data; boundary={boundary}"
            payload = (
                f'--{boundary}\r\nContent-Disposition: form-data; name="{field}"; filename="{name}"\r\n'
                f"Content-Type: {content_type}\r\n\r\n"
            ).encode() + content + f"\r\n--{boundary}--\r\n".encode()
        elif payload is not None:
            payload = json.dumps(payload).encode()
            headers["Content-Type"] = "application/json"
        request = Request(BASE + "/api/v4" + path, payload, headers, method=method)
        with urlopen(request, timeout=30) as response:
            if path == "/users/login":
                self.token = response.headers["Token"]
            return response.read() if raw else json.load(response)

    def login(self):
        return self.request("/users/login", {
            "login_id": LOGIN,
            "password": os.environ["MM_DEMO_PASSWORD"],
        })


def png_avatar():
    def chunk(kind, data):
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body))

    size = 96
    rows = b"".join(
        b"\0" + b"".join(
            bytes((231, 183, 87) if 28 <= x <= 67 and 28 <= y <= 67 else (38, 71, 116))
            for x in range(size)
        )
        for y in range(size)
    )
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(rows))
        + chunk(b"IEND", b"")
    )


def sha256(content):
    return hashlib.sha256(content).hexdigest()


def seed(client, path):
    if path.exists():
        verify(client, path)
        return
    try:
        user = client.login()
    except HTTPError as error:
        if error.code not in (400, 401):
            raise
        client.request("/users", {
            "email": LOGIN, "username": "devops-admin",
            "password": os.environ["MM_DEMO_PASSWORD"],
            "first_name": "DevOps", "last_name": "Lab",
        })
        user = client.login()
    client.request(
        f"/users/{user['id']}/image",
        upload=("image", "avatar.png", "image/png", png_avatar()),
        raw=True,
    )
    try:
        team = client.request(f"/teams/name/{TEAM}")
    except HTTPError as error:
        if error.code != 404:
            raise
        team = client.request("/teams", {"name": TEAM, "display_name": "DevOps Lab", "type": "I"})
    try:
        channel = client.request(f"/teams/{team['id']}/channels/name/{CHANNEL}")
    except HTTPError as error:
        if error.code != 404:
            raise
        channel = client.request("/channels", {
            "team_id": team["id"], "name": CHANNEL,
            "display_name": "Проверка миграции", "type": "P",
        })
    existing = client.request(f"/channels/{channel['id']}/posts")["posts"]
    by_text = {post["message"]: post for post in existing.values()}
    posts = []
    for index, text in enumerate(MESSAGE_TEXTS):
        post = by_text.get(text)
        if post is None:
            payload = {"channel_id": channel["id"], "message": text}
            if index == len(MESSAGE_TEXTS) - 1:
                files = client.request(
                    f"/files?channel_id={channel['id']}",
                    upload=("files", "migration-check.txt", "text/plain", ATTACHMENT),
                )
                payload["file_ids"] = [files["file_infos"][0]["id"]]
            post = client.request("/posts", payload)
        posts.append({key: post.get(key) for key in ("id", "message", "user_id", "create_at", "file_ids")})
    attachment_id = posts[-1]["file_ids"][0]
    downloaded = client.request(f"/files/{attachment_id}", raw=True)
    assert downloaded == ATTACHMENT, "Unexpected source attachment"
    snapshot = {
        "url": f"{BASE}/{TEAM}/channels/{CHANNEL}",
        "user_id": user["id"], "team_id": team["id"], "channel_id": channel["id"],
        "posts": posts, "attachment_id": attachment_id, "attachment_sha256": sha256(downloaded),
        "avatar_sha256": sha256(client.request(f"/users/{user['id']}/image", raw=True)),
    }
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(snapshot, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)
    print(f"Created legacy fixture: {len(posts)} posts, 1 attachment and a custom avatar.")


def verify(client, path):
    expected = json.loads(path.read_text(encoding="utf-8"))
    user = client.login()
    assert user["id"] == expected["user_id"], "Admin user changed"
    assert "system_admin" in user["roles"].split(), "Admin role was lost"
    team = client.request(f"/teams/name/{TEAM}")
    assert team["id"] == expected["team_id"], "Team ID changed"
    channel = client.request(f"/teams/{team['id']}/channels/name/{CHANNEL}")
    assert channel["id"] == expected["channel_id"] and channel["type"] == "P", "Private channel changed"
    response = client.request(f"/channels/{channel['id']}/posts?per_page=200")
    expected_ids = [post["id"] for post in expected["posts"]]
    assert [post for post in response["order"] if post in expected_ids] == expected_ids[::-1], "Post order changed"
    for post in expected["posts"]:
        actual = response["posts"][post["id"]]
        for key in ("id", "message", "user_id", "create_at"):
            assert actual.get(key) == post[key], f"Unexpected {key} on post {post['id']}"
        # Versions 9.5 and 12 serialize an empty attachment list differently.
        assert (actual.get("file_ids") or []) == (post.get("file_ids") or []), (
            f"Attachment IDs changed on post {post['id']}"
        )
    downloaded = client.request(f"/files/{expected['attachment_id']}", raw=True)
    assert sha256(downloaded) == expected["attachment_sha256"], "Attachment hash mismatch"
    avatar = client.request(f"/users/{user['id']}/image", raw=True)
    assert sha256(avatar) == expected["avatar_sha256"], "Avatar hash mismatch"
    with urlopen(expected["url"], timeout=30) as page:
        assert page.status == 200, "Mattermost web UI is unavailable"
    print(f"PASS: {len(expected_ids)} exact posts in order, admin, private channel, attachment and avatar match.")
    print(f"Attachment SHA-256 {expected['attachment_sha256']}")
    print(f"Web UI HTTP 200 {expected['url']}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("seed", "verify"))
    parser.add_argument("snapshot", type=Path)
    args = parser.parse_args()
    try:
        (seed if args.action == "seed" else verify)(Mattermost(), args.snapshot)
    except HTTPError as error:
        try:
            error_id = json.load(error).get("id", "unknown")
        except ValueError:
            error_id = "unknown"
        sys.exit(f"Mattermost API rejected the operation: HTTP {error.code} ({error_id})")


if __name__ == "__main__":
    main()
