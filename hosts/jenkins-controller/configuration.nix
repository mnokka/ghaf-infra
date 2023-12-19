# SPDX-FileCopyrightText: 2023 Technology Innovation Institute (TII)
#
# SPDX-License-Identifier: Apache-2.0
{
  pkgs,
  self,
  lib,
  ...
}: let
  post-build-hook = pkgs.writeScript "upload" ''
    set -eu
    set -f # disable globbing
    export IFS=' '

    echo "Uploading paths" $OUT_PATHS
    exec nix --extra-experimental-features nix-command copy --to 'http://localhost:8080?secret-key=/etc/secrets/nix-signing-key&compression=zstd' $OUT_PATHS
  '';
in {
  imports = [
    ../azure-common-2.nix
    ../azure-scratch-store-common.nix
    self.nixosModules.service-openssh
  ];

  # Configure /var/lib/jenkins in /etc/fstab.
  # Due to an implicit RequiresMountsFor=$state-dir, systemd
  # will block starting the service until this mounted.
  fileSystems."/var/lib/jenkins" = {
    device = "/dev/disk/by-lun/10";
    fsType = "ext4";
    options = [
      "x-systemd.makefs"
      "x-systemd.growfs"
    ];
  };

  services.jenkins = {
    enable = true;
    listenAddress = "localhost";
    port = 8080;
    withCLI = true;
  };

  # set StateDirectory=jenkins, so state volume has the right permissions
  # and we wait on the mountpoint to appear.
  # https://github.com/NixOS/nixpkgs/pull/272679
  systemd.services.jenkins.serviceConfig.StateDirectory = "jenkins";

  # Define a fetch-remote-build-ssh-key unit populating
  # /etc/secrets/remote-build-ssh-key from Azure Key Vault.
  # Make it before and requiredBy nix-daemon.service.
  systemd.services.fetch-build-ssh-key = {
    after = ["network.target"];
    before = ["nix-daemon.service"];
    requires = ["network.target"];
    wantedBy = [
      # nix-daemon is socket-activated, and having it here should be sufficient
      # to fetch the keys whenever a jenkins job connects to the daemon first.
      # This means this service will effectively get socket-activated on the
      # first nix-daemon connection.
      "nix-daemon.service"
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      EnvironmentFile = "/var/lib/fetch-build-ssh-key/env";
      Restart = "on-failure";
    };
    script = let
      get-secret = pkgs.writers.writePython3 "get-secret" {
        libraries = with pkgs.python3.pkgs; [azure-keyvault-secrets azure-identity];
      } (builtins.readFile ./get_secret.py);
    in ''
      umask 077
      mkdir -p /etc/secrets/
      ${get-secret} > /etc/secrets/remote-build-ssh-key
    '';
  };

  # Define a fetch-binary-cache-signing-key unit populating
  # /etc/secrets/nix-signing-key from Azure Key Vault.
  # Make it before and requiredBy nix-daemon.service.
  systemd.services.fetch-binary-cache-signing-key = {
    after = ["network.target"];
    before = ["nix-daemon.service"];
    requires = ["network.target"];
    wantedBy = [
      # nix-daemon is socket-activated, and having it here should be sufficient
      # to fetch the keys whenever a jenkins job connects to the daemon first.
      # This means this service will effectively get socket-activated on the
      # first nix-daemon connection.
      "nix-daemon.service"
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      EnvironmentFile = "/var/lib/fetch-binary-cache-signing-key/env";
      Restart = "on-failure";
    };
    script = let
      get-secret = pkgs.writers.writePython3 "get-secret" {
        libraries = with pkgs.python3.pkgs; [azure-keyvault-secrets azure-identity];
      } (builtins.readFile ./get_secret.py);
    in ''
      umask 077
      mkdir -p /etc/secrets/
      ${get-secret} > /etc/secrets/nix-signing-key
    '';
  };

  # Run a read-write HTTP webserver proxying to the "binary-cache-v1" storage
  # This is used by the post-build-hook to upload to the binary cache.
  # This relies on IAM to grant access to the storage container.
  systemd.services.rclone-http = {
    after = ["network.target"];
    requires = ["network.target"];
    wantedBy = ["multi-user.target"];
    serviceConfig = {
      Type = "notify";
      Restart = "always";
      RestartSec = 2;
      DynamicUser = true;
      RuntimeDirectory = "rclone-http";
      ExecStart =
        "${pkgs.rclone}/bin/rclone "
        + "serve webdav "
        + "--azureblob-env-auth "
        + "--addr localhost:8080 "
        + ":azureblob:binary-cache-v1";
      EnvironmentFile = "/var/lib/rclone-http/env";
    };
  };

  # Configure Nix to use this as a substitutor, and the public key used for signing.
  nix.settings.trusted-public-keys = [
    "ghaf-jenkins:5OXpzoevBwH4sBR0S0HaIQCik2adrOrGawIXO+WADCk="
  ];
  nix.settings.substituters = [
    "http://localhost:8080"
  ];
  nix.extraOptions = ''
    builders-use-substitutes = true
    builders = @/etc/nix/machines
    # Build remote by default
    max-jobs = 0
    post-build-hook = ${post-build-hook}
  '';

  # TODO: deploy reverse proxy, sort out authentication (SSO?)

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  system.stateVersion = "23.05";
}
