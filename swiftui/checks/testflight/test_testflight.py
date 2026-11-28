import base64
import copy
import json
import shutil
import subprocess
import sys
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "ci"))

import testflight


TEAM_ID = "d" * 24
CODEMAGIC_APP_ID = "c" * 24
CODEMAGIC_BUILD_ID = "e" * 24
ASC_APP_ID = "123456789"
ASC_GROUP_ID = "11111111-1111-4111-8111-111111111111"
ASC_BUILD_ID = "22222222-2222-4222-8222-222222222222"
BUNDLE_ID = "jp.example.swiftui.catalog"
SHA = "f" * 40
VERSION = "0.1.0"
BUILD_NUMBER = "2"
GROUP_BUILDS = f"/betaGroups/{ASC_GROUP_ID}/relationships/builds"
START_BUILD = f"/apps/{CODEMAGIC_APP_ID}/builds"
TEAM_BUILDS = f"/teams/{TEAM_ID}/builds"


class FakeAPI:
    def __init__(self, responses):
        self.responses = responses
        self.calls = []

    def request(self, method, path, query=None, body=None):
        self.calls.append((method, path, query, body))
        response = self.responses[(method, path)]
        if callable(response):
            return response()
        return copy.deepcopy(response)

    @property
    def posts(self):
        return [call for call in self.calls if call[0] == "POST"]


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.config = testflight.Config(TEAM_ID, CODEMAGIC_APP_ID, ASC_APP_ID, ASC_GROUP_ID, BUNDLE_ID)
        self.codemagic_app = {
            "id": CODEMAGIC_APP_ID,
            "archived": False,
            "settings_source": "file",
            "repository": {"url": "https://github.com/kmiharu/my-cookbook"},
        }
        self.codemagic_build = {
            "id": CODEMAGIC_BUILD_ID,
            "app_id": CODEMAGIC_APP_ID,
            "workflow": {"id": "swiftui-testflight"},
            "commit": {"hash": SHA},
            "status": "finished",
            "app_store_connect_status": "finished",
            "labels": [testflight.release_label(self.config, VERSION, BUILD_NUMBER)],
            "artifacts": [{"type": "ipa", "name": "SwiftUICatalog.ipa", "version_name": VERSION,
                           "version_code": BUILD_NUMBER}, {"name": "build-receipt.json"},
                          {"name": "SwiftUICatalog.xcarchive.zip"}],
        }
        self.apple_app = {"type": "apps", "id": ASC_APP_ID, "attributes": {"bundleId": BUNDLE_ID}}
        self.group = {
            "type": "betaGroups",
            "id": ASC_GROUP_ID,
            "attributes": {"isInternalGroup": True, "hasAccessToAllBuilds": False, "publicLinkEnabled": False},
        }
        self.apple_build = {
            "type": "builds",
            "id": ASC_BUILD_ID,
            "attributes": {
                "version": BUILD_NUMBER,
                "processingState": "VALID",
                "expired": False,
                "usesNonExemptEncryption": False,
            },
        }
        self.beta_detail = {
            "data": {
                "type": "buildBetaDetails",
                "id": "beta-detail",
                "attributes": {"internalBuildState": "READY_FOR_BETA_TESTING"},
            }
        }
        self.group_builds = {"data": []}
        self.cm = FakeAPI({
            ("GET", f"/teams/{TEAM_ID}/apps"): {"data": [self.codemagic_app], "current_page": 1, "total_pages": 1},
            ("GET", f"/builds/{CODEMAGIC_BUILD_ID}"): {"data": self.codemagic_build},
            ("GET", TEAM_BUILDS): {"data": []},
            ("POST", START_BUILD): {"data": {"id": CODEMAGIC_BUILD_ID}},
        })
        self.asc = FakeAPI({
            ("GET", f"/apps/{ASC_APP_ID}"): {"data": self.apple_app},
            ("GET", f"/apps/{ASC_APP_ID}/betaGroups"): {"data": [self.group]},
            ("GET", "/builds"): {"data": [self.apple_build]},
            ("GET", f"/builds/{ASC_BUILD_ID}/buildBetaDetail"): self.beta_detail,
            ("GET", GROUP_BUILDS): self.group_builds,
        })
        self.release = testflight.Release(self.config, self.cm, self.asc)

    def test_preflight_checks_both_accounts_and_manual_internal_group(self):
        self.release.preflight()
        self.assertEqual(self.cm.posts + self.asc.posts, [])
        self.assertTrue(any(call[1] == f"/apps/{ASC_APP_ID}/betaGroups" for call in self.asc.calls))

    def test_preflight_rejects_wrong_codemagic_repository(self):
        self.codemagic_app["repository"]["url"] = "https://github.com/example/other"
        with self.assertRaises(testflight.ReleaseError):
            self.release.preflight()
        self.assertEqual(self.cm.posts + self.asc.posts, [])

    def test_preflight_rejects_wrong_apple_bundle(self):
        self.apple_app["attributes"]["bundleId"] = "jp.example.other"
        with self.assertRaises(testflight.ReleaseError):
            self.release.preflight()
        self.assertEqual(self.cm.posts + self.asc.posts, [])

    def test_preflight_rejects_external_or_automatic_group(self):
        for field, value in (("isInternalGroup", False), ("hasAccessToAllBuilds", True), ("publicLinkEnabled", True)):
            with self.subTest(field=field):
                original = self.group["attributes"][field]
                self.group["attributes"][field] = value
                with self.assertRaises(testflight.ReleaseError):
                    self.release.preflight()
                self.group["attributes"][field] = original
        self.assertEqual(self.cm.posts + self.asc.posts, [])

    def test_preflight_rejects_automatic_distribution_to_a_different_group(self):
        groups = self.asc.responses[("GET", f"/apps/{ASC_APP_ID}/betaGroups")]["data"]
        groups.append({
            "type": "betaGroups",
            "id": "33333333-3333-4333-8333-333333333333",
            "attributes": {"isInternalGroup": True, "hasAccessToAllBuilds": True, "publicLinkEnabled": False},
        })
        with self.assertRaises(testflight.ReleaseError):
            self.release.preflight()
        self.assertEqual(self.cm.posts + self.asc.posts, [])

    def test_start_pins_the_tag_commit_and_release_identity(self):
        self.asc.responses[("GET", "/builds")] = {"data": []}
        ref = "refs/tags/swiftui/v0.1.0"
        with patch.object(testflight, "verify_ref") as verify:
            report = self.release.start(ref, SHA, VERSION, BUILD_NUMBER)
        verify.assert_called_once_with(ref, SHA)
        self.assertEqual(report["codemagicBuildID"], CODEMAGIC_BUILD_ID)
        self.assertEqual(self.cm.posts, [("POST", START_BUILD, None, {
            "workflow_id": "swiftui-testflight",
            "tag": "swiftui/v0.1.0",
            "labels": [testflight.release_label(self.config, VERSION, BUILD_NUMBER)],
            "environment": {"variables": {
                "CATALOG_EXPECTED_SHA": SHA,
                "CATALOG_BUNDLE_ID": BUNDLE_ID,
                "CATALOG_MARKETING_VERSION": VERSION,
                "CATALOG_BUILD_NUMBER": BUILD_NUMBER,
            }},
        })])

    def test_start_rejects_a_release_previously_seen_by_either_provider(self):
        ref = "refs/heads/release"
        with patch.object(testflight, "verify_ref"):
            with self.assertRaises(testflight.ReleaseError):
                self.release.start(ref, SHA, VERSION, BUILD_NUMBER)
            self.asc.responses[("GET", "/builds")] = {"data": []}
            self.cm.responses[("GET", TEAM_BUILDS)] = {"data": [{"id": CODEMAGIC_BUILD_ID}]}
            with self.assertRaises(testflight.ReleaseError):
                self.release.start(ref, SHA, VERSION, BUILD_NUMBER)
        self.assertEqual(self.cm.posts, [])

    def test_start_does_not_retry_when_codemagic_response_is_lost(self):
        self.asc.responses[("GET", "/builds")] = {"data": []}

        def lost_response():
            raise testflight.ReleaseError("POST response unavailable")

        self.cm.responses[("POST", START_BUILD)] = lost_response
        with patch.object(testflight, "verify_ref"):
            with self.assertRaisesRegex(testflight.ReleaseError, testflight.release_label(self.config, VERSION, BUILD_NUMBER)):
                self.release.start("refs/heads/release", SHA, VERSION, BUILD_NUMBER)
        self.assertEqual(len(self.cm.posts), 1)

    def test_status_rejects_wrong_revision_or_release_number(self):
        with self.assertRaises(testflight.ReleaseError):
            self.release.status(CODEMAGIC_BUILD_ID, "a" * 40, VERSION, BUILD_NUMBER)
        with self.assertRaises(testflight.ReleaseError):
            self.release.status(CODEMAGIC_BUILD_ID, SHA, VERSION, "3")
        self.assertEqual(self.asc.calls, [])

    def test_status_keeps_upload_failure_distinct_from_build_success(self):
        self.codemagic_build["app_store_connect_status"] = "failed"
        report = self.release.status(CODEMAGIC_BUILD_ID, SHA, VERSION, BUILD_NUMBER)
        self.assertEqual(report["stage"], "upload_failed")
        self.assertEqual(self.asc.calls, [])

    def test_status_confirms_upload_without_codemagic_apple_post_processing(self):
        self.codemagic_build["app_store_connect_status"] = None
        path = f"/builds/{CODEMAGIC_BUILD_ID}/actions"
        self.cm.responses[("GET", path)] = {"data": [{"type": "publishing", "status": "success"}]}
        self.asc.responses[("GET", "/builds")] = {"data": []}
        report = self.release.status(CODEMAGIC_BUILD_ID, SHA, VERSION, BUILD_NUMBER)
        self.assertEqual(report["stage"], "apple_processing")
        self.assertNotIn("uploadConfirmed", report)
        self.asc.responses[("GET", "/builds")] = {"data": [self.apple_build]}
        report = self.release.status(CODEMAGIC_BUILD_ID, SHA, VERSION, BUILD_NUMBER)
        self.assertEqual(report["stage"], "ready_to_distribute")
        self.assertTrue(report["uploadConfirmed"])

    def test_status_omits_short_lived_artifact_urls_and_checks_target_group(self):
        self.codemagic_build["artifacts"][0]["short_lived_download_url"] = "https://example.com/?token=fixture-secret"
        self.beta_detail["data"]["attributes"]["internalBuildState"] = "IN_BETA_TESTING"
        report = self.release.status(CODEMAGIC_BUILD_ID, SHA, VERSION, BUILD_NUMBER)
        self.assertNotIn("fixture-secret", json.dumps(report))
        self.assertEqual(report["stage"], "ready_to_distribute")
        self.group_builds["data"].append({"type": "builds", "id": ASC_BUILD_ID})
        report = self.release.status(CODEMAGIC_BUILD_ID, SHA, VERSION, BUILD_NUMBER)
        self.assertEqual(report["stage"], "available_for_internal_testing")

    def test_distribution_stops_when_compliance_is_missing(self):
        self.beta_detail["data"]["attributes"]["internalBuildState"] = "MISSING_EXPORT_COMPLIANCE"
        with self.assertRaises(testflight.ReleaseError):
            self.release.distribute(CODEMAGIC_BUILD_ID, SHA, VERSION, BUILD_NUMBER)
        self.assertEqual(self.asc.posts, [])

    def test_distribution_stops_before_apple_processing_finishes(self):
        self.apple_build["attributes"]["processingState"] = "PROCESSING"
        with self.assertRaises(testflight.ReleaseError):
            self.release.distribute(CODEMAGIC_BUILD_ID, SHA, VERSION, BUILD_NUMBER)
        self.assertEqual(self.asc.posts, [])

    def test_distribution_adds_only_the_matching_build_once(self):
        def add_build():
            self.group_builds["data"].append({"type": "builds", "id": ASC_BUILD_ID})

        self.asc.responses[("POST", GROUP_BUILDS)] = add_build
        self.release.distribute(CODEMAGIC_BUILD_ID, SHA, VERSION, BUILD_NUMBER)
        self.release.distribute(CODEMAGIC_BUILD_ID, SHA, VERSION, BUILD_NUMBER)
        self.assertEqual(len(self.asc.posts), 1)
        self.assertEqual(self.asc.posts[0][1], GROUP_BUILDS)
        self.assertEqual(self.asc.posts[0][3], {"data": [{"type": "builds", "id": ASC_BUILD_ID}]})

    def test_distribution_reconciles_a_lost_response_without_resending(self):
        def add_then_lose_response():
            self.group_builds["data"].append({"type": "builds", "id": ASC_BUILD_ID})
            raise testflight.ReleaseError("POST response unavailable")

        self.asc.responses[("POST", GROUP_BUILDS)] = add_then_lose_response
        report = self.release.distribute(CODEMAGIC_BUILD_ID, SHA, VERSION, BUILD_NUMBER)
        self.assertEqual(report["stage"], "group_assigned")
        self.assertEqual(len(self.asc.posts), 1)


@unittest.skipUnless(shutil.which("openssl"), "OpenSSL is needed for App Store Connect authentication")
class AppleAuthenticationTests(unittest.TestCase):
    def test_signs_a_short_lived_es256_token_with_refresh(self):
        def decode(value):
            return base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))

        def der_integer(value):
            value = value.lstrip(b"\0") or b"\0"
            if value[0] & 128:
                value = b"\0" + value
            return b"\x02" + bytes([len(value)]) + value

        with TemporaryDirectory() as directory:
            key = Path(directory) / "key.p8"
            public = Path(directory) / "public.pem"
            signature = Path(directory) / "signature.der"
            subprocess.run([
                "openssl", "genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-out", key,
            ], check=True, capture_output=True)
            subprocess.run(["openssl", "pkey", "-in", key, "-pubout", "-out", public], check=True, capture_output=True)
            authentication = testflight.AppleAuthentication("KEY", "ISSUER", str(key))
            with patch.object(testflight.time, "time", return_value=1_000):
                bearer = authentication()["Authorization"]
                self.assertEqual(authentication()["Authorization"], bearer)
            self.assertTrue(bearer.startswith("Bearer "))
            header, claims, signed = bearer.removeprefix("Bearer ").split(".")
            self.assertEqual(json.loads(decode(header))["alg"], "ES256")
            self.assertEqual(json.loads(decode(claims)), {
                "iss": "ISSUER", "iat": 1_000, "exp": 1_600, "aud": "appstoreconnect-v1",
            })
            raw = decode(signed)
            self.assertEqual(len(raw), 64)
            pair = der_integer(raw[:32]) + der_integer(raw[32:])
            signature.write_bytes(b"\x30" + bytes([len(pair)]) + pair)
            subprocess.run(["openssl", "dgst", "-sha256", "-verify", public, "-signature", signature],
                           input=f"{header}.{claims}".encode(), check=True, capture_output=True)
            with patch.object(testflight.time, "time", return_value=1_541):
                refreshed = authentication()["Authorization"]
            self.assertNotEqual(refreshed, bearer)


if __name__ == "__main__":
    unittest.main()
