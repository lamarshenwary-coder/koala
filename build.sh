#!/usr/bin/env bash
# Builds web/ (three.js pet) and the Swift app, then assembles build/Koala.app
set -euo pipefail
cd "$(dirname "$0")"

# Every build re-signs the app (see the ad-hoc/VoicePet-Dev branch below), which
# can change its signature -- and a signature change can silently invalidate a
# still-running old instance's Accessibility/Microphone TCC grant. If that old
# process is still around, a later `open build/Koala.app` just brings IT to
# the front instead of launching the freshly built one, and you get a hotkey
# that looks completely dead (flat overlay bar, nothing happens) for no
# apparent reason. Kill any running copy before rebuilding so that can't happen.
# Matches by the executable's path inside Contents/MacOS regardless of what the
# .app bundle itself is named (it was VoicePet.app before the Koala rename).
pkill -f "Contents/MacOS/VoicePet" 2>/dev/null || true
(cd web && npm run build --silent)
swift build -c release 2>&1 | grep -E "error|warning: var|Build complete" || true
APP=build/Koala.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/web"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp .build/release/VoicePet "$APP/Contents/MacOS/"
cp -R web/dist/. "$APP/Contents/Resources/web/"
# binary frameworks from dependencies (llama.cpp for the on-device brain)
mkdir -p "$APP/Contents/Frameworks"
for fw in $(find .build -type d -name "*.framework" -path "*macos*" 2>/dev/null; find .build/artifacts -type d -name "*.framework" 2>/dev/null); do
  name=$(basename "$fw"); [ -d "$APP/Contents/Frameworks/$name" ] || cp -R "$fw" "$APP/Contents/Frameworks/"
done
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/VoicePet" 2>/dev/null || true
# SwiftPM resource bundles from dependencies, if any
for b in .build/release/*.bundle; do [ -d "$b" ] && cp -R "$b" "$APP/Contents/Resources/"; done
# Strip any quarantine flag that snuck in via copied dependency resources
# (SwiftPM/npm downloads, or files that arrived over the cloud device-bridge).
# A quarantined .app gets Gatekeeper "app translocation": macOS runs it from a
# randomized read-only temp path on every launch instead of its real location,
# which makes it look like a brand new app to TCC every single time -- so the
# Accessibility grant never sticks, even with a stable signing identity.
xattr -cr "$APP" 2>/dev/null || true
# Sign with the stable local identity if it exists (keeps macOS permission grants across rebuilds), else ad-hoc.
# Reverted back to "VoicePet Dev" -- the "Koala Dev" identity was never actually
# created in Keychain, so every build was silently falling back to ad-hoc
# signing, which changes the app's signature (and therefore invalidates its
# Accessibility/Mic/Speech grants) on EVERY single rebuild. That was the real
# cause of a long chain of "the hotkey just doesn't fire" symptoms. Use the
# identity that's actually present until "Koala Dev" gets properly created.
if security find-identity -v -p codesigning 2>/dev/null | grep -q "VoicePet Dev"; then
  codesign --force --deep --sign "VoicePet Dev" "$APP" && echo "signed with VoicePet Dev"
else
  codesign --force --deep --sign - "$APP" && echo "signed ad-hoc (permissions may reset on rebuild)"
fi
# Install a double-click-able copy in /Applications so you never have to launch
# this through Terminal -- Spotlight, Launchpad, and the Dock all only see apps
# that live in a real Applications folder, not build/ inside a dev repo.
#
# IMPORTANT: /Applications/Koala.app must be the ONLY real copy. TCC grants
# (Accessibility/Mic/Speech) are tracked per bundle PATH, not just per
# signature -- having build/Koala.app AND /Applications/Koala.app both be
# real, independently-launchable bundles with the same bundle id is exactly
# the "app translocation" class of bug this script already works around
# above (xattr -cr): whichever copy you happen to launch has to re-earn its
# own grant. So build/Koala.app is left as a symlink into /Applications
# after install -- there's one real bundle, one path, one TCC identity,
# and `open build/Koala.app` still works for convenience.
#
# `ditto` (not `cp -R`) preserves the code signature and extended attributes
# exactly -- `cp -R` can be lossy about resource forks/xattrs on some macOS
# versions. The install step is best-effort: a failure here (e.g. target
# briefly in use) should not make an otherwise-successful build look failed,
# so it's not allowed to trip `set -e`.
install_ok=0
if [ -w /Applications ] || [ -w "/Applications/Koala.app" ] 2>/dev/null; then
  if rm -rf "/Applications/Koala.app" 2>/dev/null && ditto "$APP" "/Applications/Koala.app" 2>/dev/null; then
    touch "/Applications/Koala.app"
    install_ok=1
    rm -rf "$APP"
    ln -s "/Applications/Koala.app" "$APP"
    echo "Installed to /Applications/Koala.app -- launch it from Spotlight/Launchpad, or drag it to the Dock"
    echo "($APP is now a symlink to it, so 'open $APP' still works)"
  else
    echo "Install to /Applications failed (target may be in use) -- run ./build.sh again, or drag $APP there yourself"
  fi
else
  echo "Could not write to /Applications (no permission) -- drag $APP there yourself to get a double-click launcher"
fi
if [ "$install_ok" = "1" ]; then
  echo "Built and installed to /Applications/Koala.app"
else
  echo "Built $APP"
fi
