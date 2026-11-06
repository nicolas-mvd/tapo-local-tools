{ config, lib, pkgs, ... }:

let
  cfg = config.services.tapoMotionRecorder;
  stateDirectory = "/var/lib/tapo-recorder";
  configFile = "tapo-recorder/config.json";
  octet = "([0-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-5])";
  privateIPv4 = "(10\\.${octet}|172\\.(1[6-9]|2[0-9]|3[01])|192\\.168)\\.${octet}\\.${octet}";
  cameraType = lib.types.submodule {
    options = {
      id = lib.mkOption {
        type = lib.types.strMatching "[A-Za-z0-9][A-Za-z0-9-]{0,23}";
        example = "1";
        description = "Camera ID used in filenames and the camera token file.";
      };
      host = lib.mkOption {
        type = lib.types.strMatching privateIPv4;
        example = "10.42.10.101";
        description = "Private IPv4 address of the camera, reachable from this machine.";
      };
    };
  };
in
{
  options.services.tapoMotionRecorder = {
    enable = lib.mkEnableOption "local recording of Tapo camera motion clips";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ../package.nix { };
      defaultText = lib.literalExpression "pkgs.callPackage ../package.nix { }";
      description = "Package providing the Tapo motion recorder and credential installer.";
    };

    cameras = lib.mkOption {
      type = lib.types.listOf cameraType;
      default = [ ];
      example = lib.literalExpression ''
        [
          { id = "1"; host = "10.42.10.101"; }
          { id = "2"; host = "10.42.10.102"; }
        ]
      '';
      description = "Cameras to record, with IDs and addresses matching the token file.";
    };

    tokenFile = lib.mkOption {
      type = lib.types.str;
      default = "/etc/tapo-recorder/camera-tokens.json";
      description = ''
        Absolute runtime path to the root-readable camera token file. Use a
        quoted string for the path and keep the file outside the Nix store.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.cameras != [ ] && builtins.length cfg.cameras <= 16;
        message = "services.tapoMotionRecorder.cameras must contain between 1 and 16 cameras.";
      }
      {
        assertion = lib.all (field: lib.allUnique (map (camera: camera.${field}) cfg.cameras)) [ "id" "host" ];
        message = "services.tapoMotionRecorder.cameras must have unique IDs and IP addresses.";
      }
      {
        assertion =
          builtins.match "/[A-Za-z0-9_./-]+" cfg.tokenFile != null
          && !lib.hasInfix "/../" cfg.tokenFile
          && !lib.hasSuffix "/.." cfg.tokenFile
          && cfg.tokenFile != builtins.storeDir
          && !lib.hasPrefix "${builtins.storeDir}/" cfg.tokenFile;
        message = "services.tapoMotionRecorder.tokenFile must be an absolute runtime path outside the Nix store.";
      }
    ];

    environment.systemPackages = [ cfg.package ];
    environment.etc.${configFile}.text = builtins.toJSON {
      inherit (cfg) cameras;
      recordingsDir = "${stateDirectory}/clips";
    };

    users.groups.tapo-recorder = { };
    users.users.tapo-recorder = {
      isSystemUser = true;
      group = "tapo-recorder";
      home = stateDirectory;
    };

    systemd.services.tapo-motion-recorder = {
      description = "Tapo camera motion recorder";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      restartTriggers = [ config.environment.etc.${configFile}.source ];
      environment = {
        HOME = stateDirectory;
        TAPO_CONFIG = "/etc/${configFile}";
      };
      unitConfig.ConditionPathExists = cfg.tokenFile;
      serviceConfig = {
        Type = "simple";
        ExecStart = lib.getExe cfg.package;
        User = "tapo-recorder";
        Group = "tapo-recorder";
        StateDirectory = "tapo-recorder";
        StateDirectoryMode = "0700";
        UMask = "0077";
        LoadCredential = "camera-tokens.json:${cfg.tokenFile}";
        Restart = "on-failure";
        RestartSec = "15s";
        KillMode = "mixed";
        TimeoutStopSec = "45s";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
      };
    };
  };
}
