+++
title = "How to use NixOS without going insane"
date = 2025-07-13
+++

I've been using NixOS for a while now, and had my fair share of troubles with it. My main usecases for it are:

- I want my different machines (home, work, laptop) to stay synchronized when it comes to config and installed tools.
- I want to be able to wipe machines and reinstall them easily without having to do a ton of setup.
- I want to be able to easily add new machines and have them set up in the same way as my other machines.

After a lot of trial and error, I think I've landed on a good solution to achieve all of this while working around common issues that NixOS tends to have in the real world. In this post, I'll try to outline how I do things and explain how you can adapt my config for yourself.

{% info() %}
Note that this is not meant as a general introduction to NixOS - There are lots of great tutorials already. I'm only detailing how I use NixOS to achieve my goals with relatively little effort here.

I'll omit a lot of settings I have in my config if they are specific to my needs. You can have a look at my full config [here](https://github.com/happens/flake). Feel free to shoot me a message if you have any questions!
{% end %}

## Keeping it Simple

When looking at other NixOS configs, one thing that I see a lot is deeply nested directory structure, seperate files for every package that is installed, and custom modules with options that can be configured for every host.

This has many advantages and offers a lot of flexibility when it comes to configuring your machines. It also introduces a big maintenance burden and makes adding new packages harder, since you'll always think about the configuration API you'll have to write for yourself. Since I want all my machine configs to be *very* similar, I do away with all of that and try to keep my config as straightforward and flat as possible.

Here's what it looks like:

```sh
~/.flake
├── config/          # Dotfiles
│   ├── nvim/
│   ├── zsh/
│   ├── direnv/
│   ├── git/
│   └── ...
├── hosts/           # Host-specific config
│   ├── mira/
│   │   ├── config/
│   │   ├── configuration.nix
│   │   └── hardware-configuration.nix
│   ├── hei/
│   │   ├── config/
│   │   ├── configuration.nix
│   │   └── hardware-configuration.nix
│   └── ...
├── flake.nix        # Flake inputs and plumbing
├── home.nix         # Home-manager configuration
├── system.nix       # General NixOS configuration
├── overlay.nix      # nixpkgs customization
├── packages.nix     # List of all installed packages
├── devshells.nix    # Global shells for development
└── justfile         # Recipes for formatting, building the config, etc.
```

Let's go through the nix files one by one.

### `flake.nix`

This is the entrypoint.

```nix
{
  description = "system config";

  inputs = {
    nixpkgs.url = "nixpkgs/nixos-unstable";

    # nixos-hardware provides some predefined configuration for specific laptop
    # models, CPUs and so on.
    nixos-hardware.url = "github:NixOS/nixos-hardware/master";

    # Use home-manager as a flake
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Everything after this point is optional.

    # I want to use neovim nightly instead of the latest stable version
    neovim-nightly-overlay = {
      url = "github:nix-community/neovim-nightly-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Speed up nixpkgs searches by using a prebuilt database
    nix-index-database = {
      url = "github:nix-community/nix-index-database";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # More custom packages or overlays you might want to install go here.
    # For example, I have a few tools that I've written myself, which I add as
    # inputs here:
    serve = {
      url = "github:happenslol/serve";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs @ {
    nixpkgs,
    home-manager,
    nix-index-database,
    ...
  }: let
    # All my hosts are linux machines - This could be added as a parameter to
    # `mkHost` if yours aren't.
    system = "x86_64-linux";
    username = "happens";

    # Add my own overlays and overlays provided by flakes.
    overlays = [
      (import ./overlay.nix)
      inputs.neovim-nightly-overlay.overlays.default
    ];

    # Apply the overlays and allow unfree packages (slack, zoom, discord, ...)
    pkgs = import nixpkgs {
      inherit system;
      overlays = overlays;
      config.allowUnfree = true;
    };

    # This creates the actual host configuration. Instead of passing lots of
    # options for every host here, this includes per-host configuration files.
    #
    # The stateVersion can be different per host, and basically just defines
    # what version of NixOS was current when you installed the system first.
    mkHost = { hostname, stateVersion }: (nixpkgs.lib.nixosSystem {
      inherit system pkgs;

      # Pass these args to every module.
      specialArgs = {inherit inputs stateVersion hostname username system;};

      modules = [
        # Include our general system config.
        ./system.nix

        # As mentioned above, we include the host-specific config as modules
        # here from the hosts directory.
        (./. + "/hosts/${hostname}/hardware-configuration.nix")
        (./. + "/hosts/${hostname}/configuration.nix")

        # All inputs that provide extra modules go here.
        nix-index-database.nixosModules.nix-index
        home-manager.nixosModules.home-manager

        # Include our home-manager configuration.
        {
          home-manager = {
            # Make sure we use the same nixpkgs as the rest of the config.
            useGlobalPkgs = true;

            # This allows us to install all of our packages through
            # home-manager, instead of globally.
            useUserPackages = true;

            # Same as above - these will be available in our `home.nix`.
            extraSpecialArgs = {inherit inputs stateVersion hostname system username;};
            users.${username} = import ./home.nix;
          };
        }
      ];
    });
  in {
    nixosConfigurations = {
      mira = mkHost {
        hostname = "mira";
        stateVersion = "24.11";
      };
      hei = mkHost {
        hostname = "hei";
        stateVersion = "24.11";
      };

      # More hosts...
    };

    # Adding devshells here allows us to use them like this:
    # `nix develop ~/.flake#<name>`
    devShells.${system} = import ./devshells.nix pkgs;
  };
}
```

That was a lot! But with all of this set up, the rest of the files are a lot shorter.

### `system.nix`

These are configuration options that apply to every machine. I'll just show a few options that are non-obvious here or that I find especially useful here.

```nix
{ pkgs, stateVersion, username }: {
  system = {inherit stateVersion;};

  nix = {
    # Make sure we use the same nixpkgs version as in this flake when we use
    # `nix-shell -p`
    registry.nixkpgs.flake = inputs.nixpkgs;
    nixPath = ["nixpkgs=${inputs.nixpkgs.outPath}"];

    # Enable modern NixOS features
    settings.experimental-features = ["nix-command" "flakes" "pipe-operators"];
  };

  programs = {
    # Add systemwide programs here, e.g.:
    command-not-found.enable = false;
    nix-index-database.comma.enable = true;
    steam.enable = true;

    # More on this later. This allows running a lot of unpatched dynamic binaries.
    nix-ld = {
      enable = true;
      libraries = builtins.concatLists (builtins.attrValues (import ./ld.nix pkgs));
    };
  };

  environment = {
    # Add packages that you want to be available no matter what here.
    systemPackages = with pkgs; [neovim curl kitty];
  };

  services = {
    # Enable any services you want here, e.g.:
    upower.enable = true;
    openssh.enable = true;
    dbus.enable = true;
  };

  # Add the user. You can also add extra groups to the user here.
  users.users.${username}.isNormalUser = true;
}
```

### `home.nix`

This is where I install my packages, link my dotfiles, and configure home-manager.

The most important thing to note here is that we use `mkOutOfStoreSymlink` to link our dotfiles. This lets us create symlinks to our dotfiles in this repository instead of symlinks to the nix store, which would be read only. Additionally, changes to dotfiles don't require rebuilding NixOS to be applied. I didn't do this at first and it was really painful.

```nix
{ config, pkgs, stateVersion, hostname, system }: let
  home = "/home/${username}";

  # See above.
  dotfiles = config.lib.file.mkOutOfStoreSymlink "${home}/.flake/config";
in {
  # Enable home-manager
  programs.home-manager.enable = true;

  home = {
    inherit stateVersion username;
    homeDirectory = home;

    # Install packages from `packages.nix`. I move around the structure here a
    # bit so that file can be as simple as possible.
    packages =
      (builtins.concatLists (builtins.attrValues (import ./packages.nix pkgs)))
      ++ (builtins.attrValues custom);

    # Link dotfiles that live outside of `~/.config`.
    file = {
      ".gitconfig".source = "${dotfiles}/git/gitconfig";
      ".ssh/config".source = "${dotfiles}/ssh/config";
      # ...
    };
  };

  # Link dotfiles inside `~/.config`.
  xdg.configFile = {
    "nvim".source = "${dotfiles}/nvim";
    "kitty".source = "${dotfiles}/kitty";
    # ...
  };

  # Add more home-manager configuration here.
}
```

### `packages.nix`

This could be included in `home.nix` (and previously was), but I like being able to quickly install packages without having to go through my `home.nix` by just adding them here. It's also nice to just have a list of everything I expect to be installed.

```nix
pkgs: {
  pkgs = with pkgs; [git ripgrep kitty starship /* ... */];
  node = with pkgs.nodePackages_latest; [vscode-langservers-extracted /* ... */];
  beam = with pkgs.beam27Packages; [elixir elixir-ls /* ... */];

  # ...and so on.
}
```

### `overlay.nix`

Sometimes, I want to override options for a package or apply fixes. Instead of doing this configuration in `packages.nix`, I do it in an overlay, so the same things are applied everywhere the packages are used. As an example, some nix options allow specifying the package to use (like `home.pointerCursor.package = ...`), and it would be easy to forget overrides here.

```nix
self: super: {
  # An example of a package I want to customize.
  vesktop = super.vesktop.override {
    electron = self.electron_33;
    withTTS = false;
  };
}
```

### `devshells.nix`

Most of the time, `nix-ld` lets me run unpatched binaries if I want to try something out. When I want to build something myself which requires specific packages or runtime libraries, I used to just create a `flake.nix` ad-hoc, which got annoying over time. I define some devshells here that cover the most common usecases and let me quickly get these dependencies into my path if I need them.

For example, I've been playing around with a lot of GUI libraries, which mostly have the same dependencies. This is the shell I created for those:

```nix
pkgs: {
  gui = pkgs.mkShell rec {
    packages = with pkgs; [libxkbcommon vulkan-loader wayland];
    LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath packages;
  };
}
```

By running `echo "use flake ~/.flake#<name>" >> .envrc && direnv allow`, I'll have everything I need by default whenever I `cd` into the cloned project. This is instant most of the time, since it uses the same `nixpkgs` that are installed globally.

### Host-specific config (`hosts/<name>/configuration.nix`)

These are pretty minimal and mostly hardware dependant. Here's an example:

```nix
{ pkgs }: {
  # Add nix-hardware modules
  imports = [
    inputs.nixos-hardware.nixosModules.common-cpu-amd
    inputs.nixos-hardware.nixosModules.common-cpu-amd-pstate
    inputs.nixos-hardware.nixosModules.common-gpu-amd
    inputs.nixos-hardware.nixosModules.common-pc-ssd
  ];

  networking = {
    hostId = "<random id>";
    hostName = "<hostname>";
  };

  # Add kernel params and bootloader settings
  boot = {
    loader.systemd-boot.enable = true;
    kernelParams = [/* ... */];
  };

  # Make sure building a config doesn't use all CPU and I can keep working
  # during the build. I adjust this based on the machine.
  nix.settings = {
    cores = 6;
    max-jobs = 4;
  };

  # Not all my machines have bluetooth, so it's enabled here
  hardware.bluetooth.enabled = true;

  # And so on.
}
```

The `hardware-configuration.nix` file is copied directly from what generates during installation.

# Everyday Usage

Let's go through some workflows to see how this setup makes my life easier. To apply the config, I have a `justfile` for which I have a global alias in my zsh config:

```zsh
alias flake="just -f ~/.flake/justfile "
```

Here's an excerpt from the `justfile`:

```
set shell := ["zsh", "-c"]
alias a := apply

# Switch to the current flake configuration
@apply:
  git add .
  sudo nixos-rebuild switch --flake ~/.flake#
```

So, installing a package would be done by adding it to `packages.nix` and then running `flake a`.

#### Updating dotfiles

I just edit the dotfiles in `~/.flake/config`, and that's it. They are symlinked, so any changes are directly visible to the respective program.

#### Installing NixOS

I start by booting into a NixOS live disk and formatting my drives. I'd eventually like to automate this completely using [`disko`](https://github.com/nix-community/disko) and [`nixos-anywhere`](https://github.com/nix-community/nixos-anywhere), but I ran into some issues last time I tried.

Then, I clone the flake (`git clone https://github.com/happenslol/flake.git /home/happens/.flake`). If I'm adding a new host, I also generate a hardware config with `nixos-generate-config` and place it in a new host directory.

After running `nixos-install --flake /home/happens/.flake#<hostname>`, I can boot into the fully configured system. I have to log in as `root` once and change the password for the user - there's probably a way to set the password during installation, but it's not a big deal to me so I haven't put any work into it.

#### Running Binaries

`nix-ld` and my devshells take care of most things I need to run. When building an external repo for which I don't have a devshell yet, I usually create a super minimal flake:

```nix
{
  inputs.nixpkgs.url = "nixpkgs/nixos-unstable";
  outputs = {nixpkgs, ...}: let
    system = "x86_64-linux";
    pkgs = import nixpkgs {inherit system;};
  in {
    devShells.${system}.default = {
      packages = [/* ... */];
      LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath [/* ... */];
    };
  };
}
```

As a last resort I use `steam-run`, which offers a full `fhsEnv` to processes.

This is still kind of a pain, honestly. I sometimes thinking about running a different distro and just using nix to manage my dotfiles and installed packages, so that I still have a full `fhsEnv` and can run dynamic binaries or build random repos like a normal person. For now, the benefits still outweigh the cons for me overall.

#### Updating Packages

Most of the time, running `nix flake update && flake a` works without a problem. Rarely, I'll have to update some configuration or change the kernel version, but I haven't run into any huge issues here.

Even _more_ rarely, the system will refuse to boot after an update, because of incompatible kernel packages or bugs in updated packages (like the greeter or compositor). In these cases, I mostly just boot to the last configuration, revert the update, and wait a few days before trying again. It's not too hard to track down these things and find the corresponding GitHub issues on `nixpkgs` that are usually already open - but `nixpkgs` moves very fast and breaking bugs aren't on unstable for more than a few days, in my experience.

The update experience for `NixOS` hasn't been much different to me than on other rolling distros like arch. The largest difference is that I can just reset everything if something breaks, and keep working.

#### Trying Out Packages

I recommend the amazing [`comma`](https://github.com/nix-community/comma) for running applications that you don't want to permanently install. Most packages are available in `nixpkgs`, and `comma` makes trying any of them out as easy as running `, <package>`.

# Conclusion

Maintaining a personal nix configuration can definitely be a hobby, and a very fun one at that. But over time, it's become important to me that I can engage in that hobby _when I want to_, and that I'm not required to do it in my everyday working life to be productive.  
With this config, I can keep on top of software updates and work on different machines that are synced with very little upkeep.

The upfront investment of switching to NixOS is certainly large, but the benefits have been invaluable to me. I switch machines daily, and change installed programs and my dotfiles frequently. Having everything stay in sync automatically saves me a ton of work. Just running `git pull && flake a` on my laptop after not having used it for half a year, and having it _just work_ and be up to date with my other machines was magical to me.  
Having a hard drive fail and being able to reinstall within 20 minutes after replacing it, picking up right where I left off, is something I couldn't have imagined back when using arch.

I hope my experience can be of use to anyone reading this! I'm happy about any comments, questions or suggestions.
