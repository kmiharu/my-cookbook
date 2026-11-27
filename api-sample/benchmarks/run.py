"""Run isolated Linux benchmarks. All service addresses are fixed to loopback."""

import contextlib
import datetime as dt
import json
import os
import pathlib
import platform
import signal
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request


ROOT = pathlib.Path(__file__).resolve().parent.parent
LOCAL = ROOT / 'scripts/local.sh'
TOOLS = ROOT / 'scripts/tools.sh'
K6_IMAGE = 'grafana/k6:2.4.0@sha256:d41bb79cd8de5a7ad619b53570e3712633e8bff0937010a5c6c57a4747e7a276'
RUN_ID = f'{dt.datetime.now(dt.UTC):%Y%m%dT%H%M%SZ}-{os.getpid()}'
RESULTS = ROOT / '.local/benchmarks' / RUN_ID
BUILD = RESULTS / 'build'
LIB = BUILD / 'install/products-api/lib/*'
LAUNCHER = BUILD / 'install/products-api/bin/products-api'
NATIVE = BUILD / 'native/nativeCompile/products-api'
HEAP = ['-Xms64m', '-Xmx256m']
MEASURE_ARGS = [*HEAP, '-Dlogger.levels.cookbook.api.RequestLog=OFF']
# Remove any inherited cloud credentials and browser/network proxies from clients under test.
ENV = {k: v for k, v in os.environ.items()
       if not k.startswith(('AWS_', 'PG_', 'DYNAMODB_', 'K6_'))
       and k not in ('JDK_JAVA_OPTIONS', 'JAVA_TOOL_OPTIONS', '_JAVA_OPTIONS')}
ENV.update(AWS_ACCESS_KEY_ID='local', AWS_SECRET_ACCESS_KEY='local', AWS_REGION='us-east-1',
           AWS_EC2_METADATA_DISABLED='true', AWS_CONFIG_FILE=os.devnull,
           AWS_SHARED_CREDENTIALS_FILE=os.devnull, K6_NO_USAGE_REPORT='true')
HTTP = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def call(args, env=ENV, *, capture=False, data=None, timeout=300):
    return subprocess.run([str(arg) for arg in args], cwd=ROOT, env=env,
                          input=data, timeout=timeout, text=True, check=True,
                          stdout=subprocess.PIPE if capture else None).stdout


def option(name, default, minimum):
    value = int(os.environ.get(name, default))
    if value < minimum:
        raise ValueError(f'{name} must be at least {minimum}')
    return value


def system_setting(path):
    try:
        return pathlib.Path(path).read_text().strip()
    except OSError:
        return 'unavailable'


def save(path, data):
    with path.open('w') as stream:
        json.dump(data, stream, indent=2)
        stream.write('\n')


def until(read, timeout=30):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if result := read():
            return result
        time.sleep(.05)
    raise TimeoutError('condition was not met before deadline')


def port():
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        return listener.getsockname()[1]


def request(base, path, body=None, headers=None, timeout=8):
    headers = dict(headers or {})
    data = None
    if body is not None:
        headers['Content-Type'] = 'application/json'
        data = json.dumps(body).encode()
    with HTTP.open(urllib.request.Request(base + path, data=data, headers=headers), timeout=timeout) as response:
        return json.load(response)


def wait_api(base, process):
    def ready():
        if process.poll() is not None:
            raise RuntimeError(f'API exited with {process.returncode}. See process log in {RESULTS}')
        try:
            with socket.create_connection(('127.0.0.1', int(base.rsplit(':', 1)[1])), timeout=.2):
                return True
        except OSError:
            return False
    until(ready, timeout=60)


def application_env(stack, app_port, java_home, pool=8):
    return dict(stack, APP_RUNTIME='local', APP_ROLE='api', JAVA_HOME=str(java_home),
                MICRONAUT_SERVER_HOST='127.0.0.1', API_LISTEN_PORT=str(app_port),
                MICRONAUT_SERVER_PORT=str(app_port),
                DYNAMODB_ENDPOINT=f"http://127.0.0.1:{stack['DYNAMODB_PORT']}", DYNAMODB_TABLE='products',
                PG_JDBC_URL=f"jdbc:postgresql://127.0.0.1:{stack['POSTGRES_PORT']}/products",
                PG_USER='products', PG_PASSWORD='products', PG_POOL_SIZE=str(pool),
                JAVA_OPTS=' '.join(MEASURE_ARGS))


@contextlib.contextmanager
def process(args, env, label):
    with (RESULTS / f'{label}.log').open('w') as log:
        with subprocess.Popen([str(arg) for arg in args], stdout=log, stderr=log,
                              cwd=ROOT, env=env, start_new_session=True) as child:
            try:
                yield child
            finally:
                if child.poll() is None:
                    os.killpg(child.pid, signal.SIGTERM)
                    try:
                        child.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        os.killpg(child.pid, signal.SIGKILL)
                        child.wait(timeout=5)


@contextlib.contextmanager
def stack(mode, java_home):
    project = f'cookbook-bench-{os.getpid()}-{mode}'
    # Docker assigns a different published port on restart when the mapping is empty.
    # Keep Hybrid's PostgreSQL address stable while measuring outage recovery.
    service = dict(ENV, COMPOSE_PROJECT_NAME=project, DATABASE_TYPE=mode, DYNAMODB_PORT='',
                   POSTGRES_PORT=str(port()) if mode == 'hybrid' else '')
    compose = [LOCAL, 'compose', mode]
    try:
        if mode != 'aurora':
            call([*compose, 'up', '-d', 'dynamodb'], service)
        if mode != 'dynamodb':
            call([*compose, 'up', '-d', '--wait', '--wait-timeout', '45', 'postgres'], service)
        admin = dict(service, DYNAMODB_PORT='1', POSTGRES_PORT='1')
        if mode != 'aurora':
            admin['DYNAMODB_PORT'] = call([*compose, 'port', 'dynamodb', '8000'], service,
                                             capture=True).strip().rsplit(':', 1)[1]
        if mode != 'dynamodb':
            admin['POSTGRES_PORT'] = call([*compose, 'port', 'postgres', '5432'], service,
                                             capture=True).strip().rsplit(':', 1)[1]
        if mode != 'aurora':
            def dynamo_available():
                try:
                    with socket.create_connection(('127.0.0.1', int(admin['DYNAMODB_PORT'])), timeout=.2):
                        return True
                except OSError:
                    return False
            until(dynamo_available)
            call(java_main(java_home, 'cookbook.api.db.DynamoAdmin', 'init'), application_env(admin, port(), java_home))
        if mode != 'dynamodb':
            call(java_main(java_home, 'cookbook.api.db.PostgresAdmin', 'migrate'), application_env(admin, port(), java_home))
        yield admin
    finally:
        try:
            call([LOCAL, 'down', mode, '--volumes', '--rmi', 'local'], service, timeout=60)
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
            print(f'Cleanup failed for {project}: {error}', file=sys.stderr)


def docker_container(stack_env, service):
    project = stack_env['COMPOSE_PROJECT_NAME']
    result = call(['docker', 'ps', '-aq', '--filter', f'label=com.docker.compose.project={project}',
                   '--filter', f'label=com.docker.compose.service={service}'], capture=True).split()
    if len(result) != 1:
        raise RuntimeError(f'Expected one {service} container for {project}, found {len(result)}')
    return result[0]


def psql(container, sql):
    return call(['docker', 'exec', '-i', container, 'psql', '-XqtA', '-v', 'ON_ERROR_STOP=1',
                 '-U', 'products', '-d', 'products'], data=sql, capture=True)


def seed_postgres(container, count):
    psql(container, f"""
      INSERT INTO products (id,name,category,price_minor,status,version,created_at,updated_at,deleted)
      SELECT ('00000000-0000-4000-8000-' || lpad(to_hex(n),12,'0'))::uuid,
             'Benchmark product ' || n, 'bench-' || n % 10, n, 'ACTIVE', 1,
             TIMESTAMPTZ '2026-01-01 00:00:00Z' + n * INTERVAL '1 millisecond',
             TIMESTAMPTZ '2026-01-01 00:00:00Z' + n * INTERVAL '1 millisecond', false
        FROM generate_series(1, {count}) AS n;
      VACUUM ANALYZE products;
    """)


def sql_compare(container, count, repeats):
    query = "FROM products WHERE NOT deleted AND category = 'bench-0'"
    order = 'ORDER BY created_at DESC, id DESC'
    offset = min(int((count // 10) * .9), count // 10 - 20)
    # Materialize the boundary once. Building it with OFFSET inside the timed query
    # would measure the cost that keyset pagination avoids.
    boundary = psql(container, f"SELECT quote_literal(created_at), quote_literal(id) {query} {order} "
                               f'OFFSET {offset - 1} LIMIT 1;').strip().split('|')
    keyset_query = f"SELECT id {query} AND (created_at,id) < ({boundary[0]}::timestamptz,{boundary[1]}::uuid) {order} LIMIT 20"
    offset_query = f'SELECT id {query} {order} LIMIT 20 OFFSET {offset}'
    offset_rows = psql(container, offset_query).splitlines()
    if len(offset_rows) != 20 or offset_rows != psql(container, keyset_query).splitlines():
        raise RuntimeError(f'Expected two matching 20-row SQL pages after position {offset}')
    first = f'SELECT id {query} {order} LIMIT 20'

    def explain(statement):
        return json.loads(psql(container, f'EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) {statement};'))[0]

    samples = {name: [explain(statement) for _ in range(repeats)] for name, statement in
               [('indexed', first), ('offset', offset_query), ('keyset', keyset_query)]}
    psql(container, 'DROP INDEX products_listing_idx, products_category_listing_idx; ANALYZE products;')
    samples['unindexed'] = [explain(first) for _ in range(repeats)]
    return dict(offset=offset, samples=samples)


def install_k6():
    command = RESULTS / 'k6'
    if subprocess.run(['docker', 'image', 'inspect', K6_IMAGE], env=ENV,
                      stderr=subprocess.DEVNULL, stdout=subprocess.DEVNULL).returncode:
        call(['docker', 'pull', K6_IMAGE], timeout=300)
    container = call(['docker', 'create', '--pull', 'never', K6_IMAGE], capture=True).strip()
    try:
        call(['docker', 'cp', f'{container}:/usr/bin/k6', command])
    finally:
        call(['docker', 'rm', container], capture=True)
    command.chmod(0o755)
    return command


def proc_memory(pid):
    fields = {}
    for line in pathlib.Path(f'/proc/{pid}/status').read_text().splitlines():
        name, _, remainder = line.partition(':')
        if name in ('VmRSS', 'VmHWM'):
            fields[name] = int(remainder.split()[0]) * 1024
    return fields


def load(k6, base, label, vus, warmup, duration):
    def run(seconds, stage):
        raw = RESULTS / f'{label}-{stage}.json'
        env = dict(ENV, BENCH_BASE=base, BENCH_K6_OUTPUT=str(raw))
        call([k6, 'run', '--quiet', '--vus', vus, '--duration', f'{seconds}s',
              ROOT / 'benchmarks/list.js'], env, timeout=seconds + 45)
        return json.loads(raw.read_text())['metrics']

    if warmup:
        run(warmup, 'warmup')
    metrics = run(duration, 'measured')
    times = metrics['http_req_duration']['values']
    valid_rate = metrics['checks']['values']['rate']
    if not valid_rate:
        raise RuntimeError(f'No valid list responses for {label}. See the k6 summary in {RESULTS}')
    return dict(p50_ms=times['p(50)'], p95_ms=times['p(95)'], p99_ms=times['p(99)'],
                requests_per_sec=metrics['http_reqs']['values']['rate'],
                error_rate=metrics['http_req_failed']['values']['rate'],
                page_validation_error_rate=1 - valid_rate)


def api_measure(stack_env, java_home, k6, label, kind, pool, vus, warmup, duration):
    app_port = port()
    base = f'http://127.0.0.1:{app_port}'
    args = [LAUNCHER] if kind == 'jvm' else [NATIVE, *MEASURE_ARGS]
    started = time.monotonic()
    with process(args, application_env(stack_env, app_port, java_home, pool), label) as app:
        wait_api(base, app)
        listening = time.monotonic()
        first = request(base, '/products/00000000-0000-4000-8000-000000000001', timeout=20)
        responded = time.monotonic()
        if first['name'] != 'Benchmark product 1':
            raise RuntimeError('Unexpected first-response product')
        statistics = load(k6, base, label, vus, warmup, duration)
        return dict(startup_ms=(listening - started) * 1000,
                    first_response_ms=(responded - listening) * 1000,
                    **proc_memory(app.pid), **statistics)


def aurora_measure(command, java_home, k6, count, repeats, warmup, duration, report):
    with stack('aurora', java_home) as aurora:
        postgres = docker_container(aurora, 'postgres')
        seed_postgres(postgres, count)
        scenarios = ([(kind, 8, 1) for kind in ('jvm', 'native')] if command == 'native'
                     else [('jvm', pool, vus) for pool in (2, 8) for vus in (1, 8, 32)])
        report['http'] = {}
        for kind, pool, vus in scenarios:
            scenario = f'{kind}-pool{pool}-vus{vus}'
            report['http'][scenario] = []
            for repeat in range(repeats):
                sample = api_measure(aurora, java_home, k6, f'{scenario}-{repeat}',
                                     kind, pool, vus, warmup, duration)
                report['http'][scenario].append(sample)
                save(RESULTS / 'report.json', report)
        if command == 'suite':
            report['sql'] = sql_compare(postgres, count, repeats)


def java_main(java_home, entrypoint, *args):
    return [java_home / 'bin/java', '-cp', LIB, entrypoint, *args]


def projection_visible(base, item):
    try:
        page = request(base, f"/products?category={item['category']}")
        return any(found['id'] == item['id'] for found in page['items'])
    except (OSError, urllib.error.HTTPError):
        return False


def sync_measure(stack_env, java_home, repeats):
    state = RESULTS / 'worker-state'
    pg = docker_container(stack_env, 'postgres')
    app_port = port()
    base = f'http://127.0.0.1:{app_port}'
    env = application_env(stack_env, app_port, java_home)
    worker = java_main(java_home, 'cookbook.api.sync.SyncMain', 'worker')

    def write(category):
        item = request(base, '/products', dict(name='Sync latency', category=category, priceMinor=1, status='ACTIVE'))
        return time.monotonic(), item

    with process(worker, dict(env, APP_ROLE='sync', SYNC_STATE_DIR=str(state)), 'sync-worker'):
        with process([LAUNCHER], env, 'sync-http') as app:
            wait_api(base, app)
            lag = []
            for index in range(repeats + 1):
                began, item = write(f'bench-lag-{index}')
                until(lambda: projection_visible(base, item))
                if index:
                    lag.append((time.monotonic() - began) * 1000)
            call(['docker', 'stop', '--timeout', '1', pg])
            try:
                _, delayed = write('bench-recovery')
                until(lambda: next((state / 'failed').glob('*.properties'), None))
            finally:
                recovery = time.monotonic()
                call(['docker', 'start', pg], capture=True)
            until(lambda: projection_visible(base, delayed), timeout=60)
            return dict(lag_ms=lag, recovery_ms=(time.monotonic() - recovery) * 1000)


def native_smoke(java_home, report):
    for mode in ('dynamodb', 'aurora', 'hybrid'):
        try:
            with stack(mode, java_home) as stack_env, contextlib.ExitStack() as run:
                app_port = port()
                base = f'http://127.0.0.1:{app_port}'
                env = application_env(stack_env, app_port, java_home)
                if mode == 'hybrid':
                    run.enter_context(process(java_main(java_home, 'cookbook.api.sync.SyncMain', 'worker'),
                        dict(env, APP_ROLE='sync', SYNC_STATE_DIR=str(RESULTS / 'native-worker-state')), 'native-sync'))
                app = run.enter_context(process([NATIVE, *MEASURE_ARGS], env, f'native-smoke-{mode}'))
                wait_api(base, app)
                call([sys.executable, ROOT / 'tests/e2e.py', base, mode], timeout=180)
            report['native_smoke'][mode] = 'passed'
        except Exception:
            report['native_smoke'][mode] = 'failed'
            raise
        finally:
            save(RESULTS / 'report.json', report)


def main(command):
    if platform.system() != 'Linux':
        raise RuntimeError('The benchmark runner uses Linux processes and /proc')
    count = option('BENCH_DATASET_SIZE', 10000, 400)
    repeats = option('BENCH_REPETITIONS', 3, 1)
    warmup = option('BENCH_WARMUP_SECONDS', 10, 0)
    duration = option('BENCH_DURATION_SECONDS', 30, 1)
    RESULTS.mkdir(parents=True)
    report_path = RESULTS / 'report.json'
    report = dict(command=command, status='running', data_count=count, repeats=repeats,
                  warmup_s=warmup, duration_s=duration, os=platform.platform(),
                  architecture=platform.machine(), cpu_affinity_count=len(os.sched_getaffinity(0)),
                  cgroup_cpu=system_setting('/sys/fs/cgroup/cpu.max'),
                  cgroup_memory=system_setting('/sys/fs/cgroup/memory.max'),
                  heap=HEAP)
    print(f'Artifacts: {RESULTS}', flush=True)
    save(report_path, report)
    try:
        call([TOOLS, 'install', 'nik'], timeout=600)
        java_home = pathlib.Path(call([TOOLS, 'path', 'nik'], capture=True).strip()).resolve()
        java_env = dict(ENV, JAVA_HOME=str(java_home), PATH=f"{java_home / 'bin'}:{ENV['PATH']}",
                        BENCH_GRADLE_BUILD=str(BUILD), COOKBOOK_GRADLE_LOCK=str(RESULTS / 'gradle.lock'))
        init_script = RESULTS / 'isolated-build.gradle'
        configure_build = "gradle.beforeProject { p -> p.layout.buildDirectory.set(new File(System.getenv('BENCH_GRADLE_BUILD'))) }\n"
        if command != 'suite':
            quick = os.environ.get('BENCH_NATIVE_QUICK') == '1'
            report['native_build_flags'] = ['-Ob', '--parallelism=4'] if quick else []
            if quick:
                configure_build += """
                    gradle.projectsEvaluated {
                        gradle.rootProject.graalvmNative.binaries.named('main') {
                            buildArgs.addAll('-Ob', '--parallelism=4')
                        }
                    }
                """
        init_script.write_text(configure_build)
        if command != 'suite':
            report['native_smoke'] = dict.fromkeys(('dynamodb', 'aurora', 'hybrid'), 'pending')
        report['java_version'] = subprocess.check_output([java_home / 'bin/java', '-version'],
            stderr=subprocess.STDOUT, text=True).strip()
        report['docker_version'] = call(['docker', 'version', '--format', '{{.Server.Version}}'], capture=True).strip()
        report['build_seconds'] = {}
        targets = ['installDist'] if command == 'suite' else ['installDist', 'nativeCompile']
        for target in targets:
            begin = time.monotonic()
            call([ROOT / 'scripts/gradle.sh', '--no-daemon', '--rerun-tasks', '--project-cache-dir',
                  RESULTS / 'gradle-project-cache', '--init-script', init_script, target], java_env, timeout=2700)
            report['build_seconds'][target] = time.monotonic() - begin
            save(report_path, report)
        if command != 'suite':
            native_smoke(java_home, report)
        if command != 'smoke':
            k6 = install_k6()
            report['k6_version'] = call([k6, 'version'], capture=True).strip()
            if command == 'suite':
                with stack('dynamodb', java_home) as dynamo:
                    argv = java_main(java_home, 'cookbook.api.db.DynamoAdmin', 'benchmark', count)
                    report['dynamo'] = []
                    for _ in range(repeats):
                        output = call(argv, application_env(dynamo, port(), java_home), capture=True,
                                      timeout=max(300, count // 10))
                        sample = next(line for line in output.splitlines() if line.startswith('{"rows":'))
                        report['dynamo'].append(json.loads(sample))
                        save(report_path, report)
                save(report_path, report)
            aurora_measure(command, java_home, k6, count, repeats, warmup, duration, report)
            if command == 'suite':
                save(report_path, report)
                with stack('hybrid', java_home) as hybrid:
                    report['sync'] = sync_measure(hybrid, java_home, repeats)
        report['status'] = 'passed'
    except BaseException as error:
        report['status'] = 'failed'
        report['error'] = str(error) or type(error).__name__
        raise
    finally:
        save(report_path, report)


if __name__ == '__main__':
    if len(sys.argv) != 2 or sys.argv[1] not in ('suite', 'native', 'smoke'):
        sys.exit('Usage: benchmarks/run.sh suite|native|smoke')
    main(sys.argv[1])
