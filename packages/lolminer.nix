{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  makeWrapper,
  glibc,
  zlib,
  gcc-unwrapped,
  libX11,
  libxcb,
  libXext,
}:
stdenv.mkDerivation rec {
  pname = "lolminer";
  version = "1.98a";
  src = fetchurl {
    url = "https://github.com/kryptex-miners-org/kryptex-miners/releases/download/lolminer-1-98a/lolMiner_v1.98a_Lin64.tar.gz";
    sha256 = "0avny9fshray40snp3p90svlijh0mx5dh37fqqqppip9ss9gby72";
  };
  nativeBuildInputs = [autoPatchelfHook makeWrapper];
  buildInputs = [
    glibc
    zlib
    gcc-unwrapped.lib
    libX11
    libxcb
    libXext
  ];
  unpackPhase = ''
    runHook preUnpack
    tar -xf $src
    runHook postUnpack
  '';
  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    cp ./lolMiner $out/bin/
    chmod +x $out/bin/lolMiner
    wrapProgram $out/bin/lolMiner \
      --prefix LD_LIBRARY_PATH : /run/opengl-driver/lib
    runHook postInstall
  '';
  meta = with lib; {
    description = "NVIDIA/AMD GPU miner";
    homepage = "https://lolminer.org";
    license = lib.licenses.unfree;
    platforms = lib.platforms.linux;
  };
}
