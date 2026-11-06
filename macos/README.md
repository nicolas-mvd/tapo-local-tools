# Tapo Menu for macOS

See the [main README](../README.md#tapo-menu-for-macos) for build and setup steps. The build looks for Node.js and FFmpeg on your `PATH`. Set `TAPO_NODE` or `TAPO_FFMPEG` to an absolute executable path to override either one.

Tapo Menu stores camera addresses and local access tokens in private files under `~/Library/Application Support/Tapo Menu`. To change camera addresses, edit `config.json`. Keep the two IDs and replace the sample addresses with your cameras' private IPv4 addresses.

```json
{
  "cameras": [
    { "id": "1", "host": "192.168.50.20" },
    { "id": "2", "host": "192.168.50.21" }
  ]
}
```

Keep `config.json` readable only by your user with mode `0600`. Choose **Sign In…** or **Sign In Again…** from the menu to refresh the tokens after changing addresses, or if the cameras reject the saved tokens. If a battery reading or live feed is slow to appear, walk past the camera to wake it and try again.
