cask "granny" do
  version "0.1.1"
  sha256 "6f1956173163e34f5d8096b6637bc1c7146bfb51c7ec4c03e6d457290eea8d6b"

  url "https://github.com/HappyVoxel/granny/releases/download/v#{version}/granny-#{version}.zip"
  name "granny"
  desc "A strict macOS task enforcer: work first, play after"
  homepage "https://github.com/HappyVoxel/granny"

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
