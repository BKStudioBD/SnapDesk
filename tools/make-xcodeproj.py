#!/usr/bin/env python3
"""Regenerate SnapDesk.xcodeproj from the files on disk.

The project file is CHECKED IN, so nobody needs this script to build: it exists
so the project can be rebuilt after files are added or moved, without hand-
editing a pbxproj or taking on XcodeGen as a dependency.

Why an Xcode project at all: `build.sh` writes Contents/Info.plist by hand, and
a key it forgot (`CFBundleDevelopmentRegion`) crashed the app six times in a
stack that named nothing of ours. Xcode owns the bundle here instead.

    ./tools/make-xcodeproj.py        # writes SnapDesk.xcodeproj/project.pbxproj

Identifiers are derived from each path, so regenerating produces the same file
and a diff shows only what actually changed.
"""

import hashlib
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE_DIRS = ["App", "Capture", "Features", "Hotkeys", "Settings", "Support"]
# `Resources/Sounds` is a folder reference, not two loose files: `Sounds.swift`
# asks for `subdirectory: "Sounds"` first, and a flattened copy only works
# because of its fallback. Ship the layout the code expects.
RESOURCES = ["Resources/AppIcon.icns", "Resources/Sounds"]

DEPLOYMENT_TARGET = "14.0"
SWIFT_VERSION = "5.0"
BUNDLE_ID = "com.snapdesk.app"


def oid(*parts: str) -> str:
    """A stable 24-hex-character object id for a path or role."""
    return hashlib.md5("|".join(parts).encode()).hexdigest()[:24].upper()


def sources() -> list[str]:
    found: list[str] = []
    for directory in SOURCE_DIRS:
        found += [str(p.relative_to(ROOT)) for p in sorted((ROOT / directory).rglob("*.swift"))]
    return found


def file_type(path: str) -> str:
    return {
        "": "folder",
        ".swift": "sourcecode.swift",
        ".icns": "image.icns",
        ".wav": "audio.wav",
        ".plist": "text.plist.xml",
        ".entitlements": "text.plist.entitlements",
    }[pathlib.Path(path).suffix]


def group_tree(paths: list[str]) -> dict:
    """Nested dict mirroring the directories, so the navigator matches the repo."""
    tree: dict = {}
    for path in paths:
        node = tree
        parts = path.split("/")
        for part in parts[:-1]:
            node = node.setdefault(part, {})
        node.setdefault("__files__", []).append(path)
    return tree


def emit_groups(name: str, node: dict, path_prefix: str, out: list[str]) -> str:
    """Writes PBXGroup entries depth-first; returns this group's id."""
    children: list[str] = []
    for key in sorted(k for k in node if k != "__files__"):
        child_path = f"{path_prefix}/{key}" if path_prefix else key
        children.append(emit_groups(key, node[key], child_path, out))
    for f in sorted(node.get("__files__", [])):
        children.append(oid("file", f))
    group_id = oid("group", path_prefix or "root")
    listed = "\n".join(f"\t\t\t\t{c} ,".replace(" ,", ",") for c in children)
    out.append(
        f"\t\t{group_id} /* {name} */ = {{\n"
        f"\t\t\tisa = PBXGroup;\n"
        f"\t\t\tchildren = (\n{listed}\n\t\t\t);\n"
        + (f"\t\t\tpath = {name};\n" if path_prefix else "")
        + f"\t\t\tsourceTree = \"<group>\";\n"
        f"\t\t}};"
    )
    return group_id


def main() -> int:
    swift_files = sources()
    if not swift_files:
        print("No Swift sources found. Run this from the repository.", file=sys.stderr)
        return 1

    all_files = swift_files + RESOURCES + ["Resources/Info.plist",
                                           "SnapDesk.entitlements",
                                           "SnapDesk-MAS.entitlements"]

    refs, build_files, sources_phase, resources_phase = [], [], [], []
    for path in all_files:
        fid, bid = oid("file", path), oid("build", path)
        name = path.split("/")[-1]
        refs.append(
            f'\t\t{fid} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = {file_type(path)}; '
            f'path = {name}; sourceTree = "<group>"; }};'
        )
        if path.endswith(".swift"):
            build_files.append(f'\t\t{bid} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {fid} /* {name} */; }};')
            sources_phase.append(f"\t\t\t\t{bid} /* {name} in Sources */,")
        elif path in RESOURCES:
            build_files.append(f'\t\t{bid} /* {name} in Resources */ = {{isa = PBXBuildFile; fileRef = {fid} /* {name} */; }};')
            resources_phase.append(f"\t\t\t\t{bid} /* {name} in Resources */,")

    groups: list[str] = []
    root_group = emit_groups("SnapDesk", group_tree(all_files), "", groups)

    product_id = oid("product")
    target_id = oid("target")
    project_id = oid("project")
    sources_id = oid("phase", "sources")
    resources_id = oid("phase", "resources")
    frameworks_id = oid("phase", "frameworks")
    products_group = oid("group", "Products")

    def settings(configuration: str) -> str:
        release = configuration == "Release"
        return "\n".join([
            "\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;",
            "\t\t\t\tARCHS = arm64;",
            "\t\t\t\tCLANG_ENABLE_OBJC_ARC = YES;",
            "\t\t\t\tCODE_SIGN_ENTITLEMENTS = SnapDesk.entitlements;",
            "\t\t\t\tCODE_SIGN_IDENTITY = \"-\";",
            "\t\t\t\tCODE_SIGN_STYLE = Manual;",
            "\t\t\t\tCOMBINE_HIDPI_IMAGES = YES;",
            "\t\t\t\tCURRENT_PROJECT_VERSION = 1;",
            "\t\t\t\tDEVELOPMENT_TEAM = \"\";",
            "\t\t\t\tENABLE_HARDENED_RUNTIME = YES;",
            "\t\t\t\tGENERATE_INFOPLIST_FILE = NO;",
            "\t\t\t\tINFOPLIST_FILE = Resources/Info.plist;",
            f"\t\t\t\tMACOSX_DEPLOYMENT_TARGET = {DEPLOYMENT_TARGET};",
            "\t\t\t\tMARKETING_VERSION = 1.1.0;",
            f"\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = {BUNDLE_ID};",
            "\t\t\t\tPRODUCT_NAME = SnapDesk;",
            "\t\t\t\tPROVISIONING_PROFILE_SPECIFIER = \"\";",
            "\t\t\t\tSDKROOT = macosx;",
            f"\t\t\t\tSWIFT_VERSION = {SWIFT_VERSION};",
            "\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = " + ("\"-O\";" if release else "\"-Onone\";"),
            "\t\t\t\tONLY_ACTIVE_ARCH = " + ("NO;" if release else "YES;"),
            "\t\t\t\tDEBUG_INFORMATION_FORMAT = " + ("\"dwarf-with-dsym\";" if release else "dwarf;"),
            "\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = " + ("\"\";" if release else "DEBUG;"),
            "\t\t\t\tENABLE_USER_SCRIPT_SANDBOXING = YES;",
            "\t\t\t\tCLANG_ENABLE_MODULES = YES;",
            # Xcode injects `get-task-allow` when it signs a build to run
            # locally. That entitlement makes the app debuggable by anything on
            # the machine, and notarization refuses a build that carries it, so
            # a release must never be signed with it present.
            "\t\t\t\tCODE_SIGN_INJECT_BASE_ENTITLEMENTS = " + ("NO;" if release else "YES;"),
        ])

    configs, config_lists = [], []
    for scope, owner in (("project", project_id), ("target", target_id)):
        ids = []
        for configuration in ("Debug", "Release"):
            cid = oid("config", scope, configuration)
            ids.append(f"\t\t\t\t{cid} /* {configuration} */,")
            body = settings(configuration) if scope == "target" else (
                f"\t\t\t\tMACOSX_DEPLOYMENT_TARGET = {DEPLOYMENT_TARGET};\n"
                "\t\t\t\tSDKROOT = macosx;\n"
                f"\t\t\t\tSWIFT_VERSION = {SWIFT_VERSION};")
            configs.append(
                f"\t\t{cid} /* {configuration} */ = {{\n"
                f"\t\t\tisa = XCBuildConfiguration;\n"
                f"\t\t\tbuildSettings = {{\n{body}\n\t\t\t}};\n"
                f"\t\t\tname = {configuration};\n\t\t}};")
        list_id = oid("configlist", scope)
        config_lists.append(
            f"\t\t{list_id} /* Build configuration list */ = {{\n"
            f"\t\t\tisa = XCConfigurationList;\n"
            f"\t\t\tbuildConfigurations = (\n" + "\n".join(ids) + "\n\t\t\t);\n"
            f"\t\t\tdefaultConfigurationIsVisible = 0;\n"
            f"\t\t\tdefaultConfigurationName = Release;\n\t\t}};")

    newline = "\n"
    project = f"""// !$*UTF8*$!
{{
\tarchiveVersion = 1;
\tclasses = {{
\t}};
\tobjectVersion = 56;
\tobjects = {{

/* Begin PBXBuildFile section */
{newline.join(sorted(build_files))}
/* End PBXBuildFile section */

/* Begin PBXFileReference section */
{newline.join(sorted(refs))}
\t\t{product_id} /* SnapDesk.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = SnapDesk.app; sourceTree = BUILT_PRODUCTS_DIR; }};
/* End PBXFileReference section */

/* Begin PBXFrameworksBuildPhase section */
\t\t{frameworks_id} /* Frameworks */ = {{
\t\t\tisa = PBXFrameworksBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
{newline.join(groups)}
\t\t{products_group} /* Products */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{product_id} /* SnapDesk.app */,
\t\t\t);
\t\t\tname = Products;
\t\t\tsourceTree = "<group>";
\t\t}};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
\t\t{target_id} /* SnapDesk */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = {oid("configlist", "target")} /* Build configuration list */;
\t\t\tbuildPhases = (
\t\t\t\t{sources_id} /* Sources */,
\t\t\t\t{frameworks_id} /* Frameworks */,
\t\t\t\t{resources_id} /* Resources */,
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t);
\t\t\tname = SnapDesk;
\t\t\tproductName = SnapDesk;
\t\t\tproductReference = {product_id} /* SnapDesk.app */;
\t\t\tproductType = "com.apple.product-type.application";
\t\t}};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
\t\t{project_id} /* Project object */ = {{
\t\t\tisa = PBXProject;
\t\t\tattributes = {{
\t\t\t\tBuildIndependentTargetsInParallel = 1;
\t\t\t\tLastSwiftUpdateCheck = 2660;
\t\t\t\tLastUpgradeCheck = 2660;
\t\t\t\tTargetAttributes = {{
\t\t\t\t\t{target_id} = {{
\t\t\t\t\t\tCreatedOnToolsVersion = 26.6;
\t\t\t\t\t}};
\t\t\t\t}};
\t\t\t}};
\t\t\tbuildConfigurationList = {oid("configlist", "project")} /* Build configuration list */;
\t\t\tdevelopmentRegion = en;
\t\t\thasScannedForEncodings = 0;
\t\t\tknownRegions = (
\t\t\t\ten,
\t\t\t\tBase,
\t\t\t);
\t\t\tmainGroup = {root_group} /* SnapDesk */;
\t\t\tproductRefGroup = {products_group} /* Products */;
\t\t\tprojectDirPath = "";
\t\t\tprojectRoot = "";
\t\t\ttargets = (
\t\t\t\t{target_id} /* SnapDesk */,
\t\t\t);
\t\t}};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
\t\t{resources_id} /* Resources */ = {{
\t\t\tisa = PBXResourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
{newline.join(sorted(resources_phase))}
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
/* End PBXResourcesBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
\t\t{sources_id} /* Sources */ = {{
\t\t\tisa = PBXSourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
{newline.join(sorted(sources_phase))}
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
/* End PBXSourcesBuildPhase section */

/* Begin XCBuildConfiguration section */
{newline.join(configs)}
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
{newline.join(config_lists)}
/* End XCConfigurationList section */
\t}};
\trootObject = {project_id} /* Project object */;
}}
"""

    out_dir = ROOT / "SnapDesk.xcodeproj"
    out_dir.mkdir(exist_ok=True)
    (out_dir / "project.pbxproj").write_text(project)
    print(f"Wrote {out_dir.relative_to(ROOT)}/project.pbxproj "
          f"({len(swift_files)} sources, {len(RESOURCES)} resources)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
