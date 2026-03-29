class Nudge < Formula
  desc "Terminal activity monitor - notifications for finished commands, input prompts, and Claude Code"
  homepage "https://github.com/omar-dakalbab/nudge"
  url "https://github.com/omar-dakalbab/nudge/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "cd961b8a4383e3bedda03230906b39c2ce9a185b112bf3582e22b2798ac052cf"
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
