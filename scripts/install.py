#!/usr/bin/env python3
"""Install the development build for the current user without changing lock policy."""
from pathlib import Path
import plistlib
import shutil
import subprocess
import uuid

ROOT = Path(__file__).resolve().parent.parent
HOME_DIR = Path.home()
BACKUPS = HOME_DIR / "Library/Application Support/Macarchy/Backups"


def install(source, destination, identifier):
    with (source / "Contents/Info.plist").open("rb") as stream:
        assert plistlib.load(stream)["CFBundleIdentifier"] == identifier
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(source)], check=True)
    if destination.exists():
        with (destination / "Contents/Info.plist").open("rb") as stream:
            if plistlib.load(stream).get("CFBundleIdentifier") != identifier:
                raise RuntimeError(f"Another app owns {destination}; it was not changed.")
    destination.parent.mkdir(parents=True, exist_ok=True)
    staging = destination.with_name("." + destination.name + "." + str(uuid.uuid4()))
    shutil.copytree(source, staging)
    backup = None
    try:
        if destination.exists():
            BACKUPS.mkdir(parents=True, exist_ok=True)
            backup = BACKUPS / (str(uuid.uuid4()) + "-" + destination.name)
            destination.rename(backup)
        try:
            staging.rename(destination)
        except Exception:
            if backup:
                try:
                    backup.rename(destination)
                except Exception as error:
                    raise RuntimeError(f"Restore failed. Your previous bundle is at {backup}: {error}")
            raise
    finally:
        if staging.exists():
            shutil.rmtree(staging)
    print(f"Installed {destination}")
    if backup:
        print(f"Previous version retained at {backup}")


def owns_bundle(path, identifier):
    try:
        with (path / "Contents/Info.plist").open("rb") as stream:
            return plistlib.load(stream).get("CFBundleIdentifier") == identifier
    except (OSError, plistlib.InvalidFileException):
        return False


if __name__ == "__main__":
    app = HOME_DIR / "Applications/Macoma.app"
    install(ROOT / "build/Macoma.app", app, "dev.theboring.macarchy")
    legacy_saver = HOME_DIR / "Library/Screen Savers/Macarchy.saver"
    saver = legacy_saver if owns_bundle(legacy_saver, "dev.theboring.macarchy.screensaver") else HOME_DIR / "Library/Screen Savers/Macoma.saver"
    install(ROOT / "build/Macoma.saver", saver, "dev.theboring.macarchy.screensaver")
    # Preserve the old app as a backup after both new bundles install successfully.
    legacy_app = HOME_DIR / "Applications/Macarchy.app"
    if owns_bundle(legacy_app, "dev.theboring.macarchy"):
        BACKUPS.mkdir(parents=True, exist_ok=True)
        backup = BACKUPS / (str(uuid.uuid4()) + "-Macarchy.app")
        legacy_app.rename(backup)
        print(f"Previous app name retained at {backup}")
    print("Open Macoma, then select it in System Settings → Screen Saver.")
