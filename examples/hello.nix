# A trivial derivation: evaluate and print it with
#   zix eval hello.nix
builtins.derivation {
  name = "hello-zix";
  system = "x86_64-linux";
  builder = "/bin/sh";
  args = [ "-c" "echo hello from zix > $out" ];
}
