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
  # the kernel assigns it on its own; no IPv4, no DHCP. The link can come up
  # with NO-CARRIER (observed at boot on a MacBookAir9,1 under t2bce), and
  # then never gets a link-local address; rebinding cdc_ncm fixes it, which
  # is also what t2linux's Fedora package does before starting the daemon.
  linkUp = pkgs.writeShellApplication {
    name = "t2-touchid-link-up";
    runtimeInputs = [pkgs.iproute2];
    text = ''
      find_dev() {
        local dev usb
        for dev in /sys/class/net/*; do
          usb=$(readlink -f "$dev/device/..")
          [[ -r $usb/idVendor && -r $usb/idProduct ]] || continue
          [[ $(<"$usb/idVendor") == ${ncmVendor} && $(<"$usb/idProduct") == ${ncmProduct} ]] || continue
          echo "''${dev##*/}"
          return 0
        done
        return 1
      }

      # Brings the link up, then waits up to $1 tenths of a second for carrier.
      up_with_carrier() {
        local dev
        for ((i = 0; i < $1; i++)); do
          if dev=$(find_dev); then
            ip link set dev "$dev" up
            [[ $(<"/sys/class/net/$dev/carrier") == 1 ]] 2>/dev/null && return 0
          fi
          sleep 0.1
        done
        return 1
      }

      if ! dev=$(find_dev); then
        echo "t2-touchid: no Apple ${ncmVendor}:${ncmProduct} CDC-NCM interface found" >&2
        exit 1
      fi
      up_with_carrier 30 && exit 0

      echo "t2-touchid: $dev has no carrier; rebinding cdc_ncm" >&2
      intf=$(basename "$(readlink -f "/sys/class/net/$dev/device")")
      echo -n "$intf" > /sys/bus/usb/drivers/cdc_ncm/unbind
      sleep 1
      echo -n "$intf" > /sys/bus/usb/drivers/cdc_ncm/bind
      up_with_carrier 100 && exit 0

      echo "t2-touchid: CDC-NCM link has no carrier after rebind" >&2
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
        environment = {
          FP_VIRTUAL_DEVICE_STORAGE = socket;
          # libfprint simulates sensor heating and, by default, disables a
          # device after 3 minutes of continuous scanning ("Device disabled to
          # prevent overheating"). A lock screen that keeps a verify running
          # (hyprlock's native fingerprint) hits that after 3 minutes locked,
          # reports verify-disconnected and stops offering the finger. The
          # real sensor is the T2's, which has no such limit (macOS keeps it
          # armed at its own lock screen), so turn the simulation off; any
          # negative value means disabled.
          FP_VIRTUAL_DEVICE_HOT_SECONDS = "-1";
        };
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
