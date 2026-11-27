#!/usr/bin/env bash
set -euo pipefail

sample=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
if [[ -z ${JAVA_HOME:-} ]] && ! command -v javac >/dev/null; then
    JAVA_HOME=$("$sample/scripts/tools.sh" install jdk)
    export JAVA_HOME
fi
# The wrapper JVM does not read HTTPS_PROXY. Translate a credential-free proxy
# URL when the caller has not already set JVM networking options.
if [[ -n ${HTTPS_PROXY:-} && -z ${JAVA_TOOL_OPTIONS:-} && -z ${GRADLE_OPTS:-} ]]; then
    proxy_options=$(python3 - <<'PY'
import os
from urllib.parse import urlparse

proxy = urlparse(os.environ["HTTPS_PROXY"])
if proxy.scheme == "http" and proxy.hostname and not proxy.username:
    hosts = os.getenv("NO_PROXY", "localhost,127.0.0.1").replace(",", "|")
    print(
        f"-Dhttp.proxyHost={proxy.hostname} -Dhttp.proxyPort={proxy.port or 80} "
        f"-Dhttps.proxyHost={proxy.hostname} -Dhttps.proxyPort={proxy.port or 80} "
        f"-Dhttp.nonProxyHosts={hosts}"
    )
PY
)
    export JAVA_TOOL_OPTIONS=$proxy_options
    if [[ -f /etc/ssl/certs/java/cacerts ]]; then
        export JAVA_TOOL_OPTIONS="$JAVA_TOOL_OPTIONS -Djavax.net.ssl.trustStore=/etc/ssl/certs/java/cacerts"
    fi
fi
if command -v flock >/dev/null; then
    mkdir -p "$sample/.local"
    exec flock --close "${COOKBOOK_GRADLE_LOCK:-$sample/.local/gradle.lock}" "$sample/app/gradlew" -p "$sample/app" "$@"
fi
exec "$sample/app/gradlew" -p "$sample/app" "$@"
