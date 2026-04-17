{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  glibc,
  zlib,
  openssl,
  libuv,
  steam-run,
}:
stdenv.mkDerivation rec {
  pname = "xmrig";
  version = "6.25.0";
  src = fetchurl {
    url = "https://github.com/kryptex-miners-org/kryptex-miners/releases/download/xmrig-6-25-0/xmrig-6.25.0-linux-static-x64.tar.gz";
    sha256 = "1cw7ivgyr72gsgig5hxj9is73aj7vpj4sz2hmkfc7pbham4m7dh6";
  };
  nativeBuildInputs = [autoPatchelfHook];
  buildInputs = [
    glibc
    zlib
    openssl
    libuv
    steam-run
  ];
  unpackPhase = ''
    runHook preUnpack
    tar -xf $src
    runHook postUnpack
  '';
  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    cp xmrig $out/bin/
    chmod +x $out/bin/xmrig
    runHook postInstall
  '';
  meta = with lib; {
    description = "XMRig CPU miner";
    homepage = "https://xmrig.com";
    license = lib.licenses.gpl3;
    platforms = lib.platforms.linux;
  };
}
