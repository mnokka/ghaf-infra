# SPDX-FileCopyrightText: 2023 Technology Innovation Institute (TII)
#
# SPDX-License-Identifier: Apache-2.0
#
# Profile to import for Azure VMs. Imports azure-common.nix from nixpkgs,
# and configures cloud-init.
{
  modulesPath,
  pkgs,
  ...
}: {
  imports = [
    "${modulesPath}/virtualisation/azure-config.nix"
  ];

  nix = {
    settings = {
      # Enable flakes and 'nix' command
      experimental-features = "nix-command flakes";
    };
  };

  # Enable azure agent
  virtualisation.azure.agent.enable = true;

  # enable cloud-init, so instance metadata is set accordingly and we can use
  # cloud-config for ssh key management.
  services.cloud-init.enable = true;
  # FUTUREWORK: below is a hack to make cloud-init usable with azure
  # agent (waagent). The usage of azure agent together with cloud-init
  # needs to be properly done later, perhaps by using the
  # azure-scatch-store-common.nix or something similar.
  systemd.services.cloud-config.serviceConfig = {
    Restart = "on-failure";
  };

  # Use systemd-networkd for network configuration.
  services.cloud-init.network.enable = true;
  networking.useDHCP = false;
  networking.useNetworkd = true;
  # FUTUREWORK: Ideally, we'd keep systemd-resolved disabled too,
  # but the way nixpkgs configures cloud-init prevents it from picking up DNS
  # settings from elsewhere.
  # services.resolved.enable = false;

  # List packages installed in system profile
  environment.systemPackages = with pkgs; [
    git
    vim
    htop
  ];
}
