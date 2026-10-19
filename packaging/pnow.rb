cask "pnow" do
  version "__VERSION__"
  sha256 "__SHA256__"

  url "https://github.com/tarasyarema/pnow/releases/download/v#{version}/pnow-#{version}.zip"
  name "pnow"
  desc "Post now: instant posting from the menu bar"
  homepage "https://github.com/tarasyarema/pnow"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: :tahoe

  app "pnow.app"

  zap trash: "~/Library/Application Support/pnow"
end
