# Homebrew cask for SnapDesk.
#
# This file lives in the repo so it can be served as a TAP — no need to get into
# homebrew-cask itself, and every release updates in one commit:
#
#   brew tap bkstudiobd/snapdesk https://github.com/BKStudioBD/SnapDesk
#   brew install --cask snapdesk
#
# (Homebrew looks for casks in a `Casks/` directory at the tap root, which is why
# this sits here rather than under docs/.)
#
# ON EACH RELEASE, update `version` and `sha256`. Get the checksum from the
# published asset — never from a local build, which won't match the notarized one:
#
#   shasum -a 256 <(curl -sL https://github.com/BKStudioBD/SnapDesk/releases/download/v1.1.0/SnapDesk.zip)
#
# Until the first signed + notarized release exists, `sha256 :no_check` is the
# honest placeholder: pinning a wrong checksum fails the install with a confusing
# mismatch error instead of a clear one.
cask "snapdesk" do
  version "1.1.0"
  sha256 :no_check

  url "https://github.com/BKStudioBD/SnapDesk/releases/download/v#{version}/SnapDesk.zip",
      verified: "github.com/BKStudioBD/SnapDesk/"
  name "SnapDesk"
  desc "Menu-bar capture toolkit: screenshots, OCR, colour picker, clipboard history, screen recording"
  homepage "https://github.com/BKStudioBD/SnapDesk"

  # The in-app updater replaces the bundle in place, so tell Homebrew not to be
  # surprised by a version it didn't install.
  auto_updates true
  depends_on macos: ">= :sonoma"   # LSMinimumSystemVersion is 14.0

  app "SnapDesk.app"

  # Everything SnapDesk writes, so `brew uninstall --zap` leaves nothing behind.
  # Deliberately explicit rather than a wildcard: a stray glob under ~/Library is
  # how a zap deletes someone else's data.
  zap trash: [
    "~/Library/Preferences/com.snapdesk.app.plist",
    "~/Library/Logs/SnapDesk",
    "~/Library/Saved Application State/com.snapdesk.app.savedState",
  ]
end
