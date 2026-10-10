#!/usr/bin/env python3
"""Build a self-contained native app and ScreenSaverView bundle without package managers."""
from pathlib import Path
import argparse
import hashlib
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile

# Import build helpers without leaving bytecode in the source checkout.
sys.dont_write_bytecode = True
from check_dependencies import require_dependencies

ROOT = Path(__file__).resolve().parent.parent
BUILD = ROOT / "build"
VERSION = "0.3.0"
BUILD_NUMBER = "6"
SAVER_SOURCES = ROOT / "Sources/Modules/Screensavers"


def run(*args, **kwargs):
    print("+ " + " ".join(map(str, args)), flush=True)
    subprocess.run(list(map(str, args)), cwd=ROOT, check=True, **kwargs)


def plist(path, values):
    with path.open("wb") as stream:
        plistlib.dump(values, stream, sort_keys=True)


def resources(bundle, desktop=False):
    output = bundle / "Contents/Resources"
    output.mkdir(parents=True, exist_ok=True)
    for source in (ROOT / "Resources").iterdir():
        if source.is_file():
            shutil.copy2(source, output / source.name)
    if desktop:
        for name in ["Desktop", "Terminal"]:
            shutil.copytree(ROOT / "Resources" / name, output / name)
    shutil.copy2(SAVER_SOURCES / "Shared/OmacyShaders.metal", output)
    notices = output / "Licenses"
    notices.mkdir(exist_ok=True)
    for source, name in [("ThirdParty/Omacy/LICENSE", "Omacy-MIT.txt"),
                         ("ThirdParty/Omacy/Aerial-LICENSE", "Aerial-MIT.txt"),
                         ("vendor/ttfx/LICENSE", "ttfx-MIT.txt"),
                         ("vendor/ttfx/NOTICE", "ttfx-NOTICE.txt"),
                         ("NOTICE", "NOTICE.txt")]:
        shutil.copy2(ROOT / source, notices / name)
    if desktop:
        shutil.copy2(ROOT / "ThirdParty/Omarchy/LICENSE", notices / "Omarchy-MIT.txt")
        shutil.copy2(ROOT / "ThirdParty/Omarchy/SOURCE.json", notices / "Omarchy-SOURCE.json")


def build(skip_engine=False):
    require_dependencies(ROOT)
    BUILD.mkdir(exist_ok=True)
    run("xcrun", "swift", ROOT / "scripts/make-icon.swift", ROOT)
    run("iconutil", "-c", "icns", BUILD / "Macoma.iconset", "-o", ROOT / "Resources/Macoma.icns")
    if not skip_engine:
        env = dict(os.environ, CARGO_BUILD_JOBS="4", MACOSX_DEPLOYMENT_TARGET="15.0")
        run("cargo", "build", "--release", "--locked", "-p", "omacy-engine", env=env)
    library = ROOT / "target/release/libomacy_engine.a"
    if not library.exists():
        raise SystemExit("Build the Rust engine before using --skip-engine.")
    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    shared = sorted((SAVER_SOURCES / "Shared").glob("*.swift"))
    extension = sorted((SAVER_SOURCES / "Extension").glob("*.swift"))
    app_sources = sorted(source for source in (ROOT / "Sources").rglob("*.swift")
                         if source not in shared and source not in extension)
    flags = ["-swift-version", "5", "-parse-as-library", "-O", "-sdk", sdk,
             "-target", "arm64-apple-macosx15.0", "-module-cache-path", str(BUILD / "ModuleCache"),
             "-import-objc-header", str(ROOT / "crates/omacy-engine/include/omacy.h")]
    frameworks = ["AppKit", "SwiftUI", "Metal", "QuartzCore", "CoreText", "CoreGraphics", "ScreenSaver", "Security"]
    links = [str(library), "-lc++", "-liconv", "-lresolv"]
    for framework in frameworks:
        links += ["-framework", framework]
    fingerprint = hashlib.sha256()
    fingerprint_inputs = [source for folder in ["Sources", "Resources", "crates/omacy-engine"]
                          for source in (ROOT / folder).rglob("*")]
    fingerprint_inputs += [ROOT / name for name in ["Cargo.lock", "vendor/ttfx.PIN", "NOTICE"]]
    for source in sorted(fingerprint_inputs):
        if source.is_file():
            fingerprint.update(str(source.relative_to(ROOT)).encode() + b"\0" + source.read_bytes())
    fingerprint.update(hashlib.sha256(library.read_bytes()).digest())
    common_plist = {"CFBundleDevelopmentRegion": "en", "CFBundleInfoDictionaryVersion": "6.0",
                    "CFBundleShortVersionString": VERSION, "CFBundleVersion": BUILD_NUMBER,
                    "MacarchySourceFingerprint": fingerprint.hexdigest(),
                    "LSMinimumSystemVersion": "15.0", "NSHighResolutionCapable": True,
                    "NSHumanReadableCopyright": "Macoma contributors. Includes MIT-licensed Omacy, ttfx and TerminalTextEffects."}
    staging = Path(tempfile.mkdtemp(prefix="staging-", dir=BUILD))
    saver = staging / "Macoma.saver"
    (saver / "Contents/MacOS").mkdir(parents=True, exist_ok=True)
    resources(saver)
    plist(saver / "Contents/Info.plist", dict(common_plist,
        CFBundleIdentifier="dev.theboring.macarchy.screensaver", CFBundleName="Macoma",
        CFBundleDisplayName="Macoma", CFBundleExecutable="Macarchy", CFBundlePackageType="BNDL",
        NSPrincipalClass="MacarchySaverView", MacarchyCompanionBundleIdentifier="dev.theboring.macarchy"))
    run("xcrun", "swiftc", *flags, "-emit-library", "-module-name", "MacarchySaver",
        *shared, *extension, *links,
        "-o", saver / "Contents/MacOS/Macarchy")
    identity = os.environ.get("MACARCHY_SIGN_IDENTITY", "-")
    run("codesign", "--force", "--sign", identity, saver)

    app = staging / "Macoma.app"
    (app / "Contents/MacOS").mkdir(parents=True, exist_ok=True)
    resources(app, desktop=True)
    plist(app / "Contents/Info.plist", dict(common_plist,
        CFBundleIdentifier="dev.theboring.macarchy", CFBundleName="Macoma", CFBundleDisplayName="Macoma",
        CFBundleExecutable="Macarchy", CFBundlePackageType="APPL", NSPrincipalClass="NSApplication",
        CFBundleIconFile="Macoma.icns", NSAppTransportSecurity={"NSAllowsArbitraryLoads": False}))
    run("xcrun", "swiftc", *flags, "-emit-executable", "-module-name", "Macarchy",
        *shared, *app_sources, *links, "-framework", "ApplicationServices", "-framework", "Carbon",
        "-o", app / "Contents/MacOS/Macarchy")
    embedded = app / "Contents/Resources/Macoma.saver"
    if embedded.exists():
        shutil.rmtree(embedded)
    shutil.copytree(saver, embedded)
    run("codesign", "--force", "--sign", identity, app)
    run("codesign", "--verify", "--deep", "--strict", app)
    # Only complete, verified bundles replace the previous build. Fresh staging
    # prevents removed resources or old compiled shaders surviving a rebuild.
    for bundle in [saver, app]:
        destination = BUILD / bundle.name
        backup = BUILD / (bundle.name + ".previous")
        if backup.exists():
            shutil.rmtree(backup)
        if destination.exists():
            destination.rename(backup)
        try:
            bundle.rename(destination)
        except Exception:
            if backup.exists():
                backup.rename(destination)
            raise
    staging.rmdir()
    print(f"Built {BUILD / 'Macoma.app'}\nBuilt {BUILD / 'Macoma.saver'}\nSigning: {identity} (ad-hoc development build when '-').", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--skip-engine", action="store_true")
    build(**vars(parser.parse_args()))
