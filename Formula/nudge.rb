class Nudge < Formula
  desc "Terminal activity monitor - notifications for finished commands, input prompts, and Claude Code"
  homepage "https://github.com/omar-dakalbab/nudge"
  url "https://github.com/omar-dakalbab/nudge/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "PLACEHOLDER"
  license "MIT"
  head "https://github.com/omar-dakalbab/nudge.git", branch: "main"

  depends_on xcode: ["14.0", :build]
  depends_on :macos

  def install
    system "swift", "build", "-c", "release", "--disable-sandbox"
    bin.install ".build/release/nudge"
  end

  test do
    assert_match "nudge 0.1.0", shell_output("#{bin}/nudge --version")
  end
end
