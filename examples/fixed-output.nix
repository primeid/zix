# Fixed-output derivation (like builtins.fetchurl): the output path is
# determined by the hash, so it is reproducible across machines.
builtins.derivation {
  name = "hello.tar.gz";
  system = "x86_64-linux";
  builder = "/bin/sh";
  outputHashMode = "flat";
  outputHashAlgo = "sha256";
  outputHash = "0a3666a0710c08aa6d0de92ce72beeb5b93124cce1bf3701c9d6cdeb543cb73e";
}
