#!/usr/bin/env python3
"""Generate SmartRingWatcher.xcodeproj/project.pbxproj from the source tree.

Run from anywhere after adding or removing source files:

    python3 tools/generate_xcodeproj.py

The project has one watch-only watchOS app target that compiles the Swift files in
"SmartRingWatcher Watch App/" and the shared protocol layer in "RingProtocol/".
Object IDs are derived from file paths, so regenerating produces a stable diff.
"""
from __future__ import annotations

import hashlib
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROJECT_NAME = "SmartRingWatcher"
TARGET_NAME = "SmartRingWatcher Watch App"
APP_DIR = "SmartRingWatcher Watch App"
SHARED_DIR = "RingProtocol"
BUNDLE_ID = "com.example.SmartRingWatcher.watchkitapp"
DEPLOYMENT_TARGET = "10.0"
SOURCE_DIRS = [APP_DIR, SHARED_DIR]


def oid(*parts: str) -> str:
    """Deterministic 24-hex-digit object ID."""
    return hashlib.md5("/".join(parts).encode()).hexdigest()[:24].upper()


def q(value: str) -> str:
    """Quote a pbxproj string when needed."""
    if value and re.fullmatch(r"[A-Za-z0-9_$./]+", value) and not value.startswith("$("):
        return value
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def file_type(path: Path) -> str:
    return {
        ".swift": "sourcecode.swift",
        ".xcassets": "folder.assetcatalog",
        ".plist": "text.plist.xml",
    }.get(path.suffix, "text")


class Group:
    def __init__(self, rel: str, name: str):
        self.rel = rel
        self.name = name
        self.children: list[tuple[str, str]] = []  # (id, comment)


def collect() -> tuple[dict, list, list, list]:
    """Returns (groups, file_refs, sources, resources)."""
    groups: dict[str, Group] = {}
    file_refs: list[tuple[str, Path]] = []
    sources: list[tuple[str, str, Path]] = []  # (buildFileID, fileRefID, path)
    resources: list[tuple[str, str, Path]] = []

    def ensure_group(rel_dir: str) -> Group:
        if rel_dir not in groups:
            groups[rel_dir] = Group(rel_dir, Path(rel_dir).name)
            parent = str(Path(rel_dir).parent)
            if parent != ".":
                ensure_group(parent).children.append((oid("group", rel_dir), Path(rel_dir).name))
        return groups[rel_dir]

    for top in SOURCE_DIRS:
        top_path = ROOT / top
        ensure_group(top)
        entries = sorted(top_path.rglob("*"))
        for path in entries:
            rel = path.relative_to(ROOT)
            # Skip anything inside an asset catalog; the catalog itself is one reference.
            if any(part.endswith(".xcassets") for part in rel.parts[:-1]):
                continue
            if path.is_dir() and not path.name.endswith(".xcassets"):
                ensure_group(str(rel))
                continue
            if path.name.startswith(".") or path.suffix not in (".swift", ".xcassets", ".plist"):
                continue
            ref_id = oid("ref", str(rel))
            ensure_group(str(rel.parent)).children.append((ref_id, path.name))
            file_refs.append((ref_id, path))
            if path.suffix == ".swift":
                sources.append((oid("build", str(rel)), ref_id, path))
            elif path.suffix == ".xcassets":
                resources.append((oid("build", str(rel)), ref_id, path))
            # Info.plist is referenced by INFOPLIST_FILE, not copied as a resource.
    return groups, file_refs, sources, resources


def build_settings(settings: dict[str, object], indent: str) -> str:
    lines = []
    for key in sorted(settings):
        value = settings[key]
        if isinstance(value, list):
            inner = "".join(f"{indent}\t\t{q(v)},\n" for v in value)
            lines.append(f"{indent}\t{key} = (\n{inner}{indent}\t);")
        else:
            lines.append(f"{indent}\t{key} = {q(str(value))};")
    return "\n".join(lines)


def main() -> None:
    groups, file_refs, sources, resources = collect()

    project_id = oid("project")
    main_group_id = oid("group", "<main>")
    products_group_id = oid("group", "<products>")
    target_id = oid("target", TARGET_NAME)
    product_ref_id = oid("product", TARGET_NAME)
    sources_phase_id = oid("phase", "sources")
    frameworks_phase_id = oid("phase", "frameworks")
    resources_phase_id = oid("phase", "resources")
    project_configs_id = oid("configlist", "project")
    target_configs_id = oid("configlist", "target")
    project_debug_id = oid("config", "project", "Debug")
    project_release_id = oid("config", "project", "Release")
    target_debug_id = oid("config", "target", "Debug")
    target_release_id = oid("config", "target", "Release")
    product_name = f"{TARGET_NAME}.app"

    common_project = {
        "ALWAYS_SEARCH_USER_PATHS": "NO",
        "ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS": "YES",
        "CLANG_ENABLE_MODULES": "YES",
        "CLANG_ENABLE_OBJC_ARC": "YES",
        "COPY_PHASE_STRIP": "NO",
        "ENABLE_STRICT_OBJC_MSGSEND": "YES",
        "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
        "GCC_C_LANGUAGE_STANDARD": "gnu17",
        "GCC_NO_COMMON_BLOCKS": "YES",
        "LOCALIZATION_PREFERS_STRING_CATALOGS": "YES",
        "SDKROOT": "watchos",
        "SWIFT_VERSION": "5.0",
        "WATCHOS_DEPLOYMENT_TARGET": DEPLOYMENT_TARGET,
    }
    project_debug = dict(common_project, **{
        "DEBUG_INFORMATION_FORMAT": "dwarf",
        "ENABLE_TESTABILITY": "YES",
        "GCC_DYNAMIC_NO_PIC": "NO",
        "GCC_OPTIMIZATION_LEVEL": "0",
        "GCC_PREPROCESSOR_DEFINITIONS": ["DEBUG=1", "$(inherited)"],
        "MTL_ENABLE_DEBUG_INFO": "INCLUDE_SOURCE",
        "ONLY_ACTIVE_ARCH": "YES",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG $(inherited)",
        "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
    })
    project_release = dict(common_project, **{
        "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
        "ENABLE_NS_ASSERTIONS": "NO",
        "MTL_ENABLE_DEBUG_INFO": "NO",
        "SWIFT_COMPILATION_MODE": "wholemodule",
        "VALIDATE_PRODUCT": "YES",
    })
    target_common = {
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
        "CODE_SIGN_STYLE": "Automatic",
        "CURRENT_PROJECT_VERSION": "1",
        "DEVELOPMENT_TEAM": "",
        "ENABLE_PREVIEWS": "YES",
        "GENERATE_INFOPLIST_FILE": "YES",
        "INFOPLIST_FILE": f"{APP_DIR}/Info.plist",
        "INFOPLIST_KEY_CFBundleDisplayName": "SmartRing",
        "INFOPLIST_KEY_UISupportedInterfaceOrientations":
            "UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown",
        "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks"],
        "MARKETING_VERSION": "1.0",
        "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID,
        "PRODUCT_NAME": "$(TARGET_NAME)",
        "SDKROOT": "watchos",
        "SWIFT_EMIT_LOC_STRINGS": "YES",
        "SWIFT_VERSION": "5.0",
        "TARGETED_DEVICE_FAMILY": "4",
        "WATCHOS_DEPLOYMENT_TARGET": DEPLOYMENT_TARGET,
    }

    out: list[str] = []
    w = out.append
    w("// !$*UTF8*$!")
    w("{")
    w("\tarchiveVersion = 1;")
    w("\tclasses = {")
    w("\t};")
    w("\tobjectVersion = 56;")
    w("\tobjects = {")
    w("")

    w("/* Begin PBXBuildFile section */")
    for build_id, ref_id, path in sorted(sources + resources):
        phase = "Sources" if path.suffix == ".swift" else "Resources"
        w(f"\t\t{build_id} /* {path.name} in {phase} */ = {{isa = PBXBuildFile; fileRef = {ref_id} /* {path.name} */; }};")
    w("/* End PBXBuildFile section */")
    w("")

    w("/* Begin PBXFileReference section */")
    refs = [(ref_id, path.name, f"lastKnownFileType = {file_type(path)}; path = {q(path.name)}; sourceTree = \"<group>\";")
            for ref_id, path in file_refs]
    refs.append((product_ref_id, product_name,
                 f"explicitFileType = wrapper.application; includeInIndex = 0; path = {q(product_name)}; sourceTree = BUILT_PRODUCTS_DIR;"))
    for ref_id, name, body in sorted(refs):
        w(f"\t\t{ref_id} /* {name} */ = {{isa = PBXFileReference; {body} }};")
    w("/* End PBXFileReference section */")
    w("")

    w("/* Begin PBXFrameworksBuildPhase section */")
    w(f"\t\t{frameworks_phase_id} /* Frameworks */ = {{")
    w("\t\t\tisa = PBXFrameworksBuildPhase;")
    w("\t\t\tbuildActionMask = 2147483647;")
    w("\t\t\tfiles = (")
    w("\t\t\t);")
    w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    w("\t\t};")
    w("/* End PBXFrameworksBuildPhase section */")
    w("")

    w("/* Begin PBXGroup section */")
    group_entries = []
    main_children = [(oid("group", d), d) for d in SOURCE_DIRS] + [(products_group_id, "Products")]
    group_entries.append((main_group_id, None, main_children, None))
    group_entries.append((products_group_id, "Products", [(product_ref_id, product_name)], "name"))
    for rel, group in groups.items():
        children = sorted(group.children, key=lambda c: (not c[1].endswith("/") and "." in c[1], c[1].lower()))
        group_entries.append((oid("group", rel), group.name, children, "path"))
    for group_id, name, children, kind in sorted(group_entries):
        comment = f" /* {name} */" if name else ""
        w(f"\t\t{group_id}{comment} = {{")
        w("\t\t\tisa = PBXGroup;")
        w("\t\t\tchildren = (")
        for child_id, child_name in children:
            w(f"\t\t\t\t{child_id} /* {child_name} */,")
        w("\t\t\t);")
        if kind == "name":
            w(f"\t\t\tname = {q(name)};")
        elif kind == "path":
            w(f"\t\t\tpath = {q(name)};")
        w("\t\t\tsourceTree = \"<group>\";")
        w("\t\t};")
    w("/* End PBXGroup section */")
    w("")

    w("/* Begin PBXNativeTarget section */")
    w(f"\t\t{target_id} /* {TARGET_NAME} */ = {{")
    w("\t\t\tisa = PBXNativeTarget;")
    w(f"\t\t\tbuildConfigurationList = {target_configs_id} /* Build configuration list for PBXNativeTarget \"{TARGET_NAME}\" */;")
    w("\t\t\tbuildPhases = (")
    w(f"\t\t\t\t{sources_phase_id} /* Sources */,")
    w(f"\t\t\t\t{frameworks_phase_id} /* Frameworks */,")
    w(f"\t\t\t\t{resources_phase_id} /* Resources */,")
    w("\t\t\t);")
    w("\t\t\tbuildRules = (")
    w("\t\t\t);")
    w("\t\t\tdependencies = (")
    w("\t\t\t);")
    w(f"\t\t\tname = {q(TARGET_NAME)};")
    w("\t\t\tpackageProductDependencies = (")
    w("\t\t\t);")
    w(f"\t\t\tproductName = {q(TARGET_NAME)};")
    w(f"\t\t\tproductReference = {product_ref_id} /* {product_name} */;")
    w("\t\t\tproductType = \"com.apple.product-type.application\";")
    w("\t\t};")
    w("/* End PBXNativeTarget section */")
    w("")

    w("/* Begin PBXProject section */")
    w(f"\t\t{project_id} /* Project object */ = {{")
    w("\t\t\tisa = PBXProject;")
    w("\t\t\tattributes = {")
    w("\t\t\t\tBuildIndependentTargetsInParallel = 1;")
    w("\t\t\t\tLastSwiftUpdateCheck = 1600;")
    w("\t\t\t\tLastUpgradeCheck = 1600;")
    w("\t\t\t\tTargetAttributes = {")
    w(f"\t\t\t\t\t{target_id} = {{")
    w("\t\t\t\t\t\tCreatedOnToolsVersion = 16.0;")
    w("\t\t\t\t\t};")
    w("\t\t\t\t};")
    w("\t\t\t};")
    w(f"\t\t\tbuildConfigurationList = {project_configs_id} /* Build configuration list for PBXProject \"{PROJECT_NAME}\" */;")
    w("\t\t\tcompatibilityVersion = \"Xcode 14.0\";")
    w("\t\t\tdevelopmentRegion = en;")
    w("\t\t\thasScannedForEncodings = 0;")
    w("\t\t\tknownRegions = (")
    w("\t\t\t\ten,")
    w("\t\t\t\tBase,")
    w("\t\t\t);")
    w(f"\t\t\tmainGroup = {main_group_id};")
    w(f"\t\t\tproductRefGroup = {products_group_id} /* Products */;")
    w("\t\t\tprojectDirPath = \"\";")
    w("\t\t\tprojectRoot = \"\";")
    w("\t\t\ttargets = (")
    w(f"\t\t\t\t{target_id} /* {TARGET_NAME} */,")
    w("\t\t\t);")
    w("\t\t};")
    w("/* End PBXProject section */")
    w("")

    w("/* Begin PBXResourcesBuildPhase section */")
    w(f"\t\t{resources_phase_id} /* Resources */ = {{")
    w("\t\t\tisa = PBXResourcesBuildPhase;")
    w("\t\t\tbuildActionMask = 2147483647;")
    w("\t\t\tfiles = (")
    for build_id, _, path in sorted(resources):
        w(f"\t\t\t\t{build_id} /* {path.name} in Resources */,")
    w("\t\t\t);")
    w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    w("\t\t};")
    w("/* End PBXResourcesBuildPhase section */")
    w("")

    w("/* Begin PBXSourcesBuildPhase section */")
    w(f"\t\t{sources_phase_id} /* Sources */ = {{")
    w("\t\t\tisa = PBXSourcesBuildPhase;")
    w("\t\t\tbuildActionMask = 2147483647;")
    w("\t\t\tfiles = (")
    for build_id, _, path in sorted(sources, key=lambda s: str(s[2])):
        w(f"\t\t\t\t{build_id} /* {path.name} in Sources */,")
    w("\t\t\t);")
    w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    w("\t\t};")
    w("/* End PBXSourcesBuildPhase section */")
    w("")

    w("/* Begin XCBuildConfiguration section */")
    configs = [
        (project_debug_id, "Debug", project_debug),
        (project_release_id, "Release", project_release),
        (target_debug_id, "Debug", target_common),
        (target_release_id, "Release", target_common),
    ]
    for config_id, name, settings in sorted(configs):
        w(f"\t\t{config_id} /* {name} */ = {{")
        w("\t\t\tisa = XCBuildConfiguration;")
        w("\t\t\tbuildSettings = {")
        w(build_settings(settings, "\t\t\t"))
        w("\t\t\t};")
        w(f"\t\t\tname = {name};")
        w("\t\t};")
    w("/* End XCBuildConfiguration section */")
    w("")

    w("/* Begin XCConfigurationList section */")
    lists = [
        (project_configs_id, f"Build configuration list for PBXProject \"{PROJECT_NAME}\"", project_debug_id, project_release_id),
        (target_configs_id, f"Build configuration list for PBXNativeTarget \"{TARGET_NAME}\"", target_debug_id, target_release_id),
    ]
    for list_id, comment, debug_id, release_id in sorted(lists):
        w(f"\t\t{list_id} /* {comment} */ = {{")
        w("\t\t\tisa = XCConfigurationList;")
        w("\t\t\tbuildConfigurations = (")
        w(f"\t\t\t\t{debug_id} /* Debug */,")
        w(f"\t\t\t\t{release_id} /* Release */,")
        w("\t\t\t);")
        w("\t\t\tdefaultConfigurationIsVisible = 0;")
        w("\t\t\tdefaultConfigurationName = Release;")
        w("\t\t};")
    w("/* End XCConfigurationList section */")
    w("\t};")
    w(f"\trootObject = {project_id} /* Project object */;")
    w("}")

    project_dir = ROOT / f"{PROJECT_NAME}.xcodeproj"
    project_dir.mkdir(exist_ok=True)
    (project_dir / "project.pbxproj").write_text("\n".join(out) + "\n")
    print(f"Wrote {project_dir / 'project.pbxproj'}: {len(sources)} Swift files, {len(resources)} resource(s).")


if __name__ == "__main__":
    main()
