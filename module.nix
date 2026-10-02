# NixOS module for t2-touchid. Mirrors upstream's systemd integration
# (t2-services/t2-touchid/integration) with NixOS-native units, plus the one
# thing upstream leaves to the distro: bringing the T2's CDC-NCM link up so
# the sensor is reachable over IPv6 link-local.
{self}: {
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.t2-touchid;

  # fprintd and the bridge meet on this socket, so both units must declare the
  # same runtime directory. Whoever can write to the socket authenticates, so
  # it stays root-only.
  runtimeDirectory = "t2-touchid";
  socket = "/run/${runtimeDirectory}/fprint.sock";
  runtimeDirectoryConfig = {
    RuntimeDirectory = runtimeDirectory;
    RuntimeDirectoryMode = "0700";
    RuntimeDirectoryPreserve = true;
  };

  # The T2 exposes its BridgeXPC services on a USB CDC-NCM function with this
  # fixed vendor/product pair (and fixed MAC). The daemon discovers the
  # interface the same way.
  ncmVendor = "05ac";
  ncmProduct = "8233";
  ncmMac = "ac:de:48:00:11:22";

  # Brings the NCM link admin-up. IPv6 link-local is all the bridge needs and
  # the kernel assigns it on its own; no IPv4, no DHCP.
  linkUp = pkgs.writeShellApplication {
    name = "t2-touchid-link-up";
    runtimeInputs = [pkgs.iproute2];
    text = ''
      for dev in /sys/class/net/*; do
        usb=$(readlink -f "$dev/device/..")
        [[ -r $usb/idVendor && -r $usb/idProduct ]] || continue
        [[ $(<"$usb/idVendor") == ${ncmVendor} && $(<"$usb/idProduct") == ${ncmProduct} ]] || continue
        ip link set dev "''${dev##*/}" up
        exit 0
      done
      echo "t2-touchid: no Apple ${ncmVendor}:${ncmProduct} CDC-NCM interface found" >&2
      exit 1
    '';
  };
in {
  options.services.t2-touchid = {
    enable = lib.mkEnableOption ''
      the Apple T2 Touch ID bridge for fprintd. Enables fprintd, which in turn
      turns on `fprintAuth` for every PAM service by default. Fingers must be
      enrolled under macOS; this only binds them to a Linux account'';

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.t2-touchid;
      defaultText = lib.literalExpression "t2-touchid-nix.packages.\${system}.t2-touchid";
      description = "The t2-touchid package to use.";
    };

    bindUser = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "alice";
      description = ''
        Linux account the macOS-enrolled fingers are bound to automatically on
        every start (the daemon runs `fprintd-enroll` for any identity fprintd
        does not know yet; no touch is needed). Binding only records ownership,
        the finger is still required at every login. With `null`, bind by hand
        with `fprintd-enroll -f <finger>` and one touch.
      '';
    };

    macosUid = lib.mkOption {
      type = lib.types.either (lib.types.enum ["auto"]) lib.types.ints.positive;
      default = "auto";
      example = 502;
      description = ''
        The macOS user id whose enrolled fingers are verified against. `auto`
        probes the usual macOS ids (501 and up) for one with a finger enrolled;
        set a number only when several macOS users have Touch ID.
      '';
    };

    manageLink = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Bring the T2's CDC-NCM interface up (IPv6 link-local only) at boot and
        whenever it reappears, and keep NetworkManager from managing it. Turn
        off if the interface is already configured elsewhere.
      '';
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      assertions = [
        {
          assertion = pkgs.stdenv.hostPlatform.isx86_64;
          message = "services.t2-touchid only applies to x86_64 T2 Macs.";
        }
      ];

      services.fprintd.enable = true;
      services.dbus.packages = [cfg.package];

      systemd.services.t2-touchid = {
        description = "Apple T2 Touch ID bridge for fprintd";
        wantedBy = ["multi-user.target"];
        # Automatic binding shells out to fprintd-enroll.
        path = [config.services.fprintd.package];
        serviceConfig =
          {
            ExecStartPre = lib.mkIf cfg.manageLink "-${lib.getExe linkUp}";
            ExecStart = lib.escapeShellArgs [
              (lib.getExe cfg.package)
              "--socket"
              socket
              "--uid"
              (toString cfg.macosUid)
              # Plain verify; every other flag bit needs state only macOS has.
              "--flags"
              "0"
              "--bind-user"
              (
                if cfg.bindUser == null
                then "none"
                else cfg.bindUser
              )
            ];
            Restart = "on-failure";
            RestartSec = 5;
            NoNewPrivileges = true;
            ProtectSystem = "strict";
            ProtectHome = true;
            PrivateTmp = true;
          }
          // runtimeDirectoryConfig;
      };

      # Point fprintd at libfprint's virtual storage device, which the bridge
      # feeds with the T2's verdicts. Tie fprintd to the bridge: with the
      # bridge stopped the virtual device would still be advertised and every
      # sudo would wait for a finger nobody can report; tied together, a
      # stopped bridge means no reader and PAM falls through to the password.
      systemd.services.fprintd = {
        requires = ["t2-touchid.service"];
        after = ["t2-touchid.service"];
        environment.FP_VIRTUAL_DEVICE_STORAGE = socket;
        serviceConfig =
          {
            ReadWritePaths = ["/run/${runtimeDirectory}"];
          }
          // runtimeDirectoryConfig;
      };
    }

    (lib.mkIf cfg.manageLink {
      # Coldplug and every re-add (e.g. a T2 driver reload around suspend)
      # leave the netdev admin-down.
      services.udev.extraRules = ''
        ACTION=="add", SUBSYSTEM=="net", ATTRS{idVendor}=="${ncmVendor}", ATTRS{idProduct}=="${ncmProduct}", RUN+="${pkgs.iproute2}/bin/ip link set dev $name up"
      '';

      # Otherwise NM's catch-all "Wired connection" profile retries DHCP on
      # the link forever.
      networking.networkmanager.unmanaged = ["mac:${ncmMac}"];
    })
  ]);
}
