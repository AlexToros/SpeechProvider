#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
cd "$project_dir"

app_version="${APP_VERSION:-0.1.0}"
app_version="${app_version#v}"
build_number="${BUILD_NUMBER:-1}"
app_name="Speech Provider"
app_path="$project_dir/dist/$app_name.app"

swift build -c release
build_dir="$(swift build -c release --show-bin-path)"
executable="$build_dir/SpeechProvider"
resources_bundle="$build_dir/SpeechProvider_SpeechProvider.bundle"

[[ -x "$executable" ]] || { print -u2 "Не найден исполняемый файл: $executable"; exit 1; }
[[ -d "$resources_bundle" ]] || { print -u2 "Не найден bundle ресурсов: $resources_bundle"; exit 1; }

rm -rf "$app_path"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$executable" "$app_path/Contents/MacOS/SpeechProvider"
cp "Packaging/Info.plist" "$app_path/Contents/Info.plist"
cp -R "$resources_bundle" "$app_path/Contents/Resources/"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $app_version" "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$app_path/Contents/Info.plist"

codesign --force --deep --sign - "$app_path"
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$project_dir/dist/SpeechProvider-macOS-$app_version.zip"

print "Готово: $project_dir/dist/SpeechProvider-macOS-$app_version.zip"
