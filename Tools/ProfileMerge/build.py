#!/usr/bin/env python3
"""Reproducibly build the optional static offline merger; all LLVM work stays in an explicit cache."""
import argparse
import hashlib
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tarfile
import urllib.request

VERSION = "20.1.8"
HASHES = {
    "llvm": "e1363888216b455184dbb8a74a347bf5612f56a3f982369e1cba6c7e0726cde1",
    "cmake": "3319203cfd1172bbac50f06fa68e318af84dcb5d65353310c0586354069d6634",
}
TARGETS = {"host": ("macosx", "arm64"), "ios": ("iphoneos", "arm64"),
           "sim": ("iphonesimulator", "arm64"), "mac-x86": ("macosx", "x86_64"),
           "sim-x86": ("iphonesimulator", "x86_64")}


def run(args, env, **kwargs):
    """Execute argv-only build tools with a fixed developer directory and fail on errors."""
    return subprocess.run([str(x) for x in args], env=env, check=True, **kwargs)


def prepare_source(cache):
    """Verify pinned official archives before extraction, never reusing unverified downloaded content."""
    for component, expected in HASHES.items():
        archive = cache / (component + ".tar.xz")
        if not archive.exists():
            url = f"https://github.com/llvm/llvm-project/releases/download/llvmorg-{VERSION}/{component}-{VERSION}.src.tar.xz"
            urllib.request.urlretrieve(url, archive)
        if hashlib.sha256(archive.read_bytes()).hexdigest() != expected:
            raise RuntimeError("LLVM source checksum mismatch: " + component)
        destination = cache / (f"llvm-{VERSION}.src" if component == "llvm" else "cmake")
        if not destination.exists():
            with tarfile.open(archive) as source:
                # The archives are authenticated by their exact hashes above.
                source.extractall(cache)
            if component == "cmake":
                (cache / f"cmake-{VERSION}.src").rename(destination)
    return cache / f"llvm-{VERSION}.src"


def build(cache, source, name, env, jobs, tool_root):
    """Build only the profile library dependency closure, then package its C bridge as a static archive."""
    sdk, architecture = TARGETS[name]
    build_dir = cache / name
    flags = ["-DCMAKE_BUILD_TYPE=MinSizeRel", "-DLLVM_TARGETS_TO_BUILD=",
             "-DLLVM_INCLUDE_TESTS=OFF", "-DLLVM_INCLUDE_EXAMPLES=OFF", "-DLLVM_INCLUDE_BENCHMARKS=OFF",
             "-DLLVM_ENABLE_ZLIB=ON", "-DLLVM_ENABLE_ZSTD=OFF", "-DLLVM_ENABLE_LIBXML2=OFF",
             "-DLLVM_ENABLE_LIBEDIT=OFF", "-DLLVM_ENABLE_TERMINFO=OFF", "-DLLVM_ENABLE_BACKTRACES=OFF",
             "-DLLVM_ENABLE_CRASH_OVERRIDES=OFF", "-DLLVM_ENABLE_ASSERTIONS=OFF",
             "-DLLVM_ENABLE_EH=ON", "-DLLVM_ENABLE_RTTI=ON",
             "-DCMAKE_CXX_VISIBILITY_PRESET=hidden", "-DCMAKE_C_VISIBILITY_PRESET=hidden"]
    if name == "host":
        flags += ["-DCMAKE_OSX_DEPLOYMENT_TARGET=12.0", "-DCMAKE_OSX_ARCHITECTURES=arm64"]
    else:
        flags += [f"-DCMAKE_OSX_ARCHITECTURES={architecture}", f"-DCMAKE_OSX_SYSROOT={sdk}",
                  "-DCMAKE_OSX_DEPLOYMENT_TARGET=" + ("12.0" if sdk == "macosx" else "15.0"),
                  "-DLLVM_INCLUDE_TOOLS=OFF", "-DCMAKE_MACOSX_BUNDLE=OFF",
                  f"-DLLVM_TABLEGEN={cache}/host/bin/llvm-tblgen"]
        if sdk != "macosx":
            flags += ["-DCMAKE_SYSTEM_NAME=iOS", f"-DLLVM_DEFAULT_TARGET_TRIPLE={architecture}-apple-ios15.0"]
    run(["cmake", "-G", "Ninja", "-S", source, "-B", build_dir, *flags], env)
    targets = ["LLVMProfileData"] + (["llvm-config", "llvm-tblgen"] if name == "host" else [])
    run(["cmake", "--build", build_dir, "--target", *targets, "-j", str(jobs)], env)
    sdk_path = subprocess.check_output(["xcrun", "--sdk", sdk, "--show-sdk-path"], env=env, text=True).strip()
    triple = architecture + ("-apple-macos12.0" if sdk == "macosx" else "-apple-ios15.0" + ("-simulator" if sdk == "iphonesimulator" else ""))
    bridge = build_dir / "CCKProfileMerge.o"
    run(["xcrun", "clang++", "-c", tool_root / "CCKProfileMerge.cpp", "-std=c++17", "-Os",
         "-fexceptions", "-frtti", "-fvisibility=hidden", "-target", triple, "-isysroot", sdk_path,
         "-I" + str(tool_root / "include"), "-I" + str(source / "include"),
         "-I" + str(build_dir / "include"), "-o", bridge], env)
    link_flags = shlex.split(subprocess.check_output([str(cache / "host/bin/llvm-config"), "--libs", "profiledata"], env=env, text=True))
    libraries = [build_dir / "lib" / ("lib" + flag[2:] + ".a") for flag in link_flags]
    output = build_dir / "libCCKProfileMerge.a"
    run(["xcrun", "libtool", "-static", "-o", output, bridge, *libraries], env)
    return output


def main():
    """Build all supported architecture slices and create an optional local XCFramework, without installing hosts."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--developer-dir", default="/Applications/Xcode263.app/Contents/Developer")
    parser.add_argument("--targets", nargs="+", choices=TARGETS, default=list(TARGETS))
    parser.add_argument("--jobs", type=int, default=6)
    args = parser.parse_args()
    cache = args.cache.resolve()
    cache.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, DEVELOPER_DIR=args.developer_dir)
    source = prepare_source(cache)
    tool_root = Path(__file__).resolve().parent
    selected = list(dict.fromkeys(["host", *args.targets]))
    outputs = {name: build(cache, source, name, env, args.jobs, tool_root) for name in selected}
    args.output.mkdir(parents=True, exist_ok=True)
    framework = args.output / "CCKProfileMerge.xcframework"
    if framework.exists():
        raise RuntimeError("Refusing to replace an existing XCFramework; choose a fresh output directory")
    command = ["xcodebuild", "-create-xcframework"]
    for label, names in (("macos", ["host", "mac-x86"]), ("ios", ["ios"]), ("simulator", ["sim", "sim-x86"])):
        libraries = [outputs[name] for name in names if name in outputs]
        if not libraries:
            continue
        combined = cache / label / "libCCKProfileMerge.a"
        combined.parent.mkdir(parents=True, exist_ok=True)
        run(["xcrun", "lipo", "-create", *libraries, "-output", combined], env)
        command += ["-library", str(combined), "-headers", str(tool_root / "include")]
    run([*command, "-output", framework], env)
    shutil.copyfile(source / "LICENSE.TXT", args.output / "LLVM-LICENSE.txt")


if __name__ == "__main__":
    main()
