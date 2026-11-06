# Tapo motion recorder and Tapo Menu

Two tools for TP-Link Tapo cameras, tested with the battery-powered C425.

- **[Motion recorder for NixOS](#motion-recorder-for-nixos)** runs in the background. When a camera reports motion, it opens the camera stream and saves a local MP4.
- **[Tapo Menu for macOS](#tapo-menu-for-macos)** shows two cameras' battery percentages in the menu bar and opens live video when you select a camera.

Both tools use the camera owner's TP-Link account to obtain local access tokens. The TP-Link app is optional for day-to-day use. After sign-in, the tools reach the cameras over your network. Both need access to the cameras' private IPv4 addresses on UDP 20004 for discovery and TCP 8800 for video.

## Motion recorder for NixOS

Run the installer on the NixOS machine that will store the clips. The flake supports x86-64 and ARM64 Linux. Sign in to NixOS as the user who will own the clips, then run this from a Git checkout of the repository.

```sh
nix --extra-experimental-features 'nix-command flakes' run .#install
```

On a fresh install, enter the two camera IP addresses, then the owner TP-Link email and password. Enter the verification code if TP-Link asks for one. The installer checks that one frame decodes from each camera and starts a systemd user service. It may ask for your NixOS sudo password to let the service start at boot and run after logout. Pass `-- --no-linger` to skip enabling lingering.

Run the same command again to refresh the camera tokens. The installer reuses the saved camera addresses. To supply or change them, pass `-- --camera-1 CAMERA_1_IP --camera-2 CAMERA_2_IP` with your own addresses.

### Installing with an AI agent

If you're an AI agent helping with setup, confirm the recording folder before running the installer. Ask “Where on the NixOS machine should the recordings go? Is `~/.local/share/tapo-motion-recorder/clips` OK?” If `XDG_DATA_HOME` is already set, use it in place of `~/.local/share` when stating the default.

If the user chooses a different base directory, confirm the full clip path with them. Use an absolute, writable path without spaces.

```sh
XDG_DATA_HOME=/absolute/path/to/data nix --extra-experimental-features 'nix-command flakes' run .#install
```

This example saves clips in `/absolute/path/to/data/tapo-motion-recorder/clips`. Use the same base directory when rerunning the installer, including when refreshing camera tokens.

Run the installer in an interactive terminal on NixOS. Have the user enter their TP-Link credentials and any verification code directly in that terminal. After setup, tell them the clip folder printed by the installer.

### Find and watch clips

Walk past a camera to trigger a recording. The recorder can save clips without a microSD card or a hub. Each MP4 contains up to 15 seconds of video after the stream starts, with no audio. Clips stay in your local folder until you delete them.

```sh
ls -lh "${XDG_DATA_HOME:-$HOME/.local/share}/tapo-motion-recorder/clips"
systemctl --user status tapo-motion-recorder.service
journalctl --user -u tapo-motion-recorder.service -f
```

The recorder checks camera alarm metadata every 250 milliseconds by default. A sleeping camera can take longer to start video. To change the interval, set `pollIntervalMs` in `current/config.json` under `${XDG_CONFIG_HOME:-$HOME/.config}/tapo-motion-recorder` and restart the service. The supported range is 100 to 60,000 milliseconds. Reinstalling resets the interval.

To stop the service and disable automatic startup, run `systemctl --user disable --now tapo-motion-recorder.service`.

### Use cameras across a tailnet

If NixOS is outside the camera LAN, use an always-on device on the camera LAN as a Tailscale subnet router. [Tailscale subnet router setup](https://tailscale.com/docs/features/subnet-routers/how-to/setup)

1. Enable IP forwarding on the subnet router if it runs Linux. Advertise a route for each camera. Replace the sample IPs with your own and include any routes the device already advertises.

   ```sh
   sudo tailscale set --advertise-routes=192.168.50.20/32,192.168.50.21/32
   ```

2. Approve the routes in the Tailscale admin console.
3. On NixOS, run `sudo tailscale set --accept-routes`. If you restrict access through your tailnet policy, allow NixOS to reach UDP 20004 and TCP 8800 on both cameras.

To watch completed clips from another permitted device on the tailnet, run Tailscale Serve on NixOS and open the URL it prints. If you chose a custom location, use the clip folder printed by the installer in the command below. The files stay on NixOS. [Tailscale Serve reference](https://tailscale.com/docs/reference/tailscale-cli/serve)

```sh
sudo tailscale serve --bg --set-path=/tapo/ "${XDG_DATA_HOME:-$HOME/.local/share}/tapo-motion-recorder/clips"
```

## Tapo Menu for macOS

Requires macOS 13 or later, the Xcode Command Line Tools, Node.js 22 or 24 with npm, and FFmpeg. Build and open the app from the repository root.

```sh
bash macos/build.sh
open "$HOME/Applications/Tapo Menu.app"
```

Click the camera icon in the menu bar. Choose **Set Up and Sign In…** and enter the two camera IP addresses and the owner TP-Link credentials in the Terminal window. The menu shows **Cam 1** and **Cam 2** with their battery percentages when available. Select either row to watch its live feed.

Battery cameras may take several seconds to start video. If the connection ends, click **Retry**. Closing or minimizing the window stops the stream. Tapo Menu displays video without saving it.

See the [macOS setup notes](macos/README.md) for changing camera addresses and refreshing tokens.

## License

The project is licensed under the [GNU General Public License version 3 only](LICENSE) (`GPL-3.0-only`). See the [third-party notice](THIRD-PARTY-NOTICES) for the MIT-licensed code used in the media adapter.
