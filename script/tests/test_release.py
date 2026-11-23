import json
import hashlib
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from bundle import ReleaseError, create_bundle, load_config, make_info, require_release_prerequisites
from release import appcast_command, build_binary, manifest, notarize, sign_app, sign_notarize_dmg, stage_site_payload


class ReleaseScriptTests(unittest.TestCase):
    def config(self):
        return {
            "appName": "Branchline",
            "bundleIdentifier": "xyz.braksa.apps.branchline",
            "version": "0.1.0",
            "build": 1,
            "minimumMacOS": "14.0",
            "baseURL": "https://branchline.braksa.xyz",
            "feedPath": "/updates/appcast.xml",
            "sparkleVersion": "2.10.1",
            "sparklePublicKey": "",
            "sparkleKeychainAccount": "xyz.braksa.branchline",
        }

    def test_reads_current_config_and_rejects_incomplete_config(self):
        self.assertEqual(load_config()["appName"], "Branchline")
        self.assertEqual(load_config()["bundleIdentifier"], "xyz.braksa.apps.branchline")
        with tempfile.TemporaryDirectory() as directory:
            config_path = Path(directory) / "release-config.json"
            config_path.write_text(json.dumps({"appName": "Branchline"}))
            with self.assertRaisesRegex(ReleaseError, "missing"):
                load_config(config_path)

    def test_preview_bundle_is_explicitly_updates_disabled(self):
        info = make_info(self.config(), "development")
        self.assertEqual(info["CFBundleIdentifier"], "xyz.braksa.apps.branchline.dev")
        self.assertIs(info["BranchlineUpdatesEnabled"], False)
        self.assertNotIn("SUFeedURL", info)
        self.assertNotIn("SUPublicEDKey", info)

    def test_bundle_includes_app_and_sparkle_licenses(self):
        import plistlib

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / "Branchline"
            binary.write_bytes(b"executable")
            for name in ("LICENSE", "SPARKLE-LICENSE.txt"):
                (root / name).write_text(name)
            config = root / "release-config.json"
            config.write_text(json.dumps(self.config()))

            def compile_icon(command, **kwargs):
                compiled = Path(command[command.index("--compile") + 1])
                (compiled / "Assets.car").write_bytes(b"icon assets")
                partial = Path(command[command.index("--output-partial-info-plist") + 1])
                partial.write_bytes(plistlib.dumps({}))

            app = root / "Branchline.app"
            with patch("bundle.ROOT", root), patch("bundle.subprocess.run", side_effect=compile_icon):
                create_bundle(binary, app, "development", config)
            for name in ("LICENSE", "SPARKLE-LICENSE.txt"):
                self.assertEqual((app / "Contents" / "Resources" / name).read_text(), name)

    def test_notarization_uses_optional_keychain_path(self):
        with patch.dict("release.os.environ", {"BRANCHLINE_NOTARY_KEYCHAIN": "/example/login.keychain-db"}), patch("release.run") as run:
            notarize(Path("Branchline.zip"), "Branchline")
        self.assertEqual(run.call_args.args[0][-2:], ["--keychain", "/example/login.keychain-db"])

    def test_release_binary_uses_swiftpm_reported_output_path(self):
        with patch("release.run", side_effect=["", "/build/arm64-apple-macosx/release"]) as run:
            binary = build_binary("arm64", Path("/build"))
        self.assertEqual(binary, Path("/build/arm64-apple-macosx/release/Branchline"))
        self.assertEqual(run.call_args_list[1].args[0], run.call_args_list[0].args[0] + ["--show-bin-path"])

    def test_release_requires_public_key_identity_and_notary_profile(self):
        config = self.config()
        with self.assertRaisesRegex(ReleaseError, "public key"):
            require_release_prerequisites(config, {})
        config["sparklePublicKey"] = "A" * 43 + "="
        with self.assertRaisesRegex(ReleaseError, "BRANCHLINE_SIGNING_IDENTITY"):
            require_release_prerequisites(config, {})
        with self.assertRaisesRegex(ReleaseError, "Developer ID Application"):
            require_release_prerequisites(config, {
                "BRANCHLINE_SIGNING_IDENTITY": "Apple Development: Example",
                "BRANCHLINE_NOTARY_PROFILE": "Branchline",
            })
        require_release_prerequisites(config, {
            "BRANCHLINE_SIGNING_IDENTITY": "Developer ID Application: Example",
            "BRANCHLINE_NOTARY_PROFILE": "Branchline",
        })

    def test_release_bundle_has_sparkle_feed_metadata(self):
        config = self.config()
        config["sparklePublicKey"] = "A" * 43 + "="
        info = make_info(config, "release")
        self.assertEqual(info["CFBundleIdentifier"], "xyz.braksa.apps.branchline")
        self.assertIs(info["BranchlineUpdatesEnabled"], True)
        self.assertEqual(info["SUFeedURL"], "https://branchline.braksa.xyz/updates/appcast.xml")
        self.assertEqual(info["SUPublicEDKey"], "A" * 43 + "=")

    def test_manifest_uses_absolute_versioned_download_url_and_hash(self):
        with tempfile.TemporaryDirectory() as directory:
            dmg = Path(directory) / "Branchline-0.1.0.dmg"
            dmg.write_bytes(b"final notarized dmg bytes")
            result = manifest(self.config(), dmg, "https://branchline.braksa.xyz/")
        self.assertEqual(result["downloadURL"], "https://branchline.braksa.xyz/downloads/Branchline-0.1.0.dmg")
        self.assertEqual(result["sha256"], hashlib.sha256(b"final notarized dmg bytes").hexdigest())
        self.assertEqual(result["architecture"], "universal")
        self.assertEqual(result["releaseNotesURL"], "https://branchline.braksa.xyz/releases/Branchline-0.1.0.md")
        self.assertEqual(result["sizeBytes"], len(b"final notarized dmg bytes"))

    def test_release_signs_standalone_autoupdate_before_framework_and_app(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / "Branchline.app"
            framework = app / "Contents" / "Frameworks" / "Sparkle.framework"
            autoupdate = framework / "Versions" / "B" / "Autoupdate"
            autoupdate.parent.mkdir(parents=True)
            autoupdate.touch()
            (framework / "Versions" / "B" / "Updater.app").mkdir()
            (framework / "Versions" / "B" / "XPCServices" / "Downloader.xpc").mkdir(parents=True)
            calls = []
            with patch("release.run", side_effect=lambda command, **_: calls.append(command)):
                sign_app(app, "Developer ID Application: Example")
        targets = [Path(command[-1]).name for command in calls if command[0].endswith("codesign")]
        self.assertLess(targets.index("Autoupdate"), targets.index("Sparkle.framework"))
        self.assertLess(targets.index("Sparkle.framework"), targets.index("Branchline.app"))

    def test_appcast_command_points_downloads_and_release_notes_at_public_paths(self):
        config = self.config()
        command = appcast_command(Path("generate_appcast"), config, Path("downloads"), Path("updates/appcast.xml"))
        self.assertIn("https://branchline.braksa.xyz/downloads/", command)
        self.assertIn("https://branchline.braksa.xyz/releases/", command)
        self.assertNotIn("--ed-key-file", command)

    def test_site_payload_copies_archives_feed_manifest_and_notes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            site_source = root / "site-source"
            site_source.mkdir()
            (site_source / "index.html").write_text("landing")
            source_downloads = root / "downloads"
            source_downloads.mkdir()
            current = source_downloads / "Branchline-0.1.0.dmg"
            old = source_downloads / "Branchline-0.0.9.dmg"
            delta = source_downloads / "Branchline-0.1.0_from_0.0.9.delta"
            for path in (current, old, delta):
                path.write_bytes(path.name.encode())
            manifest_path = root / "latest.json"
            feed = root / "appcast.xml"
            notes = source_downloads / "Branchline-0.1.0.md"
            manifest_path.write_text("manifest")
            feed.write_text("feed")
            notes.write_text("notes")
            payload = root / "payload"
            stage_site_payload(site_source, payload, source_downloads, manifest_path, feed, notes)
            self.assertEqual((payload / "index.html").read_text(), "landing")
            for name in (current.name, old.name, delta.name):
                self.assertEqual((payload / "downloads" / name).read_bytes(), name.encode())
            self.assertEqual((payload / "downloads" / "latest.json").read_text(), "manifest")
            self.assertEqual((payload / "updates" / "appcast.xml").read_text(), "feed")
            self.assertEqual((payload / "releases" / notes.name).read_text(), "notes")

    def test_dmg_is_signed_and_verified_before_notary_submission_and_stapled(self):
        calls = []
        with patch("release.run", side_effect=lambda command, **_: calls.append(command)):
            sign_notarize_dmg(Path("Branchline.dmg"), "Developer ID Application: Example", "Branchline")
        commands = [command[0:2] for command in calls]
        self.assertEqual(commands, [
            ["/usr/bin/codesign", "--force"],
            ["/usr/bin/codesign", "--verify"],
            ["xcrun", "notarytool"],
            ["xcrun", "stapler"],
            ["xcrun", "stapler"],
        ])


if __name__ == "__main__":
    unittest.main()
