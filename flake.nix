{
  description = "Neotest adapter for dotnet";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";

    flake-parts.url = "github:hercules-ci/flake-parts";

    pre-commit-hooks = {url = "github:cachix/pre-commit-hooks.nix";};

    neorocks = {url = "github:nvim-neorocks/neorocks";};

    gen-luarc.url = "github:mrcjkb/nix-gen-luarc-json";

    vimcats.url = "github:mrcjkb/vimcats";
  };

  outputs = inputs @ {
    self,
    nixpkgs,
    flake-parts,
    pre-commit-hooks,
    neorocks,
    gen-luarc,
    vimcats,
    ...
  }: let
    name = "neotest-dotnet";

    plugin-overlay = import ./nix/plugin-overlay.nix {inherit name self;};
  in
    flake-parts.lib.mkFlake {inherit inputs;} {
      systems = ["x86_64-linux" "x86_64-darwin" "aarch64-darwin"];
      perSystem = {
        config,
        self',
        inputs',
        system,
        ...
      }: let
        ci-overlay = import ./nix/ci-overlay.nix {
          inherit self;
          plugin-name = name;
        };

        pkgs = import nixpkgs {
          inherit system;
          overlays = [
            ci-overlay
            neorocks.overlays.default
            gen-luarc.overlays.default
            plugin-overlay
          ];
        };

        luarc-plugins = with pkgs.lua51Packages;
          [nvim-nio] ++ (with pkgs.vimPlugins; [neotest nvim-dap]);

        luarc-nightly = pkgs.mk-luarc {
          nvim = pkgs.neovim-nightly;
          plugins = luarc-plugins;
        };

        luarc-stable = pkgs.mk-luarc {
          nvim = pkgs.neovim-unwrapped;
          plugins = luarc-plugins;
          disabled-diagnostics = [
            "undefined-doc-name"
            "undefined-doc-class"
            "redundant-parameter"
            "invisible"
          ];
        };

        type-check-nightly = pre-commit-hooks.lib.${system}.run {
          src = self;
          hooks = {
            lua-ls = {
              enable = true;
              settings.configuration = luarc-nightly;
            };
          };
        };

        type-check-stable = pre-commit-hooks.lib.${system}.run {
          src = self;
          hooks = {
            lua-ls = {
              enable = true;
              settings = {configuration = luarc-stable;};
            };
          };
        };

        pre-commit-check = pre-commit-hooks.lib.${system}.run {
          src = self;
          hooks = {
            alejandra.enable = true;
            stylua.enable = true;
            luacheck.enable = true;
            editorconfig-checker.enable = true;
            markdownlint.enable = true;
          };
        };

        devShell = pkgs.nvim-nightly-tests.overrideAttrs (oa: {
          name = "neotest-dotnet devShell";
          shellHook = ''
            ${pre-commit-check.shellHook}
            ln -fs ${pkgs.luarc-to-json luarc-nightly} .luarc.json
          '';
          buildInputs =
            self.checks.${system}.pre-commit-check.enabledPackages
            ++ oa.buildInputs;
        });
      in {
        devShells = {
          default = devShell;
          inherit devShell;
        };

        packages = rec {
          default = neotest-dotnet;
          inherit (pkgs.vimPlugins) neotest-dotnet;
          inherit (pkgs) docgen;
        };

        checks = {
          inherit pre-commit-check type-check-stable type-check-nightly;
          inherit (pkgs) nvim-stable-tests nvim-nightly-tests;
        };
      };
      flake = {overlays.default = plugin-overlay;};
    };
}
