{
  description = "Hello world flake using uv2nix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    uv2nix = {
      url = "github:pyproject-nix/uv2nix";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.uv2nix.follows = "uv2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      uv2nix,
      pyproject-nix,
      pyproject-build-systems,
      ...
    }:
    let
      inherit (nixpkgs) lib;

      # Load a uv workspace from a workspace root.
      # Uv2nix treats all uv projects as workspace projects.
      workspace = uv2nix.lib.workspace.loadWorkspace { workspaceRoot = ./.; };

      # Create package overlay from workspace.
      overlay = workspace.mkPyprojectOverlay {
        # Prefer prebuilt binary wheels as a package source.
        # Sdists are less likely to "just work" because of the metadata missing from uv.lock.
        # Binary wheels are more likely to, but may still require overrides for library dependencies.
        sourcePreference = "wheel"; # or sourcePreference = "sdist";
        # Optionally customise PEP 508 environment
        # environ = {
        #   platform_release = "5.10.65";
        # };
      };

      # Extend generated overlay with build fixups
      #
      # Uv2nix can only work with what it has, and uv.lock is missing essential metadata to perform some builds.
      # This is an additional overlay implementing build fixups.
      # See:
      # - https://pyproject-nix.github.io/uv2nix/FAQ.html
      pyprojectOverrides = final: prev:
        let
          # Helper function to add setuptools to a package's build dependencies
          addSetuptools = pkgName: prev.${pkgName}.overrideAttrs (old: {
            nativeBuildInputs = (old.nativeBuildInputs or []) ++ [
              final.setuptools
            ];
          });
          
          packagesNeedingSetuptools = [
            "crcmod"
            "cos-python-sdk-v5"
            "netifaces"
            "placebo"
          ];
          
          setupToolsOverrides = builtins.listToAttrs (
            map (name: { inherit name; value = addSetuptools name; }) 
            packagesNeedingSetuptools
          );
          
          # HACK: required because c7n-awscc's build is impure since it depends
          # on a changing aws zip file
          # need a fix by perhaps checking in the build artifacts in git?
          disableEditableOverrides = {
            c7n-awscc = prev.c7n-awscc.overrideAttrs (old: {
              # Filter out
              makeEditable = false;
              editableRoot = null;
            });
          };
        in
          setupToolsOverrides // disableEditableOverrides;

      pkgs = nixpkgs.legacyPackages.x86_64-linux;

      python = pkgs.python312;

      pythonSet =
        (pkgs.callPackage pyproject-nix.build.packages {
          inherit python;
        }).overrideScope
          (
            lib.composeManyExtensions [
              pyproject-build-systems.overlays.default
              overlay
              pyprojectOverrides
            ]
          );

      editableOverlay = workspace.mkEditablePyprojectOverlay {
        root = "$REPO_ROOT";
        members = [ "c7n" ];
      };

      editablePythonSet = pythonSet.overrideScope (
        lib.composeManyExtensions [
          editableOverlay

          # Apply fixups for building an editable package of your workspace packages
          (final: prev: {
            c7n = prev.c7n.overrideAttrs (old: {
              # It's a good idea to filter the sources going into an editable build
              # so the editable package doesn't have to be rebuilt on every change.
              src = lib.fileset.toSource {
                root = old.src;
                fileset = lib.fileset.unions [
                  (old.src + "/pyproject.toml")
                  (old.src + "/README.md")
                  (old.src + "/c7n/__init__.py")
                ];
              };

              # Hatchling (our build system) has a dependency on the `editables` package when building editables.
              #
              # In normal Python flows this dependency is dynamically handled, and doesn't need to be explicitly declared.
              # This behaviour is documented in PEP-660.
              #
              # With Nix the dependency needs to be explicitly declared.
              nativeBuildInputs =
                old.nativeBuildInputs
                ++ final.resolveBuildSystem {
                  editables = [ ];
                };
            });
          })
        ]
      );

      filteredDeps = lib.filterAttrs (name: value: name != "c7n-awscc") workspace.deps.all;
        
      virtualenv = editablePythonSet.mkVirtualEnv "c7n-dev-env" filteredDeps;

    in
    {
      packages.x86_64-linux.default = pythonSet.mkVirtualEnv "c7n-env" workspace.deps.default;

      # Make custodian runnable with `nix run`
      apps.x86_64-linux = {
        default = {
          type = "app";
          program = let
            custodianScript = pkgs.writeShellScriptBin "custodian-dev" ''
              export REPO_ROOT=$(git rev-parse --show-toplevel)
              
              exec ${virtualenv}/bin/custodian "$@"
            '';
          in "${custodianScript}/bin/custodian-dev";
        };
      };

      # This example provides two different modes of development:
      # - Impurely using uv to manage virtual environments
      # - Pure development using uv2nix to manage virtual environments
      devShells.x86_64-linux = {
        # It is of course perfectly OK to keep using an impure virtualenv workflow and only use uv2nix to build packages.
        # This devShell simply adds Python and undoes the dependency leakage done by Nixpkgs Python infrastructure.
        impure = pkgs.mkShell {
          packages = [
            python
            pkgs.uv
          ];
          env =
            {
              # Prevent uv from managing Python downloads
              UV_PYTHON_DOWNLOADS = "never";
              # Force uv to use nixpkgs Python interpreter
              UV_PYTHON = python.interpreter;
            }
            // lib.optionalAttrs pkgs.stdenv.isLinux {
              # Python libraries often load native shared objects using dlopen(3).
              # Setting LD_LIBRARY_PATH makes the dynamic library loader aware of libraries without using RPATH for lookup.
              LD_LIBRARY_PATH = lib.makeLibraryPath pkgs.pythonManylinuxPackages.manylinux1;
            };
          shellHook = ''
            unset PYTHONPATH
          '';
        };

        # This devShell uses uv2nix to construct a virtual environment purely from Nix
        uv2nix = pkgs.mkShell {
          packages = [
            virtualenv  # Use the top-level virtualenv
            pkgs.uv
          ];

          env = {
            # Don't create venv using uv
            UV_NO_SYNC = "1";

            # Force uv to use Python interpreter from venv
            UV_PYTHON = "${virtualenv}/bin/python";

            # Prevent uv from downloading managed Python's
            UV_PYTHON_DOWNLOADS = "never";
          };

          shellHook = ''
            # Undo dependency propagation by nixpkgs.
            unset PYTHONPATH

            # Get repository root using git. This is expanded at runtime by the editable `.pth` machinery.
            export REPO_ROOT=$(git rev-parse --show-toplevel)
          '';
        };
      };
    };
}
