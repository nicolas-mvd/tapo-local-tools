# Tapo Menu for macOS

See the [main README](../README.md#tapo-menu-for-macos) for build and setup steps. The build looks for Node.js and FFmpeg on your `PATH`. Set `TAPO_NODE` or `TAPO_FFMPEG` to an absolute executable path to override either one.

Choose **Settings…** from the camera icon to add, name, or edit one to sixteen cameras. Enter their private IPv4 addresses. The first time you choose **Sign In…**, you can set up your cameras and then enter your TP-Link credentials directly in Terminal. To sign in a single camera, select its row before signing it in. When discovery cannot reach a camera, the Terminal helper can ask for the MAC address printed on that camera.

Use **Cancel Sign-In** in the menu to stop a pending attempt. You can also close the Terminal window or press Control-C there. Open **Sign In…** again to retry. Tapo Menu keeps the existing access tokens until a new attempt succeeds.

The menu keeps the last battery reading during the current app session and displays its age when the camera stops replying. A fresh reading of 20% or less shows **Low battery** unless the camera is charging. A live window retries twice if the connection drops or decoded video stalls. Close or minimize the window to stop streaming.

### Open recordings from the menu

If you serve your NixOS recording folder privately through Tailscale Serve, paste its HTTPS URL into **Private recordings URL** in Settings. **Open Recordings** opens that URL in your browser. The MP4s stay on the NixOS recorder.

### Configuration files

Tapo Menu stores settings and local access tokens in private files under `~/Library/Application Support/Tapo Menu`. Existing camera IDs and addresses continue to work. A settings file can include optional display names and a recordings URL.

```json
{
  "cameras": [
    { "id": "1", "host": "192.168.50.20", "name": "Front Door" }
  ],
  "recordingsURL": "https://recorder.example.ts.net/tapo/"
}
```

Keep `config.json` readable only by your user with mode `0600`. Choose **Sign In…** or **Sign In Again…** from the menu to refresh the tokens after changing addresses, or if the cameras reject the saved tokens. If a battery reading or live feed is slow to appear, walk past the camera to wake it and try again.
