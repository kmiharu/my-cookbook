#!/usr/bin/env python3
"""Exercise real DynamoDB Local stream records through the worker and SAM handler."""

from datetime import datetime, timezone
import hashlib
import hmac
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
from urllib.error import HTTPError, URLError
from urllib.request import Request, ProxyHandler, build_opener
from uuid import uuid4

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'scripts' / 'local.sh'
ENV = os.environ | {
    'COMPOSE_PROJECT_NAME': 'products-sync-' + uuid4().hex[:9],
    'API_PORT': '',
    'DYNAMODB_PORT': '',
    'POSTGRES_PORT': '',
}
HTTP = build_opener(ProxyHandler({}))
CATEGORY = 'sync-' + uuid4().hex[:12]


def local(*arguments, capture=False):
    result = subprocess.run(
        [str(SCRIPT), *arguments],
        cwd=ROOT,
        env=ENV,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        check=True,
    )
    return result.stdout if capture else None


def compose(*arguments, capture=False):
    return local('compose', 'hybrid', *arguments, capture=capture)


def endpoint(service, internal_port):
    port = int(compose('port', service, str(internal_port), capture=True).strip().rsplit(':', 1)[1])
    return f'http://127.0.0.1:{port}'


def api(base, method, path, status, data=None, version=None):
    headers = {}
    payload = None
    if data is not None:
        headers['Content-Type'] = 'application/json'
        payload = json.dumps(data).encode()
    if version is not None:
        headers['If-Match'] = f'"{version}"'
    try:
        response = HTTP.open(Request(base + path, data=payload, headers=headers, method=method), timeout=45)
    except HTTPError as failure:
        response = failure
    with response:
        raw = response.read()
        assert response.status == status, (method, path, status, response.status, raw)
        return json.loads(raw) if raw else None


def insert(base, name):
    body = dict(name=name, category=CATEGORY, priceMinor=100, status='ACTIVE')
    return api(base, 'POST', '/products', 201, body)


def list_products(base):
    return {product['id']: product for product in api(base, 'GET', f'/products?category={CATEGORY}&limit=100', 200)['items']}


def eventually(description, condition, seconds=45):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if result := condition():
            return result
        time.sleep(0.2)
    raise AssertionError(f'Timed out waiting for {description}')


def database(sql):
    return compose('exec', '-T', 'postgres', 'psql', '-U', 'products', '-d', 'products',
                   '-X', '-A', '-t', '-v', 'ON_ERROR_STOP=1', '-c', sql, capture=True).strip()


def projection(product_id):
    return database(f"SELECT version, deleted, name FROM products WHERE id = '{product_id}'")


def files(directory):
    return sorted(compose('exec', '-T', 'worker', 'sh', '-c',
                          f'find /sync/{directory} -name "*.properties" -type f -print',
                          capture=True).splitlines())


def checkpoint():
    return compose('exec', '-T', 'worker', 'sh', '-c',
                   'find /sync/checkpoints -name "*.properties" -type f -exec cat {} +', capture=True)


def local_dynamo(base, service, action, body):
    """Send the Streams wire request to the loopback address with dummy SigV4 credentials."""
    payload = json.dumps(body, separators=(',', ':')).encode()
    now = datetime.now(timezone.utc)
    timestamp, date = now.strftime('%Y%m%dT%H%M%SZ'), now.strftime('%Y%m%d')
    prefix = 'DynamoDBStreams' if service == 'streams' else 'DynamoDB'
    headers = {
        'content-type': 'application/x-amz-json-1.0',
        'host': base.removeprefix('http://'),
        'x-amz-date': timestamp,
        'x-amz-target': f'{prefix}_20120810.{action}',
    }
    header_names = ';'.join(headers)
    canonical = '\n'.join([
        'POST', '/', '', ''.join(f'{key}:{value}\n' for key, value in headers.items()),
        header_names, hashlib.sha256(payload).hexdigest(),
    ])
    scope = f'{date}/us-east-1/dynamodb/aws4_request'

    def sign(key, value):
        return hmac.digest(key, value.encode(), 'sha256')

    key = b'AWS4local'
    for value in scope.split('/'):
        key = sign(key, value)
    message = f'AWS4-HMAC-SHA256\n{timestamp}\n{scope}\n{hashlib.sha256(canonical.encode()).hexdigest()}'
    signature = sign(key, message).hex()
    headers['authorization'] = (
        f'AWS4-HMAC-SHA256 Credential=local/{scope}, SignedHeaders={header_names}, Signature={signature}'
    )
    try:
        with HTTP.open(Request(base + '/', data=payload, headers=headers), timeout=15) as response:
            return json.load(response)
    except HTTPError as failure:
        raise AssertionError((service, action, failure.code, failure.read())) from failure


def stream_records(base):
    arn = local_dynamo(base, 'table', 'DescribeTable', {'TableName': 'products'})['Table']['LatestStreamArn']
    request = {'StreamArn': arn}
    while True:
        stream = local_dynamo(base, 'streams', 'DescribeStream', request)['StreamDescription']
        for shard in stream['Shards']:
            iterator = local_dynamo(base, 'streams', 'GetShardIterator', {
                'StreamArn': arn, 'ShardId': shard['ShardId'], 'ShardIteratorType': 'TRIM_HORIZON',
            })['ShardIterator']
            while iterator:
                batch = local_dynamo(base, 'streams', 'GetRecords', {'ShardIterator': iterator, 'Limit': 100})
                for record in batch.get('Records', []):
                    yield record | {'eventSourceARN': arn}
                if not batch.get('Records'):
                    break
                iterator = batch.get('NextShardIterator')
        after = stream.get('LastEvaluatedShardId')
        if not after:
            break
        request['ExclusiveStartShardId'] = after


def collect(base, selected):
    found = {}
    for record in stream_records(base):
        stream = record['dynamodb']
        name = record['eventName']
        image = stream['OldImage' if name == 'REMOVE' else 'NewImage']
        key = (image['id']['S'], name, int(image['version']['N']))
        if key in selected:
            found[key] = record
    return found if found.keys() == set(selected) else None


def invoke(directory, name, records):
    path = Path(directory) / f'{name}.json'
    path.write_text(json.dumps({'Records': records}), encoding='utf-8')
    result = local('sam-invoke', 'hybrid', 'SyncFunction', str(path), capture=True)
    for line in reversed(result.splitlines()):
        try:
            response = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(response, dict) and 'batchItemFailures' in response:
            return response['batchItemFailures']
    raise AssertionError(f'SAM did not return a Streams result: {result}')


def verify(base, dynamo):
    compose('stop', 'worker')
    logical = insert(base, 'initial')
    logical_id = logical['id']
    path = '/products/' + logical_id
    assert api(base, 'GET', path, 200) == logical
    assert logical_id not in list_products(base), 'POST updated the search database synchronously'
    compose('start', 'worker')
    eventually('creation to be projected', lambda: list_products(base).get(logical_id) == logical)

    patched = api(base, 'PATCH', path, 200, {'name': 'edited'}, 1)
    eventually('first update', lambda: list_products(base).get(logical_id) == patched)
    replaced = api(base, 'PUT', path, 200, dict(name='latest', category=CATEGORY, priceMinor=300, status='INACTIVE'), 2)
    eventually('second update', lambda: list_products(base).get(logical_id) == replaced)
    api(base, 'DELETE', path, 204, version=3)
    api(base, 'GET', path, 404)
    eventually('logical tombstone', lambda: projection(logical_id) == '4|t|latest')
    assert logical_id not in list_products(base)

    physical = insert(base, 'physical')
    physical_id = physical['id']
    eventually('physical-delete example inserted', lambda: list_products(base).get(physical_id) == physical)
    local('exec', 'hybrid', 'cookbook.api.db.DynamoAdmin', 'purge', physical_id, '1')
    api(base, 'GET', '/products/' + physical_id, 404)
    eventually('physical tombstone from OldImage', lambda: projection(physical_id) == '1|t|physical')
    assert physical_id not in list_products(base)

    compose('stop', 'postgres')
    recovering = insert(base, 'recovery')
    recovering_id = recovering['id']
    assert api(base, 'GET', '/products/' + recovering_id, 200) == recovering
    eventually('failed stream event to be spooled', lambda: files('failed'))
    recovery_key = (recovering_id, 'INSERT', 1)
    recovery_record = eventually('real failed record', lambda: collect(dynamo, [recovery_key]))[recovery_key]
    recovery_sequence = recovery_record['dynamodb']['SequenceNumber']
    assert f'sequence={recovery_sequence}\n' not in checkpoint(), 'a failed projection advanced its checkpoint'
    compose('stop', 'worker')
    compose('start', 'postgres')

    def postgres_ready():
        result = subprocess.run(
            [str(SCRIPT), 'compose', 'hybrid', 'exec', '-T', 'postgres',
             'pg_isready', '-h', '127.0.0.1', '-U', 'products', '-d', 'products'],
            env=ENV, cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        return result.returncode == 0

    eventually('PostgreSQL to recover', postgres_ready)
    local('sync', 'hybrid', 'replay')
    assert list_products(base).get(recovering_id) == recovering
    compose('start', 'worker')
    eventually('worker to acknowledge the successful replay', lambda: f'sequence={recovery_sequence}\n' in checkpoint())
    assert not files('failed') and len(files('replayed')) == 1

    compose('stop', 'worker')
    database(f"DELETE FROM products WHERE id = '{physical_id}'")
    local('sync', 'hybrid', 'backfill')
    assert projection(physical_id) == '1|t|physical'
    database(f"DELETE FROM products WHERE id IN ('{physical_id}', '{logical_id}')")
    local('sync', 'hybrid', 'rebuild')
    assert projection(physical_id) == '1|t|physical'
    assert projection(logical_id) == '4|t|latest'
    assert list_products(base).get(recovering_id) == recovering
    print('Hybrid Streams, PostgreSQL outage and replay, backfill and rebuild passed.', flush=True)

    untouched = insert(base, 'newer survives stale active update')
    untouched_id = untouched['id']
    untouched_path = '/products/' + untouched_id
    api(base, 'PATCH', untouched_path, 200, {'name': 'newer'}, 1)
    rejected = insert(base, 'reject one')
    accepted = insert(base, 'accept one')
    rejected_id, accepted_id = rejected['id'], accepted['id']
    selected = [
        (untouched_id, 'MODIFY', 2),
        (untouched_id, 'INSERT', 1),
        (logical_id, 'MODIFY', 3),
        (physical_id, 'INSERT', 1),
        (physical_id, 'REMOVE', 1),
        (rejected_id, 'INSERT', 1),
        (accepted_id, 'INSERT', 1),
    ]
    records = eventually('all original DynamoDB Stream events', lambda: collect(dynamo, selected))
    database(f"ALTER TABLE products ADD CONSTRAINT reject_one_event CHECK (id <> '{rejected_id}')")
    with tempfile.TemporaryDirectory(prefix='products-sync-') as directory:
        batch = [records[key] for key in selected]
        failed_sequence = records[selected[-2]]['dynamodb']['SequenceNumber']
        assert invoke(directory, 'mixed', batch + [batch[0], batch[-1]]) == [{'itemIdentifier': failed_sequence}]
        assert projection(untouched_id) == '2|f|newer'
        assert projection(logical_id) == '4|t|latest'
        assert projection(physical_id) == '1|t|physical'
        assert projection(rejected_id) == ''
        assert projection(accepted_id) == '1|f|accept one'
        database('ALTER TABLE products DROP CONSTRAINT reject_one_event')
        # An AWS event source may replay successful later records when the earlier record failed.
        assert invoke(directory, 'retry', batch[-2:]) == []
        assert projection(rejected_id) == '1|f|reject one'
        assert projection(accepted_id) == '1|f|accept one'

    assert list_products(base).get(accepted_id) == accepted
    print('SAM Streams deduplication, ordering, partial batch and retry passed.', flush=True)


def main():
    try:
        local('up', 'hybrid')
        base, dynamo = endpoint('api', 8080), endpoint('dynamodb', 8000)

        def api_ready():
            try:
                api(base, 'GET', '/products', 200)
                return True
            except (URLError, AssertionError):
                return False

        eventually('hybrid API', api_ready)
        verify(base, dynamo)
    except Exception:
        subprocess.run([str(SCRIPT), 'compose', 'hybrid', 'logs', '--tail', '50'], cwd=ROOT, env=ENV)
        raise
    finally:
        subprocess.run([str(SCRIPT), 'down', 'hybrid', '--volumes'], cwd=ROOT, env=ENV, check=sys.exc_info()[0] is None)


if __name__ == '__main__':
    main()
