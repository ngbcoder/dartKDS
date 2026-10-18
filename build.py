#!/usr/bin/env python3
"""Build DartKDS release: Flutter web UI + Android APK.

Steps (unless skipped):
  1. flutter build web --no-web-resources-cdn   (local canvaskit, air-gapped safe)
  2. dart run scripts/bundle_webui.dart          (pack build/web -> assets/webui.bin)
  3. flutter build apk --release --split-per-abi (APK now bundles the web UI)

Usage:
  python build.py               # full release build
  python build.py --debug       # build a debug APK instead of release
  python build.py --skip-web    # skip recompiling web; bundle the existing build/web
  python build.py --web-only    # build + bundle the web UI, skip APK
  python build.py --apk-only    # build the APK only (web UI must already be bundled)
"""

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path


def _force_utf8_stdio():
    """Make this process able to print whatever the Flutter tools emit.

    The subprocesses are already decoded as UTF-8 (see `run`), but printing that
    text re-encodes it into this process's stdout, which Windows defaults to
    cp1252. Flutter marks success with a U+2713 CHECK MARK and failure with
    U+2717, neither of which cp1252 can represent, so the script used to die
    with a UnicodeEncodeError partway through echoing the build log — killing
    the run after the tool it was reporting on had already succeeded. This
    turned a successful `flutter build web` into a failed build.
    """
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, ValueError):
            # Python < 3.7, or a stream already detached. Fall back to the
            # legacy codec switch, which is enough to keep the build running.
            try:
                stream.detach()
            except Exception:
                pass

def get_jdk():
    candidates = [
        r"C:\Users\29bragann\Documents\Software\Prism\java\java-runtime-delta",
        r"C:\Users\29bragann\Documents\Software\android-studio-quail4-windows\android-studio\jbr",
        os.environ.get("JAVA_HOME", ""),
    ]
    for c in candidates:
        if c and os.path.exists(c) and os.path.exists(os.path.join(c, "bin", "javac.exe")):
            return c
    for c in candidates:
        if c and os.path.exists(c):
            return c
    return r"C:\Users\29bragann\Documents\Software\Prism\java\java-runtime-delta"

def get_sdk():
    """Locate an Android SDK that is actually usable.

    This used to be a hardcoded path belonging to a different machine
    (`C:\\Users\\29bragann\\...`), which silently sent ANDROID_HOME somewhere
    that does not exist here. Worse, `android/local.properties` — which Gradle
    prefers over the environment — pointed `sdk.dir` at a directory holding
    nothing but `platform-tools`, so the build demanded an NDK download and then
    failed on unaccepted SDK licenses. Neither path had `platforms/`,
    `build-tools/` or `ndk/`, so the APK could not be produced from either.

    Candidates are ordered so a complete, already-licensed SDK wins over a
    partial one. `platforms/` plus `build-tools/` is the cheapest reliable test
    for "can actually build an APK".
    """
    home = os.path.expanduser("~")
    candidates = [
        os.environ.get("ANDROID_SDK_ROOT", ""),
        os.environ.get("ANDROID_HOME", ""),
        os.path.join(os.environ.get("LOCALAPPDATA", ""), "Android", "Sdk"),
        os.path.join(home, "AppData", "Local", "Android", "Sdk"),
        os.path.join(home, "Library", "Android", "sdk"),
        os.path.join(home, "Android", "Sdk"),
    ]
    for c in candidates:
        if c and os.path.isdir(os.path.join(c, "platforms")) and os.path.isdir(
            os.path.join(c, "build-tools")
        ):
            return c
    for c in candidates:
        if c and os.path.isdir(c):
            return c
    return candidates[2] or "Android/Sdk"

JDK = get_jdk()
SDK_DIR = get_sdk()
os.environ["JAVA_HOME"] = JDK
os.environ["ANDROID_HOME"] = SDK_DIR
os.environ["ANDROID_SDK_ROOT"] = SDK_DIR
os.environ.pop("ANDROID_PREFS_ROOT", None)

ROOT = Path(__file__).resolve().parent


def run(cmd, cwd=None):
    print(f"\n==> {' '.join(cmd)}", flush=True)
    target_dir = cwd if cwd is not None else ROOT
    env = os.environ.copy()
    env["JAVA_HOME"] = JDK
    env["ANDROID_HOME"] = SDK_DIR
    env["ANDROID_SDK_ROOT"] = SDK_DIR
    env.pop("ANDROID_PREFS_ROOT", None)
    env["PATH"] = f"{JDK}\\bin;{env.get('PATH', '')}"
    full_cmd = ["cmd", "/c", f"set JAVA_HOME={JDK}&& set ANDROID_HOME={SDK_DIR}&& set ANDROID_SDK_ROOT={SDK_DIR}&& set ANDROID_PREFS_ROOT=&& set PATH={JDK}\\bin;%PATH%&& " + " ".join(cmd)]
    try:
        proc = subprocess.Popen(
            full_cmd,
            cwd=str(target_dir),
            env=env,
            bufsize=1,
            universal_newlines=True,
            encoding="utf-8",
            errors="replace",
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
    except OSError as e:
        print(f"ERROR: failed to launch {' '.join(cmd)}: {e}", file=sys.stderr)
        return 1
    if proc.stdout is not None:
        for line in proc.stdout:
            print(line, end="", flush=True)
    proc.wait()
    return proc.returncode


def tools_ok():
    missing = [tool for tool in ("flutter", "dart") if shutil.which(tool) is None]
    if missing:
        print(f"ERROR: not found on PATH: {', '.join(missing)}", file=sys.stderr)
        return False
    return True


def ensure_webui_placeholder():
    """The web build validates every pubspec asset, including the bundled web UI
    (assets/webui.bin) that only exists after bundling. Create an empty placeholder
    so an initial fresh build can compile; bundle_webui.dart overwrites it."""
    placeholder = ROOT / "assets" / "webui.bin"
    if not placeholder.exists():
        placeholder.touch()
        print("==> Created empty assets/webui.bin placeholder (bundled later)")


def fail(step):
    print(f"\nERROR: {step} failed.", file=sys.stderr)
    return 1


def cleanup_android_locks():
    lock_file = Path.home() / ".android" / "debug.keystore.lock"
    if lock_file.exists():
        try:
            lock_file.unlink()
            print("==> Cleaned up stale debug.keystore.lock")
        except Exception as e:
            print(f"Warning: Could not remove lock file: {e}")


def main():
    _force_utf8_stdio()
    cleanup_android_locks()
    ap = argparse.ArgumentParser(
        prog="build",
        description="Build DartKDS (Flutter web UI + Android APK).",
    )
    ap.add_argument(
        "--debug",
        action="store_true",
        help="build a debug APK instead of a release APK",
    )
    ap.add_argument(
        "--skip-web",
        action="store_true",
        help="skip recompiling the web UI; bundle the existing build/web into assets",
    )
    ap.add_argument(
        "--web-only",
        action="store_true",
        help="build + bundle the web UI only (no APK)",
    )
    ap.add_argument(
        "--apk-only",
        action="store_true",
        help="build the APK only (web UI must already be bundled into assets/webui.bin)",
    )
    args = ap.parse_args()

    if not tools_ok():
        return 1

    if not args.apk_only:
        webui_asset = ROOT / "assets" / "webui.bin"
        webui_asset.parent.mkdir(parents=True, exist_ok=True)
        if not webui_asset.exists():
            webui_asset.touch()

        if not args.skip_web:
            ensure_webui_placeholder()
            if run(["flutter", "build", "web", "--no-web-resources-cdn"]) != 0:
                return fail("Web UI build")
        if run(["dart", "run", "scripts/bundle_webui.dart"]) != 0:
            return fail("Web UI bundling")

    if args.web_only:
        print("\nWeb UI built and bundled. Done (--web-only).")
        return 0

    if args.debug:
        if run(["gradlew.bat", "assembleDebug"], cwd=ROOT / "android") != 0:
            return fail("APK build")
    else:
        if run(["flutter", "build", "apk", "--split-per-abi", "--release"]) != 0:
            if run(["gradlew.bat", "assembleRelease"], cwd=ROOT / "android") != 0:
                return fail("APK build")

    print("\nBuild complete.")
    return 0


if __name__ == "__main__":
    sys.exit(main())