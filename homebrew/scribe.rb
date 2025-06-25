class Scribe < Formula
  desc "Multi-Agent Code Orchestration System using Claude Code"
  homepage "https://github.com/yourusername/scribe"
  url "https://github.com/yourusername/scribe/archive/v1.0.0.tar.gz"
  sha256 "YOUR_SHA256_HERE"
  license "MIT"

  depends_on "git"
  depends_on "jq"
  depends_on "gh"

  def install
    # Install all scripts
    libexec.install Dir["*"]
    
    # Create wrapper script
    (bin/"scribe").write <<~EOS
      #!/bin/bash
      exec "#{libexec}/scribe.sh" "$@"
    EOS
    
    # Make scripts executable
    chmod 0755, libexec/"scribe.sh"
    chmod 0755, Dir[libexec/"lib/*.sh"]
  end

  def caveats
    <<~EOS
      Scribe requires Claude Code CLI to be installed separately.
      Please ensure 'claude' is available in your PATH.

      To get started:
        scribe "Feature description" "https://github.com/org/repo"
    EOS
  end

  test do
    system "#{bin}/scribe", "--help"
  end
end