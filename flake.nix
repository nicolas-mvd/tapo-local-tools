{
  description = "Local Tapo motion recorder for NixOS";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/c56a87d8e41ce69bd2af57eb35dcc117a9dfca33";

  outputs =
    { self, nixpkgs }:
    let
      eachSystem = nixpkgs.lib.genAttrs [
        "x86_64-linux"
        "aarch64-linux"
      ];
    in
    {
      packages = eachSystem (system: {
        default = nixpkgs.legacyPackages.${system}.callPackage ./package.nix { };
      });

      apps = eachSystem (
        system:
        let
          app = executable: description: {
            type = "app";
            program = "${self.packages.${system}.default}/bin/${executable}";
            meta = { inherit description; };
          };
          installer = app "tapo-install" "Install the local Tapo motion recorder service";
        in
        {
          default = installer;
          install = installer;
          tapo-login = app "tapo-login" "Refresh local camera tokens through TP-Link sign-in";
          refresh = app "tapo-refresh" "Refresh tokens for an existing user service";
          status = app "tapo-status" "Show recorder and camera health";
          doctor = app "tapo-doctor" "Check camera discovery, video, and recording storage";
        }
      );

      checks = eachSystem (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          recorder-service = pkgs.testers.runNixOSTest {
            imports = [ ./test/nixos-service.nix ];
            requiredFeatures.kvm = system == "x86_64-linux";
            qemu.forceAccel = system == "x86_64-linux";
            node.specialArgs = {
              recorderModule = self.nixosModules.default;
              recorderPackage = self.packages.${system}.default;
            };
          };
        }
      );

      nixosModules.default = import ./deploy/nixos-recorder.nix;
    };
}
