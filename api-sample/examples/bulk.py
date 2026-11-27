#!/usr/bin/env python3
"""Send independent CRUD operations to a running local API, one JSON object per stdin line."""

import argparse
import http.client
import json
import sys
from uuid import UUID


def command(item):
    operation = item["operation"]
    if operation == "create":
        return "POST", "/products", item["product"], {}
    method = {"replace": "PUT", "patch": "PATCH", "delete": "DELETE"}[operation]
    path = f"/products/{UUID(item['id'])}"
    version = item["version"]
    if type(version) is not int or version < 1:
        raise ValueError("version must be a positive integer")
    return method, path, None if method == "DELETE" else item["product"], {"If-Match": f'"{version}"'}


def run(port, item):
    method, path, data, headers = command(item)
    if data is not None:
        headers["Content-Type"] = "application/json"
        data = json.dumps(data).encode("utf-8")
    # Loopback TCP only. http.client does not follow redirects or consult proxy settings.
    client = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    try:
        client.request(method, path, body=data, headers=headers)
        response = client.getresponse()
        payload = response.read()
        return {"ok": 200 <= response.status < 300, "status": response.status,
                "etag": response.getheader("ETag"), "body": json.loads(payload) if payload else None}
    finally:
        client.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8080)
    args = parser.parse_args()
    failures = 0
    for line_number, line in enumerate(sys.stdin, 1):
        try:
            result = run(args.port, json.loads(line))
        except (KeyError, TypeError, ValueError, OSError, http.client.HTTPException) as error:
            result = {"ok": False, "error": str(error)}
        print(json.dumps({"line": line_number, **result}, ensure_ascii=False), flush=True)
        failures += not result["ok"]
    return int(failures > 0)


if __name__ == "__main__":
    sys.exit(main())
