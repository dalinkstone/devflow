# Homebrew formula for devflow.
#
#   brew tap dalinkstone/devflow https://github.com/dalinkstone/devflow
#   brew install dalinkstone/devflow/devflow
#
class Devflow < Formula
  desc "Agentic cloud dev sessions: Claude Code / Codex in Daytona sandboxes, on your subscriptions"
  homepage "https://github.com/dalinkstone/devflow"
  url "https://github.com/dalinkstone/devflow/archive/refs/tags/v0.3.0.tar.gz"
  sha256 "eba1e80a274ebbac08ef865aa8f001890b2e0119b50482c23dfc05fcf6674269"
  license "MIT"
  head "https://github.com/dalinkstone/devflow.git", branch: "main"

  depends_on "gh"
  depends_on "jq"
  depends_on "qrencode"

  def install
    bin.install "bin/devflow"
    bin.install_symlink "devflow" => "dv"
  end

  def caveats
    <<~EOS
      devflow drives the Daytona CLI. Install it with:
        brew install daytonaio/cli/daytona

      Optional (fuzzy pickers): brew install fzf

      Then run:  devflow setup
    EOS
  end

  test do
    assert_match "devflow", shell_output("#{bin}/devflow version")
  end
end
