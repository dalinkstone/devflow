# Homebrew formula for devflow.
#
#   brew install dalinkstone/devflow/devflow
#
class Devflow < Formula
  desc "Run Claude Code and Codex in Daytona cloud sandboxes"
  homepage "https://github.com/dalinkstone/devflow"
  url "https://github.com/dalinkstone/devflow/archive/refs/tags/v0.4.0.tar.gz"
  sha256 "40626433a79a45ed6b59d830b9209867b9d0f9dc5708b77be8332f355a05e825"
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
