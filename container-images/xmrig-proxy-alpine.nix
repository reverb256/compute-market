{
  pkgs,
  lib,
  ...
}:
let
  version = "6.25.0";
  xmrigSrc = pkgs.fetchurl {
    url = "https://github.com/kryptex-miners-org/kryptex-miners/releases/download/xmrig-6-25-0/xmrig-${version}-linux-static-x64.tar.gz";
    hash = "sha256-BrZTSVVw3cPcrFB8TeTdR6pxdEyyw/Li00+c7N+Oh7M=";
  };
in
pkgs.dockerTools.buildLayeredImage {
  name = "xmrig-proxy-alpine";
  tag = version;
  contents = [
    pkgs.dockerTools.caCertificates
  ];
  extraCommands = ''
    mkdir -p usr/local/bin etc/ssl/certs
    tar -xzf ${xmrigSrc}
    cp xmrig usr/local/bin/xmrig-proxy
    chmod +x usr/local/bin/xmrig-proxy
  '';
  config = {
    Entrypoint = [ "/usr/local/bin/xmrig-proxy" ];
    WorkingDir = "/";
    Env = [
      "SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt"
    ];
  };
}
