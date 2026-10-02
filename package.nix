# t2-touchid: bridges the Apple T2 Touch ID sensor to stock fprintd through
# libfprint's virtual storage device. Upstream lives in the KaiT2en-Fedora
# monorepo; the crate pulls two in-tree path dependencies (t2-biometrickit,
# t2-bridgexpc), so the whole monorepo is fetched and the build is pointed at
# the crate's subdirectory.
{
  lib,
  rustPlatform,
  fetchFromGitHub,
}: let
  crate = "t2-services/t2-touchid";
in
  rustPlatform.buildRustPackage {
    pname = "t2-touchid";
    version = "0.1.0-unstable-2026-10-02";

    src = fetchFromGitHub {
      owner = "kaiT2en";
      repo = "KaiT2en-Fedora";
      rev = "cf6ed25149f17c67c08d97cb1f8ccef5dedca220";
      hash = "sha256-xZt5r3toAZtfZcs6CIy0QLl0xjKkJPCKUlZfmULzQpk=";
    };

    cargoRoot = crate;
    buildAndTestSubdir = crate;
    cargoHash = "sha256-AEIkigG0aFT5UK3RuNef6jThU1ygv/jYRJnWS+ARWys=";

    # Upstream's integration files, for non-NixOS consumers. The NixOS module
    # declares its own units rather than using these.
    postInstall = ''
      install -Dm444 -t $out/share/dbus-1/system.d \
        ${crate}/integration/dbus/org.kait2en.TouchId.conf
      install -Dm444 -t $out/share/doc/t2-touchid \
        ${crate}/README.md ${crate}/config/t2-touchid.conf
      mkdir -p $out/lib/systemd/system
      substitute ${crate}/integration/systemd/kait2en-t2-touchid.service \
        $out/lib/systemd/system/kait2en-t2-touchid.service \
        --replace-fail @BINDIR@ $out/bin
      install -Dm444 ${crate}/integration/fprintd/fprintd-kait2en-t2-touchid.conf \
        $out/lib/systemd/system/fprintd.service.d/kait2en-t2-touchid.conf
    '';

    meta = {
      description = "Apple T2 Touch ID bridge for fprintd";
      homepage = "https://github.com/kaiT2en/KaiT2en-Fedora/tree/main/t2-services/t2-touchid";
      license = lib.licenses.gpl3Plus;
      mainProgram = "t2-touchid";
      platforms = ["x86_64-linux"];
    };
  }
