#!/usr/bin/env python3
"""Start, inspect, and distribute the cookbook's internal TestFlight builds."""

import argparse
import base64
import hashlib
import json
import os
import re
import subprocess
import sys
import time
from dataclasses import dataclass
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

REPOSITORY = "https://github.com/kmiharu/my-cookbook"
WORKFLOW = "swiftui-testflight"
CM_ORIGIN = "https://codemagic.io"
ASC_ORIGIN = "https://api.appstoreconnect.apple.com"
MAX_RESPONSE = 4 * 1024 * 1024


class ReleaseError(Exception):
    pass


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


class API:
    def __init__(self, name, origin, prefix, authentication):
        self.name = name
        self.origin = origin
        self.prefix = prefix
        self.authentication = authentication
        self.opener = build_opener(NoRedirect())

    def request(self, method, path, query=None, body=None):
        url = self.origin + self.prefix + path if path.startswith("/") else path
        if not url.startswith(self.origin + self.prefix + "/"):
            raise ReleaseError(f"{self.name} returned a pagination link outside its API.")
        if query:
            url += "?" + urlencode(query)
        headers = {"Accept": "application/json", **self.authentication()}
        data = None
        if body is not None:
            data = json.dumps(body).encode()
            headers["Content-Type"] = "application/json"
        try:
            with self.opener.open(Request(url, data, headers, method=method), timeout=25) as response:
                if response.status == 204:
                    return None
                raw = response.read(MAX_RESPONSE + 1)
        except HTTPError as error:
            raise ReleaseError(f"{self.name} {method} failed (HTTP {error.code}).") from None
        except (URLError, OSError, ValueError):
            raise ReleaseError(f"{self.name} {method} could not complete.") from None
        if len(raw) > MAX_RESPONSE:
            raise ReleaseError(f"{self.name} response exceeded the size limit.")
        try:
            value = json.loads(raw)
        except (UnicodeError, ValueError):
            raise ReleaseError(f"{self.name} returned invalid JSON.") from None
        if not isinstance(value, dict):
            raise ReleaseError(f"{self.name} returned an unexpected response.")
        return value


def base64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=")


def raw_signature(der):
    """Convert an OpenSSL P-256 DER signature to the ES256 JWT format."""
    if len(der) < 8 or der[0] != 0x30 or der[1] != len(der) - 2:
        raise ReleaseError("The App Store Connect key must be an ES256 (P-256) key.")
    parts = []
    position = 2
    for _ in range(2):
        if position + 2 > len(der) or der[position] != 0x02:
            raise ReleaseError("OpenSSL returned an invalid ES256 signature.")
        size = der[position + 1]
        start = position + 2
        position = start + size
        if not 1 <= size <= 33 or position > len(der) or der[start] & 0x80:
            raise ReleaseError("OpenSSL returned an invalid ES256 signature.")
        number = der[start:position].lstrip(b"\0")
        if len(number) > 32:
            raise ReleaseError("The App Store Connect key must be an ES256 (P-256) key.")
        parts.append(number.rjust(32, b"\0"))
    if position != len(der):
        raise ReleaseError("OpenSSL returned an invalid ES256 signature.")
    return b"".join(parts)


class AppleAuthentication:
    def __init__(self, key_id, issuer_id, key_path):
        self.key_id = key_id
        self.issuer_id = issuer_id
        self.key_path = key_path
        self.token = None
        self.expires = 0

    def __call__(self):
        now = int(time.time())
        if now >= self.expires - 60:
            expires = now + 600
            header = {"alg": "ES256", "kid": self.key_id, "typ": "JWT"}
            claims = {"iss": self.issuer_id, "iat": now, "exp": expires, "aud": "appstoreconnect-v1"}
            signed = b".".join(base64url(json.dumps(part).encode()) for part in (header, claims))
            try:
                signature = subprocess.run(
                    ["openssl", "dgst", "-sha256", "-sign", self.key_path],
                    input=signed, capture_output=True, check=True, timeout=10,
                ).stdout
            except (OSError, subprocess.SubprocessError):
                raise ReleaseError("Could not sign the App Store Connect token with OpenSSL and ASC_KEY_PATH.") from None
            self.token = b".".join((signed, base64url(raw_signature(signature)))).decode("ascii")
            self.expires = expires
        return {"Authorization": "Bearer " + self.token}


@dataclass(frozen=True)
class Config:
    team_id: str
    codemagic_app_id: str
    app_id: str
    group_id: str
    bundle_id: str


def release_label(config, version, build_number):
    release = f"{config.bundle_id}:{version}:{build_number}"
    return "cookbook-testflight-" + hashlib.sha256(release.encode()).hexdigest()[:24]


def verify_ref(ref, sha):
    if not ref.startswith(("refs/heads/", "refs/tags/")):
        raise ReleaseError("Use a full GitHub branch or tag ref.")
    try:
        subprocess.run(["git", "check-ref-format", ref], check=True, capture_output=True, timeout=10)
        data = subprocess.run(
            ["git", "ls-remote", "--exit-code", REPOSITORY + ".git", ref, ref + "^{}"],
            capture_output=True, text=True, check=True, timeout=25,
        ).stdout
    except (OSError, subprocess.SubprocessError):
        raise ReleaseError("Could not resolve the requested ref on GitHub.") from None
    commits = {name: value for value, name in (line.split("\t", 1) for line in data.splitlines())}
    if commits.get(ref + "^{}", commits.get(ref)) != sha:
        raise ReleaseError("The GitHub ref does not resolve to the requested commit SHA.")


class Release:
    def __init__(self, config, cm, asc):
        self.config = config
        self.cm = cm
        self.asc = asc

    def _apple_pages(self, path):
        seen = set()
        while path:
            if path in seen:
                raise ReleaseError("App Store Connect repeated a pagination link.")
            seen.add(path)
            response = self.asc.request("GET", path)
            yield from response["data"]
            path = (response.get("links") or {}).get("next")

    def preflight(self):
        config = self.config
        page = 1
        while True:
            response = self.cm.request("GET", f"/teams/{config.team_id}/apps", {"page": page})
            project = next((app for app in response["data"] if app["id"] == config.codemagic_app_id), None)
            if project is not None or page >= response["total_pages"]:
                break
            page += 1
        if project is None or project["archived"] is not False or project["settings_source"] != "file":
            raise ReleaseError("The configured Codemagic app must be active and use repository YAML.")
        repository_url = project["repository"]["url"].rstrip("/").removesuffix(".git")
        if repository_url.casefold() != REPOSITORY.casefold():
            raise ReleaseError("The configured Codemagic app points to a different repository.")

        app = self.asc.request("GET", f"/apps/{config.app_id}")["data"]
        if app["id"] != config.app_id or app["type"] != "apps" or app["attributes"]["bundleId"] != config.bundle_id:
            raise ReleaseError("The App Store Connect app does not match the configured bundle ID.")
        groups = list(self._apple_pages(f"/apps/{config.app_id}/betaGroups"))
        group = next((item["attributes"] for item in groups if item["id"] == config.group_id), None)
        if (group is None or group.get("isInternalGroup") is not True
                or group.get("hasAccessToAllBuilds") is not False or group.get("publicLinkEnabled") is True):
            raise ReleaseError("Select a manual internal TestFlight group belonging to this app.")
        if any(item["attributes"].get("hasAccessToAllBuilds") is True for item in groups):
            raise ReleaseError("An automatic TestFlight group could receive this upload. Review the app's groups first.")

    def _apple_build(self, version, build_number):
        data = self.asc.request("GET", "/builds", {
            "filter[app]": self.config.app_id,
            "filter[version]": build_number,
            "filter[preReleaseVersion.version]": version,
            "filter[preReleaseVersion.platform]": "IOS",
        })["data"]
        if len(data) > 1 or (data and (
            data[0]["type"] != "builds" or not ID_PATTERN.fullmatch(data[0]["id"])
            or data[0]["attributes"]["version"] != build_number
        )):
            raise ReleaseError("App Store Connect returned an ambiguous build match.")
        return data[0] if data else None

    def start(self, ref, sha, version, build_number):
        verify_ref(ref, sha)
        if self._apple_build(version, build_number):
            raise ReleaseError("That iOS version and build number already exist in App Store Connect.")
        config = self.config
        label = release_label(config, version, build_number)
        previous = self.cm.request("GET", f"/teams/{config.team_id}/builds", {
            "app_id": config.codemagic_app_id, "workflow_id": WORKFLOW, "label": label,
        })["data"]
        if previous:
            ids = [item["id"] for item in previous if ID_PATTERN.fullmatch(item["id"])]
            raise ReleaseError("That release already has Codemagic build(s): " + ", ".join(ids) + ". Use status.")
        field = "branch" if ref.startswith("refs/heads/") else "tag"
        variables = {
            "CATALOG_EXPECTED_SHA": sha, "CATALOG_BUNDLE_ID": config.bundle_id,
            "CATALOG_MARKETING_VERSION": version, "CATALOG_BUILD_NUMBER": build_number,
        }
        try:
            result = self.cm.request("POST", f"/apps/{config.codemagic_app_id}/builds", body={
                "workflow_id": WORKFLOW, field: ref.split("/", 2)[2], "labels": [label],
                "environment": {"variables": variables},
            })
            build_id = result["data"]["id"]
            if not ID_PATTERN.fullmatch(build_id):
                raise ReleaseError("Codemagic returned an invalid build ID.")
        except (ReleaseError, KeyError, TypeError, ValueError) as error:
            raise ReleaseError(
                f"Build start was not confirmed. Check Codemagic for label {label} before trying again."
            ) from error
        return {"stage": "build_queued", "codemagicBuildID": build_id, "releaseLabel": label}

    def _group_builds(self):
        return self._apple_pages(f"/betaGroups/{self.config.group_id}/relationships/builds")

    def status(self, codemagic_build_id, sha, version, build_number):
        build = self.cm.request("GET", f"/builds/{codemagic_build_id}")["data"]
        config = self.config
        if (build["id"] != codemagic_build_id or build["app_id"] != config.codemagic_app_id
                or build["workflow"]["id"] != WORKFLOW
                or release_label(config, version, build_number) not in build["labels"]):
            raise ReleaseError("Codemagic build does not match the configured app, workflow, or release.")
        commit = (build.get("commit") or {}).get("hash")
        if commit is not None and commit != sha:
            raise ReleaseError("Codemagic built a different commit.")
        state = build["status"]
        upload = build.get("app_store_connect_status")
        result = {
            "stage": "build_pending", "codemagicBuildID": codemagic_build_id,
            "codemagicState": state, "uploadState": upload,
        }
        if state in {"failed", "canceled", "timeout", "skipped"} or upload in {"failed", "timeout"}:
            result["stage"] = "upload_failed" if upload in {"failed", "timeout"} else "build_failed"
            return result
        if state != "finished":
            return result
        if commit != sha:
            raise ReleaseError("Codemagic finished without reporting the requested commit.")
        artifacts = build["artifacts"]
        names = {item["name"] for item in artifacts}
        ipas = [item for item in artifacts if item["name"].endswith(".ipa")]
        if (len(ipas) != 1 or not {"build-receipt.json", "SwiftUICatalog.xcarchive.zip"} <= names
                or ipas[0].get("version_name") not in (None, version)
                or ipas[0].get("version_code") not in (None, build_number)):
            raise ReleaseError("Codemagic did not report the expected archive, receipt, and IPA.")
        result["artifacts"] = sorted(names)
        if upload != "finished":
            # This field can be null for an upload without Codemagic's TestFlight post-processing.
            actions = self.cm.request("GET", f"/builds/{codemagic_build_id}/actions",
                                      {"page_size": 100, "page": 1})["data"]
            publishing = [step["status"] for step in actions if step["type"] == "publishing"]
            if not publishing or any(step != "success" for step in publishing):
                result["stage"] = "upload_failed" if {"failed", "canceled"}.intersection(publishing) else "upload_pending"
                return result

        apple_build = self._apple_build(version, build_number)
        result["stage"] = "apple_processing"
        if apple_build is None:
            return result
        result["uploadConfirmed"] = True
        apple_id = apple_build["id"]
        attributes = apple_build["attributes"]
        processing = attributes["processingState"]
        result.update(appleBuildID=apple_id, appleProcessingState=processing)
        if processing != "VALID" or attributes.get("expired") is not False:
            if processing in {"FAILED", "INVALID"} or attributes.get("expired") is True:
                result["stage"] = "apple_processing_failed"
            return result
        detail = self.asc.request("GET", f"/builds/{apple_id}/buildBetaDetail")["data"]
        beta_state = detail["attributes"]["internalBuildState"]
        result["internalBetaState"] = beta_state
        if beta_state not in {"READY_FOR_BETA_TESTING", "IN_BETA_TESTING"}:
            result["stage"] = "apple_processing" if beta_state == "PROCESSING" else "apple_blocked"
            return result
        assigned = any(item["id"] == apple_id for item in self._group_builds())
        result.update(groupAssigned=assigned, groupID=config.group_id)
        if assigned:
            result["stage"] = "available_for_internal_testing" if beta_state == "IN_BETA_TESTING" else "group_assigned"
        else:
            result["stage"] = "ready_to_distribute"
        return result

    def distribute(self, codemagic_build_id, sha, version, build_number):
        result = self.status(codemagic_build_id, sha, version, build_number)
        if result["stage"] in {"group_assigned", "available_for_internal_testing"}:
            return result
        if result["stage"] != "ready_to_distribute":
            raise ReleaseError(f"Build is not ready for internal testing ({result['stage']}). Use status.")
        apple_id = result["appleBuildID"]
        post_error = None
        try:
            self.asc.request(
                "POST", f"/betaGroups/{self.config.group_id}/relationships/builds",
                body={"data": [{"type": "builds", "id": apple_id}]},
            )
        except ReleaseError as error:
            # A transport failure may occur after Apple committed the relationship.
            post_error = error
        result = self.status(codemagic_build_id, sha, version, build_number)
        if not result.get("groupAssigned"):
            message = "Group assignment was not confirmed. Check status before trying distribute again."
            if post_error:
                message = f"{post_error} {message}"
            raise ReleaseError(message)
        return result


ID_PATTERN = re.compile(r"[A-Za-z0-9-]{1,120}")
PENDING = {"build_pending", "upload_pending", "apple_processing", "group_assigned"}
BLOCKED = {"build_failed", "upload_failed", "apple_processing_failed", "apple_blocked"}


def required_env(name, pattern=None):
    value = os.environ.get(name, "")
    if not value or (pattern is not None and not re.fullmatch(pattern, value)):
        raise ReleaseError(f"Set a valid {name} in the release environment.")
    return value


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("start", "status", "distribute"):
        command = commands.add_parser(name)
        command.add_argument("--sha", required=True)
        command.add_argument("--version", required=True)
        command.add_argument("--build-number", required=True)
        if name == "start":
            command.add_argument("--ref", required=True)
        else:
            command.add_argument("--codemagic-build-id", required=True)
        if name == "status":
            command.add_argument("--wait", type=int, default=0, metavar="SECONDS")
    args = parser.parse_args(argv)
    options = (args.sha, args.version, args.build_number)
    if not all(re.fullmatch(pattern, value) for pattern, value in zip(
        (r"[0-9a-f]{40}", r"[0-9]+\.[0-9]+\.[0-9]+", r"[1-9][0-9]*"), options
    )):
        parser.error("use a full lowercase Git SHA, a version like 0.1.0, and a positive integer build number")
    if args.command != "start" and not ID_PATTERN.fullmatch(args.codemagic_build_id):
        parser.error("invalid Codemagic build ID")
    wait = getattr(args, "wait", 0)
    if not 0 <= wait <= 3600:
        parser.error("--wait must be between 0 and 3600 seconds")

    try:
        config = Config(
            *(required_env(name, ID_PATTERN) for name in (
                "CODEMAGIC_TEAM_ID", "CODEMAGIC_APP_ID", "ASC_APP_ID", "ASC_BETA_GROUP_ID"
            )),
            required_env("CATALOG_BUNDLE_ID", r"(?!com\.example\.)([A-Za-z0-9-]+\.)+[A-Za-z0-9-]+"),
        )
        cm_token = required_env("CODEMAGIC_API_TOKEN", r"[^\s]+")
        authentication = AppleAuthentication(
            required_env("ASC_KEY_ID", ID_PATTERN), required_env("ASC_ISSUER_ID", ID_PATTERN),
            required_env("ASC_KEY_PATH"),
        )
        release = Release(
            config, API("Codemagic", CM_ORIGIN, "/api/v3", lambda: {"x-auth-token": cm_token}),
            API("App Store Connect", ASC_ORIGIN, "/v1", authentication),
        )
        release.preflight()
        if args.command == "start":
            result = release.start(args.ref, *options)
        elif args.command == "distribute":
            result = release.distribute(args.codemagic_build_id, *options)
        else:
            until = time.monotonic() + wait
            result = release.status(args.codemagic_build_id, *options)
            while wait and result["stage"] in PENDING and time.monotonic() < until:
                print(f"Waiting: {result['stage']}", file=sys.stderr)
                time.sleep(min(30, max(0, until - time.monotonic())))
                result = release.status(args.codemagic_build_id, *options)
        print(json.dumps({"gitCommit": args.sha, "bundleID": config.bundle_id,
                          "marketingVersion": args.version, "buildNumber": args.build_number, **result}))
        if wait and result["stage"] in PENDING:
            return 3
        return 1 if result["stage"] in BLOCKED else 0
    except ReleaseError as error:
        print(error, file=sys.stderr)
    except (KeyError, TypeError, ValueError):
        print("A release service returned an unexpected response.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
