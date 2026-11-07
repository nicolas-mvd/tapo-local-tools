# Tapo motion recorder and Tapo Menu

Two tools for TP-Link Tapo cameras, tested with the battery-powered C425.

- **[Motion recorder for NixOS](#motion-recorder-for-nixos)** runs in the background. When a camera reports motion, it opens the camera stream and saves a local MP4.
- **[Tapo Menu for macOS](#tapo-menu-for-macos)** shows camera battery levels in the menu bar, opens live video, and links to the recorder's clip timeline.

Both tools use the camera owner's TP-Link account to obtain local access tokens. The TP-Link app is optional for day-to-day use. After sign-in, the tools reach the cameras over your network. Both need access to the cameras' private IPv4 addresses on UDP 20004 for discovery and TCP 8800 for video.

## Motion recorder for NixOS

Run the installer on the NixOS machine that will store the clips. The flake supports x86-64 and ARM64 Linux. Sign in to NixOS as the user who will own the clips, then run this from a Git checkout of the repository.

```sh
nix --extra-experimental-features 'nix-command flakes' run .#install
```

On a fresh install, enter the IP addresses and names of one to sixteen cameras, then choose the local folder for clips. Sign in with the owner TP-Link email and password, and enter the verification code if TP-Link asks for one. The installer checks that a frame decodes from each camera and waits for the recording folder and motion watcher to be ready. It may ask for your NixOS sudo password to let the service start at boot and run after logout. Pass `-- --no-linger` to skip enabling lingering.

To supply settings on the command line, use `--camera ID IPV4 NAME` once per camera and `--recordings-dir PATH` for the exact destination. The camera flags replace the saved list. Reuse each camera ID to keep its clips grouped together. The `--camera-1` and `--camera-2` shortcuts still update those individual addresses.

```sh
nix --extra-experimental-features 'nix-command flakes' run .#install -- \
  --camera porch 192.168.50.20 "Front porch" \
  --recordings-dir "$HOME/Camera Recordings"
```

Run the installer again to update settings. It keeps your saved configuration unless you specify an override. To refresh tokens with the same settings, use `nix run .#refresh` from the checkout, adding the experimental-features flags if needed.

### Installing with an AI agent

If you're an AI agent helping with setup, confirm the recording folder before running the installer. Ask “Where on the NixOS machine should the recordings go? Is `~/.local/share/tapo-motion-recorder/clips` OK?” If `XDG_DATA_HOME` is set, use it in place of `~/.local/share` when stating the default. Pass the confirmed absolute path with `--recordings-dir`.

Run the installer in an interactive terminal on NixOS. Have the user enter their TP-Link credentials and any verification code directly in that terminal. After setup, tell them the clip folder printed by the installer.

### Find and watch clips

Walk past a camera to trigger a recording. The recorder can save clips without a microSD card or a hub. Each MP4 contains up to 15 seconds of video by default, starting when the camera stream is ready, with no audio. Open `index.html` in the recording folder to browse clips by camera and date. Thumbnails appear as the recorder processes them.

Use a dedicated folder with a writable parent on the same filesystem. For a separate drive, choose a subfolder inside the mount. By default, clips stay until you delete them. Re-run the installer with `--retention-days` or `--max-storage-mib` to remove the oldest recorder clips automatically. Use `0` to turn either limit off. The recorder logs a warning and pauses new clips below 256 MiB of free space by default. Use `--min-free-mib` to change the reserve and `--clip-seconds` to set the clip length from 1 to 120 seconds.

### Check recorder health

Use the flake's status command to see each camera's last reply, last saved clip, and latest error. The diagnostic command checks storage, discovery, and whether it can decode a frame from each camera.

```sh
nix run .#status
nix run .#doctor
systemctl --user status tapo-motion-recorder.service
journalctl --user -u tapo-motion-recorder.service -f
```

The recorder checks camera alarm metadata every 250 milliseconds by default. A sleeping camera can take longer to start video. To change the interval, set `pollIntervalMs` in `current/config.json` under `${XDG_CONFIG_HOME:-$HOME/.config}/tapo-motion-recorder` and restart the service. The supported range is 100 to 60,000 milliseconds.

To stop the service and disable automatic startup, run `systemctl --user disable --now tapo-motion-recorder.service`.

### Use cameras across a tailnet

If NixOS is outside the camera LAN, use an always-on device on the camera LAN as a Tailscale subnet router. [Tailscale subnet router setup](https://tailscale.com/docs/features/subnet-routers/how-to/setup)

1. Enable IP forwarding on the subnet router if it runs Linux. Advertise a route for each camera. Replace the sample IPs with your own and include any routes the device already advertises.

   ```sh
   sudo tailscale set --advertise-routes=192.168.50.20/32,192.168.50.21/32
   ```

2. Approve the routes in the Tailscale admin console.
3. On NixOS, run `sudo tailscale set --accept-routes`. If you restrict access through your tailnet policy, allow NixOS to reach UDP 20004 and TCP 8800 on both cameras.

To watch completed clips from another permitted device on the tailnet, run Tailscale Serve on NixOS and open the URL it prints. Substitute the dedicated recording folder printed by the installer. Serve can read files placed in that folder, so keep credentials, unrelated files, and symlinks elsewhere. The MP4s and timeline stay on NixOS. [Tailscale Serve reference](https://tailscale.com/docs/reference/tailscale-cli/serve)

```sh
sudo tailscale serve --bg --set-path=/tapo/ "/absolute/path/to/recordings"
```

## Tapo Menu for macOS

Requires macOS 13 or later, the Xcode Command Line Tools, Node.js 22 or 24 with npm, and FFmpeg. Build and open the app from the repository root.

```sh
bash macos/build.sh
open "$HOME/Applications/Tapo Menu.app"
```

Click the camera icon in the menu bar. Add one to sixteen named cameras in **Settings…**, then select a camera to sign in and watch live video. Enter the owner TP-Link credentials directly in the Terminal window. The menu shows the latest battery readings, when they were last seen, and which cameras are low on battery.

Battery cameras may take several seconds to start video. If a running preview stalls, Tapo Menu tries to reconnect. Click **Retry** if it still needs help. Closing or minimizing the window stops the stream. Tapo Menu displays video without saving it.

To browse the NixOS timeline from the menu, paste its HTTPS address into **Settings…**, then choose **Open Recordings**.

See the [macOS setup notes](macos/README.md) for changing camera addresses and refreshing tokens.

## Checks

GitHub Actions runs synthetic motion and video tests, builds the NixOS package on x86-64 and ARM64, runs a NixOS service test in a VM, and builds the Mac app. The automated checks use test fixtures without a TP-Link account or live cameras.

## License

The project is licensed under the [GNU General Public License version 3 only](LICENSE) (`GPL-3.0-only`). See the [third-party notice](THIRD-PARTY-NOTICES) for the MIT-licensed code used in the media adapter.
