#!/usr/bin/env python3
"""Run the same HTTP contract against Netty or SAM, with real databases."""

from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
import json
import os
import sys
import time
from urllib.error import HTTPError
from urllib.parse import urlencode
from urllib.request import Request, urlopen
from uuid import uuid4

BASE = sys.argv[1].rstrip('/')
MODE = sys.argv[2]
REQUEST_TIMEOUT = float(os.environ.get('HTTP_REQUEST_TIMEOUT', '45'))
MISSING = object()


def call(method, path, data=MISSING, version=None, request_id=None):
    headers = {}
    if version is not None:
        headers['If-Match'] = version
    if request_id:
        headers['X-Request-Id'] = request_id
    if data is not MISSING:
        headers['Content-Type'] = 'application/json'
        data = data if isinstance(data, bytes) else json.dumps(data).encode()
    else:
        data = None
    try:
        response = urlopen(Request(BASE + path, data=data, method=method, headers=headers), timeout=REQUEST_TIMEOUT)
    except HTTPError as error:
        response = error
    with response:
        payload = response.read()
        return response.status, response.headers, json.loads(payload) if payload else None


def expect(status, response, code=None):
    actual, headers, payload = response
    assert actual == status, (status, actual, payload)
    assert headers.get('X-Request-Id'), (actual, payload, headers)
    if status >= 400:
        assert sorted(payload) == ['code', 'message', 'requestId'], payload
        assert payload['requestId'] == headers['X-Request-Id'], payload
        if code:
            assert payload['code'] == code, payload
    return payload


def eventually(condition, seconds=35):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if condition():
            return
        time.sleep(0.2)
    assert condition(), 'Timed out waiting for list visibility'


def query(**parameters):
    return expect(200, call('GET', '/products?' + urlencode(parameters)))


category = 'e2e-' + uuid4().hex[:12]
body = dict(name='文房具', category=category, priceMinor=120, status='ACTIVE')
expect(400, call('POST', '/products', body | {'priceMinor': -1}))
expect(400, call('POST', '/products', b'{'))
expect(400, call('POST', '/products', body | {'version': 1}))
expect(400, call('GET', '/products/not-a-uuid'))
expect(400, call('GET', '/products?limit=101'))
expect(400, call('GET', '/products?nextToken=bad-token'))
missing = f'/products/{uuid4()}'
expect(404, call('GET', missing))
expect(404, call('DELETE', missing, version='"1"'))

response = call('POST', '/products', body, request_id='e2e-request')
created = expect(201, response)
path = '/products/' + created['id']
assert response[1]['Location'] == path and response[1]['ETag'] == '"1"'
assert response[1]['X-Request-Id'] == 'e2e-request'
assert created['version'] == 1 and created['deleted'] is False and created['name'] == '文房具'
assert expect(200, call('GET', path)) == created
expect(428, call('PUT', path, body))
expect(400, call('PUT', path, body, 'W/"1"'))
expect(400, call('PUT', path, {'name': 'missing'}, '"1"'))
expect(400, call('PATCH', path, {}, '"1"'))
expect(400, call('PATCH', path, {'name': None}, '"1"'))
expect(400, call('PATCH', path, {'id': created['id']}, '"1"'))
updated = expect(200, call('PUT', path, body | {'name': 'ノート', 'priceMinor': 200}, '"1"'))
assert updated['version'] == 2 and updated['createdAt'] == created['createdAt']
patched = expect(200, call('PATCH', path, {'status': 'INACTIVE'}, '"2"'))
assert patched['version'] == 3 and patched['priceMinor'] == 200 and patched['name'] == 'ノート'
expect(412, call('DELETE', path, version='"2"'))

with ThreadPoolExecutor(max_workers=2) as workers:
    parallel = list(workers.map(lambda name: call('PATCH', path, {'name': name}, '"3"'), ['first', 'second']))
assert sorted(response[0] for response in parallel) == [200, 412], parallel
assert expect(200, call('GET', path))['version'] == 4

products = [expect(201, call('POST', '/products', body | {'name': str(number)})) for number in range(4)]
ids = {product['id'] for product in products} | {created['id']}
eventually(lambda: {product['id'] for product in query(category=category, limit=100)['items']} == ids)
seen = []
parameters = {'category': category, 'limit': 2}
for _ in range(8):
    page = query(**parameters)
    assert len(page['items']) <= 2
    seen.extend(page['items'])
    if page['nextToken'] is None:
        break
    expect(400, call('GET', '/products?' + urlencode(dict(category='wrong', nextToken=page['nextToken']))))
    parameters['nextToken'] = page['nextToken']
else:
    raise AssertionError('pagination did not finish')
assert len(seen) == len(ids) and {product['id'] for product in seen} == ids, seen
assert seen == sorted(seen, key=lambda item: (datetime.fromisoformat(item['createdAt']), item['id']), reverse=True)
assert query(limit=1)['items']

deleted = call('DELETE', path, version='"4"')
expect(204, deleted)
assert deleted[1]['ETag'] == '"5"'
expect(404, call('GET', path))
expect(404, call('PATCH', path, {'name': 'no'}, '"5"'))
expect(404, call('DELETE', path, version='"5"'))
eventually(lambda: {product['id'] for product in query(category=category)['items']} == ids - {created['id']})
print(f'CRUD, concurrency and pagination passed ({MODE}, {BASE})', flush=True)
