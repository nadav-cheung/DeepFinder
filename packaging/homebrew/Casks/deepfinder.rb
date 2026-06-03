# frozen_string_literal: true

# DeepFinder — instant file search for macOS.
# Homebrew Cask for installing the pre-built .app bundle.
#
# Usage:
#   brew install --cask ./packaging/homebrew/Casks/deepfinder.rb
#
# Or via tap:
#   brew tap nadav-cheung/deepfinder
#   brew install --cask deepfinder

cask "deepfinder" do
  version "3.2.0"
  sha256 :no_check

  url "https://github.com/nadav-cheung/DeepFinder/releases/download/v#{version}/DeepFinder-#{version}.zip"
  name "DeepFinder"
  desc "Lightning-fast macOS file search — like Everything but native"
  homepage "https://github.com/nadav-cheung/DeepFinder"

  depends_on macos: ">= :tahoe"

  app "DeepFinder.app"

  caveats <<~EOS
    DeepFinder requires Full Disk Access to search all directories.
    To grant access:
      System Settings -> Privacy & Security -> Full Disk Access -> enable DeepFinder
  EOS
end
