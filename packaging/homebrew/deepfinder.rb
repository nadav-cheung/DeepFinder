# frozen_string_literal: true

# DeepFinder — instant file search for macOS.
# Homebrew formula for building and installing from source.
#
# Usage:
#   brew install ./packaging/homebrew/deepfinder.rb
#
# After the first Homebrew release:
#   brew tap nadav-cheung/deepfinder
#   brew install deepfinder

class Deepfinder < Formula
  desc "Instant file search for macOS — like Everything but native"
  homepage "https://github.com/nadav-cheung/DeepFinder"
  url "https://github.com/nadav-cheung/DeepFinder/archive/refs/tags/v3.0.0.tar.gz"
  sha256 "REPLACE_WITH_ACTUAL_TARBALL_SHA256"
  license "MIT"
  head "https://github.com/nadav-cheung/DeepFinder.git", branch: "main"

  depends_on :macos => :tahoe  # macOS 26+
  depends_on :xcode => ["16.0", :build]

  # Both executables are built from the same Swift package.
  def install
    system "swift", "build",
           "-c", "release",
           "--disable-sandbox",
           "--product", "deepfinder"
    system "swift", "build",
           "-c", "release",
           "--disable-sandbox",
           "--product", "deepfinder-daemon"

    # Install binaries into the Homebrew prefix.
    bin.install ".build/release/deepfinder"
    bin.install ".build/release/deepfinder-daemon"

    # Install man page.
    man1.install "packaging/deepfinder.1"

    # Install shell completions.
    bash_completion.install "packaging/completions/deepfinder.bash"
    zsh_completion.install "packaging/completions/_deepfinder"
    fish_completion.install "packaging/completions/deepfinder.fish"
  end

  def post_install
    ohai "DeepFinder requires Full Disk Access to index your files."
    ohai ""
    ohai "To grant Full Disk Access:"
    ohai "  1. Open System Preferences > Privacy & Security > Full Disk Access"
    ohai "  2. Click + and add: #{opt_bin}/deepfinder-daemon"
    ohai "  3. Alternatively, add the LaunchAgent from Terminal.app"
    ohai ""
    ohai "To start the daemon:  deepfinder daemon start"
    ohai "To auto-start on login:  deepfinder install"
  end

  # Verify the binary runs and reports the correct version.
  test do
    assert_match "DeepFinder #{version}", shell_output("#{bin}/deepfinder --version")
    assert_match "USAGE", shell_output("#{bin}/deepfinder --help")
  end
end
