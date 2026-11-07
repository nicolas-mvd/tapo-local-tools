{ ... }:

{
  name = "tapo-recorder-service";

  nodes.machine =
    { pkgs, recorderModule, recorderPackage, ... }:
    let
      fakeCamera = pkgs.writeText "fake-tapo-camera.py" ''
        import json
        from pathlib import Path
        import socket

        alarm_path = Path("/run/test-tapo-alarm")
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.bind(("10.42.10.101", 20004))
            while True:
                _, client = sock.recvfrom(16384)
                alarm = int(alarm_path.read_text()) if alarm_path.exists() else 0
                reply = {"result": {"device_type": "SMART.IPCAMERA", "last_alarm_time": alarm}}
                sock.sendto(bytes(16) + json.dumps(reply).encode(), client)
      '';
    in
    {
      imports = [ recorderModule ];
      services.tapoMotionRecorder = {
        enable = true;
        package = recorderPackage;
        cameras = [ { id = "1"; host = "10.42.10.101"; name = "Fixture camera"; } ];
        minFreeBytes = 0;
      };

      environment.etc."tapo-recorder/camera-tokens.json" = {
        mode = "0600";
        text = builtins.toJSON {
          type = "tapo-lat/v1";
          cameras.camera1 = { host = "10.42.10.101"; lat = "fixture"; };
        };
      };
      environment.systemPackages = [ pkgs.jq ];
      systemd.services.fake-tapo-camera = {
        wantedBy = [ "multi-user.target" ];
        before = [ "tapo-motion-recorder.service" ];
        path = [ pkgs.iproute2 ];
        preStart = "ip address replace 10.42.10.101/32 dev lo";
        serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 ${fakeCamera}";
      };
    };

  testScript = ''
    start_all()
    machine.wait_for_unit("tapo-motion-recorder.service")
    machine.succeed("systemctl show -p StatusText --value tapo-motion-recorder | grep -F 'motion watcher ready'")
    machine.succeed("test -f /var/lib/tapo-recorder/clips/index.html")
    status = "/var/lib/tapo-recorder/status.json"
    machine.wait_until_succeeds(f"jq -e '.cameras[0].lastReplyAt != null' {status}")
    machine.succeed("date +%s > /run/test-tapo-alarm.next; mv /run/test-tapo-alarm.next /run/test-tapo-alarm")
    machine.wait_until_succeeds(f"jq -e '.cameras[0].lastAlarmAt != null and .cameras[0].lastError != null' {status}")
    machine.succeed("systemctl stop fake-tapo-camera.service; systemctl is-active --quiet tapo-motion-recorder")
    machine.succeed("systemctl stop tapo-motion-recorder.service")
  '';
}
