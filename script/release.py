#!/usr/bin/env python3
"""Build local preview images or a signed, notarized Branchline release."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from bundle import ReleaseError, load_config, make_info, require_release_prerequisites


ROOT = Path(__file__).resolve().parent.parent
DIST = ROOT / "dist" / "release"


def run(command: list[str], *, capture: bool = False) -> str:
    try:
        result = subprocess.run(command, check=True, text=True, stdout=subprocess.PIPE if capture else None)
    except (OSError, subprocess.CalledProcessError) as error:
        raise ReleaseError(f"Command failed: {' '.join(command)}") from error
    return result.stdout.strip() if capture else ""


def verify_universal(binary: Path) -> None:
    run(["/usr/bin/lipo", "-verify_arch", "arm64", str(binary)])
    run(["/usr/bin/lipo", "-verify_arch", "x86_64", str(binary)])


def find_sparkle_framework() -> Path:
    candidates = list((ROOT / ".build").glob("artifacts/**/Sparkle.framework"))
    candidates += list((ROOT / ".build").glob("checkouts/**/Sparkle.framework"))
    for candidate in candidates:
        if (candidate / "Versions").exists():
            return candidate
    raise ReleaseError("Sparkle.framework was not found under .build; run swift package resolve first")


def find_sparkle_tool(name: str) -> Path:
    external = os.environ.get("BRANCHLINE_SPARKLE_TOOLS", "").strip()
    if external:
        candidate = Path(external) / name
        if candidate.is_file():
            return candidate
    candidates = list((ROOT / ".build").glob(f"artifacts/**/bin/{name}"))
    candidates += list((ROOT / ".build").glob(f"checkouts/**/bin/{name}"))
    for candidate in candidates:
        if candidate.is_file():
            return candidate
    raise ReleaseError(f"Sparkle tool {name} was not found under .build")


def write_background(path: Path, preview: bool) -> None:
    # A small native AppKit renderer keeps the DMG artwork deterministic and crisp.
    swift = r'''import AppKit
let args = CommandLine.arguments
let preview = args[2] == "preview"
let size = NSSize(width: 640, height: 400)
let image = NSImage(size: size)
image.lockFocus()
let rect = NSRect(origin: .zero, size: size)
NSColor(calibratedRed: 0.955, green: 0.925, blue: 0.99, alpha: 1).setFill()
rect.fill()
let title = preview ? "BRANCHLINE PREVIEW" : "BRANCHLINE"
let ink = NSColor(calibratedRed: 0.22, green: 0.12, blue: 0.31, alpha: 1)
let titleAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 20, weight: .semibold), .foregroundColor: ink]
(title as NSString).draw(at: NSPoint(x: 34, y: 343), withAttributes: titleAttrs)
let subAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: ink.withAlphaComponent(0.72)]
("Drag Branchline to Applications to install" as NSString).draw(at: NSPoint(x: 34, y: 318), withAttributes: subAttrs)
let line = NSBezierPath(); line.move(to: NSPoint(x: 34, y: 301)); line.line(to: NSPoint(x: 606, y: 301))
ink.withAlphaComponent(0.16).setStroke(); line.lineWidth = 1; line.stroke()
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 279, y: 195)); arrow.line(to: NSPoint(x: 361, y: 195))
arrow.move(to: NSPoint(x: 348, y: 208)); arrow.line(to: NSPoint(x: 361, y: 195)); arrow.line(to: NSPoint(x: 348, y: 182))
ink.withAlphaComponent(0.5).setStroke(); arrow.lineWidth = 3; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round; arrow.stroke()
image.unlockFocus()
guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { fatalError("Could not render background") }
try png.write(to: URL(fileURLWithPath: args[1]))
'''
    run(["/usr/bin/swift", "-e", swift, str(path), "preview" if preview else "release"])


def make_dmg(app: Path, destination: Path, volume: str, preview: bool) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix="branchline-dmg-"))
    raw_image = destination.with_name(destination.stem + ".rw.dmg")
    mounted = None
    try:
        run(["/usr/bin/ditto", str(app), str(staging / app.name)])
        (staging / "Applications").symlink_to("/Applications")
        background = staging / ".background"
        background.mkdir()
        write_background(background / "background.png", preview)
        run(["/usr/bin/hdiutil", "create", "-volname", volume, "-srcfolder", str(staging), "-ov", "-format", "UDRW", str(raw_image)])
        attach = run(["/usr/bin/hdiutil", "attach", str(raw_image), "-nobrowse", "-plist"], capture=True)
        attached = plistlib.loads(attach.encode())
        for entity in attached.get("system-entities", []):
            if entity.get("mount-point"):
                mounted = Path(entity["mount-point"])
                break
        if mounted is None:
            raise ReleaseError("hdiutil did not return a mounted volume")
        # Finder owns only this newly mounted disk image. Keep .DS_Store customization local.
        script = f'''tell application "Finder"
  tell disk "{volume}"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {{80, 80, 720, 480}}
    set icon size of icon view options of container window to 128
    set background picture of icon view options of container window to file ".background:background.png"
    set position of item "{app.name}" of container window to {{165, 205}}
    set position of item "Applications" of container window to {{475, 205}}
    update without registering applications
    close
  end tell
end tell'''
        run(["/usr/bin/osascript", "-e", script])
        run(["/usr/bin/hdiutil", "detach", str(mounted), "-quiet"])
        mounted = None
        run(["/usr/bin/hdiutil", "convert", str(raw_image), "-ov", "-format", "UDZO", "-o", str(destination)])
    finally:
        if mounted:
            subprocess.run(["/usr/bin/hdiutil", "detach", str(mounted), "-quiet"], check=False)
        shutil.rmtree(staging, ignore_errors=True)
        raw_image.unlink(missing_ok=True)


def verify_preview_dmg(dmg: Path, app_name: str) -> None:
    attach = run(["/usr/bin/hdiutil", "attach", str(dmg), "-nobrowse", "-plist"], capture=True)
    mounted = None
    try:
        attached = plistlib.loads(attach.encode())
        for entity in attached.get("system-entities", []):
            if entity.get("mount-point"):
                mounted = Path(entity["mount-point"])
                break
        if mounted is None:
            raise ReleaseError("Could not mount preview DMG for verification")
        app = mounted / f"{app_name}.app"
        applications = mounted / "Applications"
        if not app.is_dir() or not applications.is_symlink() or applications.resolve() != Path("/Applications"):
            raise ReleaseError("Preview DMG must contain the app and an /Applications symlink")
        with (app / "Contents" / "Info.plist").open("rb") as stream:
            info = plistlib.load(stream)
        if info.get("BranchlineUpdatesEnabled") is not False:
            raise ReleaseError("Preview app bundle must have updates disabled")
        executable = app / "Contents" / "MacOS" / app_name
        verify_universal(executable)
    finally:
        if mounted:
            run(["/usr/bin/hdiutil", "detach", str(mounted), "-quiet"])


def sign_app(app: Path, identity: str) -> None:
    framework = app / "Contents" / "Frameworks" / "Sparkle.framework"
    bundles = [p for p in framework.rglob("*") if p.is_dir() and p.suffix in (".app", ".xpc", ".framework")]
    for bundle in sorted(bundles, key=lambda path: len(path.parts), reverse=True):
        if bundle.suffix != ".framework":
            run(["/usr/bin/codesign", "--force", "--options", "runtime", "--timestamp", "--sign", identity, str(bundle)])
    autoupdate = framework / "Versions" / "B" / "Autoupdate"
    if autoupdate.is_file():
        run(["/usr/bin/codesign", "--force", "--options", "runtime", "--timestamp", "--sign", identity, str(autoupdate)])
    run(["/usr/bin/codesign", "--force", "--options", "runtime", "--timestamp", "--sign", identity, str(framework)])
    run(["/usr/bin/codesign", "--force", "--options", "runtime", "--timestamp", "--sign", identity, str(app)])
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app)])


def notarize(archive: Path, notary_profile: str) -> None:
    command = ["xcrun", "notarytool", "submit", str(archive), "--keychain-profile", notary_profile, "--wait"]
    keychain = os.environ.get("BRANCHLINE_NOTARY_KEYCHAIN", "").strip()
    if keychain:
        command.extend(["--keychain", keychain])
    run(command)


def sign_notarize_dmg(dmg: Path, identity: str, notary_profile: str) -> None:
    run(["/usr/bin/codesign", "--force", "--timestamp", "--sign", identity, str(dmg)])
    run(["/usr/bin/codesign", "--verify", "--verbose=2", str(dmg)])
    notarize(dmg, notary_profile)
    run(["xcrun", "stapler", "staple", str(dmg)])
    run(["xcrun", "stapler", "validate", str(dmg)])


def manifest(config: dict, dmg: Path, base_url: str) -> dict:
    hasher = hashlib.sha256()
    with dmg.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            hasher.update(chunk)
    digest = hasher.hexdigest()
    filename = dmg.name
    architecture = "universal"
    return {
        "version": config["version"],
        "build": config["build"],
        "filename": filename,
        "downloadURL": f"{base_url.rstrip('/')}/downloads/{filename}",
        "minimumMacOS": config["minimumMacOS"],
        "architecture": architecture,
        "sha256": digest,
        "sizeBytes": dmg.stat().st_size,
        "releaseNotesURL": f"{base_url.rstrip('/')}/releases/{config['appName']}-{config['version']}.md",
    }


def appcast_command(tool: Path, config: dict, output_dir: Path, feed: Path) -> list[str]:
    base_url = config["baseURL"].rstrip("/")
    return [
        str(tool), "--account", config["sparkleKeychainAccount"],
        "--download-url-prefix", f"{base_url}/downloads/",
        "--release-notes-url-prefix", f"{base_url}/releases/",
        "-o", str(feed), str(output_dir),
    ]


def stage_site_payload(site_source: Path, site_payload: Path, downloads: Path, manifest_path: Path, feed: Path, notes: Path) -> None:
    if site_source.exists():
        shutil.copytree(site_source, site_payload, dirs_exist_ok=True)
    downloads_destination = site_payload / "downloads"
    updates_destination = site_payload / "updates"
    releases_destination = site_payload / "releases"
    downloads_destination.mkdir(parents=True, exist_ok=True)
    updates_destination.mkdir(parents=True, exist_ok=True)
    releases_destination.mkdir(parents=True, exist_ok=True)
    for archive in downloads.iterdir():
        if archive.is_file() and (archive.suffix == ".dmg" or archive.suffix == ".delta"):
            shutil.copy2(archive, downloads_destination / archive.name)
    shutil.copy2(manifest_path, downloads_destination / "latest.json")
    shutil.copy2(feed, updates_destination / feed.name)
    shutil.copy2(notes, releases_destination / notes.name)


def build_binary(arch: str, build_root: Path) -> Path:
    command = ["swift", "build", "--configuration", "release", "--arch", arch, "--scratch-path", str(build_root), "--product", "Branchline"]
    run(command)
    binary_directory = run(command + ["--show-bin-path"], capture=True)
    return Path(binary_directory) / "Branchline"


def do_release(args: argparse.Namespace) -> None:
    config = load_config(args.config)
    mode = "preview" if args.preview else "release"
    if not args.preview:
        require_release_prerequisites(config, os.environ)
        if args.build_only:
            raise ReleaseError("--build-only is available only with --preview")
    app_root = ROOT / "dist" / mode
    app = app_root / f"{config['appName']}.app"
    output_dir = DIST / "preview" if args.preview else DIST / "downloads"
    filename = f"{config['appName']}-{config['version']}{'-preview' if args.preview else ''}.dmg"
    dmg = output_dir / filename
    if args.preview:
        arm = build_binary("arm64", ROOT / ".build" / "release-preview-arm64")
        intel = build_binary("x86_64", ROOT / ".build" / "release-preview-x86_64")
        universal = app_root / "Branchline-universal"
        universal.parent.mkdir(parents=True, exist_ok=True)
        run(["/usr/bin/lipo", "-create", str(arm), str(intel), "-output", str(universal)])
        verify_universal(universal)
        if args.build_only:
            print(f"Universal preview build ready: {universal}")
            return
        from bundle import create_bundle
        sparkle = find_sparkle_framework()
        verify_universal(sparkle / "Versions" / "B" / "Sparkle")
        create_bundle(universal, app, "development", args.config, sparkle)
        make_dmg(app, dmg, f"{config['appName']} Preview", True)
        verify_preview_dmg(dmg, config["appName"])
        print(f"Unsigned preview DMG: {dmg}")
        return

    signing = os.environ["BRANCHLINE_SIGNING_IDENTITY"]
    notary_profile = os.environ["BRANCHLINE_NOTARY_PROFILE"]
    arm = build_binary("arm64", ROOT / ".build" / "release-arm64")
    intel = build_binary("x86_64", ROOT / ".build" / "release-x86_64")
    universal = app_root / "Branchline-universal"
    universal.parent.mkdir(parents=True, exist_ok=True)
    run(["/usr/bin/lipo", "-create", str(arm), str(intel), "-output", str(universal)])
    verify_universal(universal)
    from bundle import create_bundle
    create_bundle(universal, app, "release", args.config, find_sparkle_framework())
    sign_app(app, signing)
    app_archive = app_root / f"{config['appName']}-{config['version']}.zip"
    run(["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(app_archive)])
    notarize(app_archive, notary_profile)
    run(["xcrun", "stapler", "staple", str(app)])
    run(["xcrun", "stapler", "validate", str(app)])
    make_dmg(app, dmg, config["appName"], False)
    sign_notarize_dmg(dmg, signing, notary_profile)
    run(["/usr/sbin/spctl", "--assess", "--type", "execute", "--verbose=2", str(app)])
    run(["/usr/sbin/spctl", "--assess", "--type", "open", "--context", "context:primary-signature", "--verbose=2", str(dmg)])
    sparkle_tool = find_sparkle_tool("generate_appcast")
    notes = output_dir / f"{config['appName']}-{config['version']}.md"
    shutil.copy2(ROOT / "release" / "notes" / f"{config['version']}.md", notes)
    feed = DIST / config["feedPath"].lstrip("/")
    feed.parent.mkdir(parents=True, exist_ok=True)
    run(appcast_command(sparkle_tool, config, output_dir, feed))
    manifest_path = DIST / "latest.json"
    manifest_path.write_text(json.dumps(manifest(config, dmg, config["baseURL"]), indent=2) + "\n")
    site = ROOT / "site"
    stage_site_payload(site, DIST / "site", output_dir, manifest_path, feed, notes)
    print(f"Public release validated: {dmg}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--preview", action="store_true", help="build unsigned local preview; never emit public metadata")
    parser.add_argument("--build-only", action="store_true", help="compile preview without packaging")
    parser.add_argument("--config", type=Path, default=ROOT / "release-config.json")
    args = parser.parse_args()
    try:
        do_release(args)
    except ReleaseError as error:
        print(f"release: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
