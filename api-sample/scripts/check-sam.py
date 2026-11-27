"""Check direct Lambda responses and pass the new ID to the calling script."""

import base64
import json
import sys

command, response_file, *arguments = sys.argv[1:]
with open(response_file, encoding="utf-8") as stream:
    response = json.load(stream)

headers = {key.lower(): value for key, value in response.get("headers", {}).items()}
body = response["body"]
if response.get("isBase64Encoded"):
    body = base64.b64decode(body)
product_or_page = json.loads(body)

if command == "created":
    assert response["statusCode"] == 201, response
    assert headers["x-request-id"] == "sam-fixture", headers
    assert headers["etag"], headers
    assert product_or_page["name"] == "SAM ノート", product_or_page
    print(product_or_page["id"])
elif command == "listed":
    assert response["statusCode"] == 200, response
    assert [item["id"] for item in product_or_page["items"]] == arguments, product_or_page
else:
    raise SystemExit(f"Unknown assertion {command}")
