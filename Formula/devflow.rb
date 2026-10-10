# Homebrew formula for devflow.
#
#   brew install dalinkstone/devflow/devflow
#
class Devflow < Formula
  desc "Run Claude, Codex, OpenCode, and Pi in Daytona sandboxes"
  homepage "https://github.com/dalinkstone/devflow"
  url "https://github.com/dalinkstone/devflow/archive/refs/tags/v0.10.0.tar.gz"
  sha256 "8be9ea8008993066353f1aa58e9e82ea86a156c3cc43f7e79af97290eeefed98"
  license "MIT"
  head "https://github.com/dalinkstone/devflow.git", branch: "main"

  depends_on "daytonaio/cli/daytona"
  depends_on "gh"
  depends_on "jq"
  depends_on "qrencode"

  def install
    bin.install "bin/devflow"
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
  end
end
