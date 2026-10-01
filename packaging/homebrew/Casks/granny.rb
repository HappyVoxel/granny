cask "granny" do
  version "0.1.0"
  sha256 "bdeec04fa3502e1ed9357f0fcb2ac8db3cc3d390424a16e28db78dcfadafa2dc"

  url "https://github.com/HappyVoxel/granny-agent/releases/download/v#{version}/granny-#{version}.zip"
  name "granny"
  desc "A strict macOS task enforcer: work first, play after"
  homepage "https://github.com/HappyVoxel/granny-agent"

  depends_on macos: :sonoma

  app "granny.app"

  caveats <<~EOS
    granny is not notarized yet. Skip the quarantine flag up front:
      brew install --cask --no-quarantine granny
    (already installed? right-click the app -> Open, or:
      xattr -dr com.apple.quarantine /Applications/granny.app)

    One-time setup after install (full guide: docs/INSTALL.md):

      1. Open granny (Dock or Spotlight), then menu -> Install helper… and
         approve the admin prompt once. No Terminal needed; this is what lets
         granny own /etc/hosts without asking again.
      2. Load the browser extension, shipped inside the app:
           - Chrome-family: chrome://extensions -> Developer mode ->
             Load unpacked -> granny.app/Contents/Resources/extension
           - Safari: build from source once (Xcode); Safari extensions cannot
             be sideloaded.
      3. menu -> Settings… and paste your API keys (OpenRouter, optional
         Laya or Jev classifier, optional Langfuse). granny is BYOK.
      4. Say Allow when macOS asks for notifications and for controlling
         Safari (the tab janitor).

    macOS requires those consent prompts by design; nothing can pre-approve
    them for the user.
  EOS
end
