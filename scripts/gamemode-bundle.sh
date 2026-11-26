#!/bin/sh
# Run Wine from inside a minimal app bundle so macOS Game Mode can apply (full screen only).
#
# macOS enables Game Mode for a full-screen app whose bundle declares a games category. Wine's loader is a
# bare executable, so this puts a copy of it in "Wine FSX.app/Contents/MacOS/" (with an ntdll.so symlink,
# which the loader looks for beside itself) and replaces the installed loader with a *symlink* to it.
# Every Wine process, including the ones x87sidecar starts, then runs from inside the bundle.
# Do not use a shell-script wrapper here: x87sidecar must exec an x86 Mach-O, and a script makes every
# 32-bit process crash. Symlinks are relative, so the runtime folder can be moved.
#
# Usage: scripts/gamemode-bundle.sh install|remove <wine install prefix> [bundle dir]
set -e
action=$1
prefix=$(cd "$2" && pwd)
bundle=${3:-$(dirname "$prefix")/Wine FSX.app}
unix="$prefix/lib/wine/x86_64-unix"
relpath() { python3 -I -c 'import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' "$1" "$2"; }

case "$action" in
install)
    [ -f "$unix/wine.bin" ] && [ ! -L "$unix/wine" ] && rm -f "$unix/wine.bin"   # fresh `make install`
    [ -f "$unix/wine.bin" ] || cp -p "$unix/wine" "$unix/wine.bin"
    mkdir -p "$bundle/Contents/MacOS"
    bundle=$(cd "$bundle" && pwd)
    cp -p "$unix/wine.bin" "$bundle/Contents/MacOS/wine"
    ln -sfn "$(relpath "$unix/ntdll.so" "$bundle/Contents/MacOS")" "$bundle/Contents/MacOS/ntdll.so"
    cat > "$bundle/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>		<string>org.fsxsilicon.wine</string>
	<key>CFBundleName</key>			<string>Wine FSX</string>
	<key>CFBundleExecutable</key>		<string>wine</string>
	<key>CFBundlePackageType</key>		<string>APPL</string>
	<key>CFBundleShortVersionString</key>	<string>11.0</string>
	<key>LSApplicationCategoryType</key>	<string>public.app-category.simulation-games</string>
	<key>LSSupportsGameMode</key>		<true/>
	<key>NSHighResolutionCapable</key>	<true/>
</dict>
</plist>
EOF
    ln -sfn "$(relpath "$bundle/Contents/MacOS/wine" "$unix")" "$unix/wine"
    echo "installed: $unix/wine -> $(readlink "$unix/wine")"
    ;;
remove)
    [ -f "$unix/wine.bin" ] && { rm -f "$unix/wine"; cp -p "$unix/wine.bin" "$unix/wine"; }
    echo "restored $unix/wine (bundle left at $bundle)"
    ;;
*)
    echo "usage: $0 install|remove <wine install prefix> [bundle dir]" >&2
    exit 2
    ;;
esac
