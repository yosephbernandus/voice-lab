{
  description = "voice-lab sound-to-sound behavioral reference and conformance corpus";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  outputs = { self, nixpkgs }:
    let systems = [ "aarch64-darwin" "x86_64-darwin" "aarch64-linux" "x86_64-linux" ];
    in { devShells = nixpkgs.lib.genAttrs systems (system:
      let pkgs = nixpkgs.legacyPackages.${system}; in {
        default = pkgs.mkShell {
          packages = with pkgs; [ elixir nodejs_22 jq python3 git ];
          shellHook = ''
            export MIX_HOME=$PWD/.nix-mix
            export HEX_HOME=$PWD/.nix-hex
            export PATH=$MIX_HOME/bin:$HEX_HOME/bin:$PATH
            export ERL_AFLAGS="-kernel shell_history enabled"
            export LANG=en_US.UTF-8
          '';
        };
      }); };
}
