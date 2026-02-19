{ lib, rustPlatform, pkg-config, src }:

rustPlatform.buildRustPackage {
  pname = "zeroclaw";
  version = "0.1.0";

  inherit src;

  cargoLock.lockFile = "${src}/Cargo.lock";

  nativeBuildInputs = [ pkg-config ];

  # Only build the main binary (skip robot-kit subcrate)
  cargoBuildFlags = [ "--package" "zeroclaw" ];

  # Default features include "hardware" (nusb, tokio-serial).
  # Skip browser-native, probe, rag-pdf, peripheral-rpi.
  buildNoDefaultFeatures = false;

  # Tests require network access and interactive prompts
  doCheck = false;

  meta = with lib; {
    description = "Zero overhead AI assistant infrastructure in Rust";
    homepage = "https://github.com/zeroclaw-labs/zeroclaw";
    license = licenses.asl20;
    mainProgram = "zeroclaw";
    platforms = platforms.linux;
  };
}
