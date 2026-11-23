#!/usr/bin/env python3
"""Create Branchline's SwiftPM macOS app bundle from the shared release config."""

from __future__ import annotations

import argparse
import base64
import binascii
import json
import plistlib
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from urllib.parse import urljoin


ROOT = Path(__file__).resolve().parent.parent
CONFIG_PATH = ROOT / "release-config.json"


class ReleaseError(Exception):
    pass


def load_config(path: Path = CONFIG_PATH) -> dict:
    try:
        config = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise ReleaseError(f"Cannot read release config {path}: {error}") from error
    required = ("appName", "bundleIdentifier", "version", "build", "minimumMacOS", "baseURL", "feedPath", "sparkleVersion", "sparklePublicKey", "sparkleKeychainAccount")
    missing = [key for key in required if key not in config]
    if missing:
        raise ReleaseError(f"release-config.json is missing: {', '.join(missing)}")
    if not isinstance(config["build"], int) or config["build"] < 1:
        raise ReleaseError("release-config.json build must be a positive integer")
    if not str(config["version"]).strip() or not str(config["bundleIdentifier"]).strip():
        raise ReleaseError("release-config.json version and bundleIdentifier must be non-empty")
    return config


def require_release_prerequisites(config: dict, environ: dict[str, str]) -> None:
    key = config["sparklePublicKey"].strip()
    try:
        decoded_key = base64.b64decode(key, validate=True)
    except (binascii.Error, ValueError):
        decoded_key = b""
    if len(decoded_key) != 32:
        raise ReleaseError("Public release is disabled: release-config.json must contain a 32-byte base64 Sparkle public key")
    absent = [name for name in ("BRANCHLINE_SIGNING_IDENTITY", "BRANCHLINE_NOTARY_PROFILE") if not environ.get(name, "").strip()]
    if absent:
        raise ReleaseError("Public release requires environment variable(s): " + ", ".join(absent))
    if not environ["BRANCHLINE_SIGNING_IDENTITY"].startswith("Developer ID Application:"):
        raise ReleaseError("Public release signing identity must be a Developer ID Application certificate")


def make_info(config: dict, mode: str) -> dict:
    if mode not in ("development", "release"):
        raise ReleaseError("bundle mode must be development or release")
    enabled = mode == "release"
    info = {
        "CFBundleExecutable": config["appName"],
        "CFBundleIdentifier": config["bundleIdentifier"] if enabled else config["bundleIdentifier"] + ".dev",
        "CFBundleName": config["appName"],
        "CFBundleDisplayName": config["appName"],
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": config["version"],
        "CFBundleVersion": str(config["build"]),
        "LSMinimumSystemVersion": config["minimumMacOS"],
        "NSPrincipalClass": "NSApplication",
        "NSHighResolutionCapable": True,
        "BranchlineUpdatesEnabled": enabled,
    }
    if enabled:
        try:
            decoded_key = base64.b64decode(config["sparklePublicKey"].strip(), validate=True)
        except (binascii.Error, ValueError):
            decoded_key = b""
        if len(decoded_key) != 32:
            raise ReleaseError("Release bundles require a 32-byte base64 Sparkle public key")
        info["SUFeedURL"] = urljoin(config["baseURL"].rstrip("/") + "/", config["feedPath"].lstrip("/"))
        info["SUPublicEDKey"] = config["sparklePublicKey"].strip()
    return info


def create_bundle(binary: Path, output: Path, mode: str, config_path: Path = CONFIG_PATH, sparkle_framework: Path | None = None) -> None:
    config = load_config(config_path)
    if not binary.is_file():
        raise ReleaseError(f"Build executable not found: {binary}")
    if output.exists():
        shutil.rmtree(output)
    contents = output / "Contents"
    macos = contents / "MacOS"
    resources = contents / "Resources"
    macos.mkdir(parents=True)
    resources.mkdir()
    for license_name in ("LICENSE", "SPARKLE-LICENSE.txt"):
        shutil.copy2(ROOT / license_name, resources / license_name)
    shutil.copy2(binary, macos / config["appName"])
    (macos / config["appName"]).chmod((macos / config["appName"]).stat().st_mode | 0o111)
    icon = ROOT / "Assets" / "Branchline.icns"
    if icon.exists():
        shutil.copy2(icon, resources / "Branchline.icns")
    info = make_info(config, mode)
    with tempfile.TemporaryDirectory(prefix="branchline-icon-") as directory:
        temporary = Path(directory)
        compiled = temporary / "compiled"
        compiled.mkdir()
        partial = temporary / "IconInfo.plist"
        subprocess.run([
            "xcrun", "actool", str(ROOT / "Assets" / "AppIcon.icon"), "--compile", str(compiled),
            "--platform", "macosx", "--minimum-deployment-target", config["minimumMacOS"],
            "--app-icon", "AppIcon", "--output-partial-info-plist", str(partial),
        ], check=True)
        shutil.copy2(compiled / "Assets.car", resources / "Assets.car")
        with partial.open("rb") as stream:
            info.update(plistlib.load(stream))
    info["CFBundleIconName"] = "AppIcon"
    if icon.exists():
        info["CFBundleIconFile"] = "Branchline.icns"
    with (contents / "Info.plist").open("wb") as stream:
        plistlib.dump(info, stream, sort_keys=True)
    if mode == "release" and (not sparkle_framework or not sparkle_framework.exists()):
        raise ReleaseError("Release bundle requires Sparkle.framework")
    if sparkle_framework:
        if not sparkle_framework.exists():
            raise ReleaseError(f"Sparkle.framework not found: {sparkle_framework}")
        frameworks = contents / "Frameworks"
        frameworks.mkdir()
        try:
            subprocess.run(["/usr/bin/ditto", str(sparkle_framework), str(frameworks / "Sparkle.framework")], check=True)
        except (OSError, subprocess.CalledProcessError) as error:
            raise ReleaseError(f"Could not embed Sparkle.framework: {error}") from error


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--mode", choices=("development", "release"), required=True)
    parser.add_argument("--config", type=Path, default=CONFIG_PATH)
    parser.add_argument("--sparkle-framework", type=Path)
    args = parser.parse_args()
    try:
        create_bundle(args.binary, args.output, args.mode, args.config, args.sparkle_framework)
    except ReleaseError as error:
        print(f"bundle: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
