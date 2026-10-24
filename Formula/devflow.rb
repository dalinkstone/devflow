# Homebrew formula for devflow.
#
#   brew install dalinkstone/devflow/devflow
#
class Devflow < Formula
  desc "Run Claude, Codex, OpenCode, and Pi in Daytona sandboxes"
  homepage "https://github.com/dalinkstone/devflow"
  url "https://github.com/dalinkstone/devflow/archive/refs/tags/v0.11.0.tar.gz"
  sha256 "79b17b62605cfeec4372373b0a6972cab5fa1a87ded16ef81000c732a26319fa"
  license "MIT"
  head "https://github.com/dalinkstone/devflow.git", branch: "main"

  depends_on "daytonaio/cli/daytona"
  depends_on "gh"
  depends_on "jq"
  depends_on "qrencode"
  depends_on "go" => :build
  depends_on "python@3.13"

  def install
    system "make", "tui"
    bin.install "bin/devflow"
    bin.install "bin/devflow-tui"
    bin.install_symlink "devflow" => "dv"
  end

  def caveats
    <<~EOS
      Optional (fuzzy pickers): brew install fzf

      Then run: dv setup
    EOS
  end

  test do
    assert_match "devflow", shell_output("#{bin}/devflow version")
    assert_match "devflow-tui", shell_output("#{bin}/devflow-tui --version")
  end
end
