#!/usr/bin/env bash
set -euo pipefail

sample=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tool_dir="$sample/.local/tools"
action=${1:-}
tool=${2:-}

case "$tool" in
    jdk)
        version=21.0.13+9
        path="$tool_dir/temurin-$version"
        ;;
    sam)
        version=1.174.1
        path="$tool_dir/sam-$version/bin/sam"
        version_output="SAM CLI, version $version"
        ;;
    terraform)
        version=1.13.5
        path="$tool_dir/terraform-$version/terraform"
        version_output="Terraform v$version"
        ;;
    nik)
        version=23.1.13+1-21.0.13.0.3+6
        path="$tool_dir/nik-$version"
        ;;
    *)
        echo "Usage: $0 {path|install} {jdk|sam|terraform|nik}" >&2
        exit 2
        ;;
esac

resolve() {
    if [[ $tool == jdk ]]; then
        if [[ -x $path/bin/javac ]]; then
            printf '%s\n' "$path"
            return 0
        fi
    elif [[ $tool == nik ]]; then
        local candidate=${NIK_HOME:-$path}
        if [[ -x $candidate/bin/native-image ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    else
        if [[ -x $path ]]; then
            printf '%s\n' "$path"
            return 0
        fi
        if command -v "$tool" >/dev/null && [[ $("$tool" --version | sed -n '1p') == "$version_output" ]]; then
            command -v "$tool"
            return 0
        fi
    fi
    return 1
}

if [[ $action == path ]]; then
    if ! resolve; then
        echo "$tool $version is missing. Run $0 install $tool" >&2
        exit 1
    fi
    exit 0
fi
if [[ $action != install ]]; then
    echo "Usage: $0 {path|install} {jdk|sam|terraform|nik}" >&2
    exit 2
fi
if resolve; then
    exit 0
fi
if [[ $(uname -s) != Linux ]]; then
    echo 'Automatic tool installation requires Linux. Install the pinned tool locally.' >&2
    exit 1
fi
case $(uname -m) in
    x86_64) sam_arch=x86_64; tf_arch=amd64; jdk_arch=x64 ;;
    aarch64|arm64) sam_arch=arm64; tf_arch=arm64; jdk_arch=aarch64 ;;
    *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

mkdir -p "$tool_dir"
temp=$(mktemp -d "$tool_dir/.download.XXXXXX")
trap 'rm -rf -- "$temp"' EXIT
archive="$temp/download"
case "$tool:$tf_arch" in
    jdk:amd64) sum=d7f5d5cf865a2902b70ff549b97586a7d3f234e016f041ab447ea740c7d66d1c ;;
    jdk:arm64) sum=e3522e707fc7dbe2a72c30746b1e7068301a0213ecd213d4491f35a14eb55578 ;;
    sam:amd64) sum=34e0117b933482f4df54667af67e47fc82b087b64392304b1481442ca6da1005 ;;
    sam:arm64) sum=c62d803d59146b0d4087ca7fd42501d78e0c93570296ef64363e7487d29f5d0f ;;
    terraform:amd64) sum=0dbe3fcc268eb670801af6a6456799d1ae26e72e73797f6c6167e18aafd1fd9a ;;
    terraform:arm64) sum=fc1ddcb403fb57e25bdbdceb1ef2b1a102650c01b4d65dd3410082d2ef8b4417 ;;
    nik:amd64) sum=5ab7e2c6a9cd75ad16d2387c24f7080a883fb3598dbf2c84ab94c1412613bf55 ;;
    nik:arm64) echo 'Install a Java 21 native-image distribution and set NIK_HOME.' >&2; exit 1 ;;
esac

case "$tool" in
    jdk) url="https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.13%2B9/OpenJDK21U-jdk_${jdk_arch}_linux_hotspot_21.0.13_9.tar.gz" ;;
    sam) url="https://github.com/aws/aws-sam-cli/releases/download/v$version/aws-sam-cli-linux-$sam_arch.zip" ;;
    terraform) url="https://releases.hashicorp.com/terraform/$version/terraform_${version}_linux_$tf_arch.zip" ;;
    nik)
        url='https://github.com/bell-sw/LibericaNIK/releases/download/23.1.13%2B1-21.0.13.0.3%2B6/bellsoft-liberica-vm-full-openjdk21.0.13.0.3%2B6-23.1.13%2B1-linux-amd64.tar.gz'
        ;;
esac
printf 'Downloading %s %s\n' "$tool" "$version" >&2
curl --fail --silent --show-error --location --retry 2 "$url" -o "$archive"
printf '%s  %s\n' "$sum" "$archive" | sha256sum --check --status

case "$tool" in
    sam)
        unzip -q "$archive" -d "$temp/sam"
        "$temp/sam/install" --install-dir "$tool_dir/sam-$version/install" --bin-dir "$tool_dir/sam-$version/bin" >&2
        ;;
    terraform)
        mkdir -p "$tool_dir/terraform-$version"
        unzip -oq "$archive" -d "$tool_dir/terraform-$version" terraform
        ;;
    jdk|nik)
        mkdir -p "$path"
        tar xzf "$archive" -C "$path" --strip-components=1
        ;;
esac
resolve
