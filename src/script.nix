{ config, lib, pkgs
, is-system-install
, extra-flatpak-flags ? [] }:

let
  fargs = if is-system-install then [ "--system" ] else [ "--user" ] ++ extra-flatpak-flags;
  cfg = config.services.flatpak;
  regex = (import ./lib/types.nix { inherit lib; }).regex;
in

pkgs.writeShellScript "setup-flatpaks" ''
  export PATH=${lib.makeBinPath (with pkgs; [ coreutils util-linux inetutils gnugrep flatpak gawk rsync ostree systemd findutils gnused ])}
  
  until ping -c1 github.com &>/dev/null; do echo x; sleep 1; done | awk '
  {
    printf "Waiting for net (%d tries)\n", (NR)
  }
  END {
    printf "Network connected.\n"
  }
  '

  set -eu

  export LANG=C

  ${if is-system-install then ''
  export MODULE_DATA_ROOT=/var/lib/flatpak-module
  export FLATPAK_DIR=/var/lib/flatpak
  '' else ''
  export MODULE_DATA_ROOT=${config.xdg.stateHome}/flatpak-module
  export FLATPAK_DIR=${config.xdg.dataHome}/flatpak
  ''}

  CURR_BOOTID=$(journalctl --list-boots --no-pager | grep -E '^ +0' | awk '{print$2}') || \
    PREV_BOOTID=1
  PREV_BOOTID=$(journalctl --list-boots --no-pager | grep -E '^ +-1' | awk '{print$2}') || \
    PREV_BOOTID=2
  LAST_SUCCESSFUL_BOOTID=$(cat $MODULE_DATA_ROOT/last-successful 2>/dev/null) || \
    LAST_SUCCESSFUL_BOOTID=3

  export TARGET_DIR=$MODULE_DATA_ROOT/boot/$CURR_BOOTID/$(uuidgen)
  export INSTALL_TRASH_DIR=$MODULE_DATA_ROOT/boot/0/$(uuidgen)

  echo Running with $CURR_BOOTID
  mkdir -pm 755 $TARGET_DIR
  mkdir -pm 755 $INSTALL_TRASH_DIR

  echo Cleaning old directories
  find $MODULE_DATA_ROOT/boot -type d -mindepth 1 -maxdepth 1 -not \( -path "$MODULE_DATA_ROOT/boot/$CURR_BOOTID" -o -path "$MODULE_DATA_ROOT/boot/$PREV_BOOTID" -o -path "$MODULE_DATA_ROOT/boot/$LAST_SUCCESSFUL_BOOTID" \) -exec rm -rf {} \;

  export FLATPAK_USER_DIR=$TARGET_DIR
  export FLATPAK_SYSTEM_DIR=$TARGET_DIR

  ${cfg.preInitCommand}

  ${if builtins.length (builtins.attrValues cfg.remotes) == 0 then ''
  echo "No remotes declared in config. Refusing to do anything."
  exit 0
  '' else builtins.toString (builtins.attrValues (builtins.mapAttrs (name: value: ''
  echo "Adding remote ${name} with URL ${value}"
  flatpak ${builtins.toString fargs} remote-add --if-not-exists ${name} ${value}
  '') cfg.remotes))}

  for i in ${builtins.toString (builtins.filter (x: builtins.match ".+${regex.ffile}$" x == null) cfg.packages)}; do
    _remote=$(grep -Eo '^${regex.fremote}' <<< $i)
    _id=$(grep -Eo '${regex.ftype}\/${regex.fref}\/${regex.farch}\/${regex.fbranch}(:${regex.fcommit})?' <<< $i)
    _commit=$(grep -Eo ':${regex.fcommit}$' <<< $_id) || true
    if [ -n "$_commit" ]; then
      _commit=$(tail -c-$(($(wc -c <<< $_commit) - 1)) <<< $_commit)
      _id=$(head -c-$(($(wc -c <<< $_commit) + 1)) <<< $_id)
    fi

    # echo F $i
    # echo R $_remote
    # echo C $_commit
    # echo I $_id

    flatpak ${builtins.toString fargs} install --noninteractive --no-auto-pin $_remote $_id

    if [ -n "$_commit" ]; then
      flatpak update --commit="$_commit" $_id || echo "failed to update to commit \"$_commit\". Check if the commit is correct"
    fi
  done

  echo "Installing out-of-tree refs"
  for i in ${builtins.toString (builtins.filter (x: builtins.match ":.+\.flatpak$" x != null) cfg.packages)}; do
    _id=$(grep -Eo ':.+\.flatpak$' <<< $i | tail -c+2)

    flatpak ${builtins.toString fargs} install --noninteractive --no-auto-pin $_id
  done
  for i in ${builtins.toString (builtins.filter (x: builtins.match ":.+\.flatpakref$" x != null) cfg.packages)}; do
    _remote=$(grep -Eo '^${regex.fremote}:' <<< $i | head -c-2)
    _id=$(grep -Eo ':.+\.flatpakref$' <<< $i | tail -c+2)

    flatpak ${builtins.toString fargs} install --noninteractive --no-auto-pin $_remote $_id
  done

  # Install files
  [ -d $FLATPAK_DIR ] && mv $FLATPAK_DIR/* $INSTALL_TRASH_DIR
  rm -rf $FLATPAK_DIR
  mkdir -pm 755 $FLATPAK_DIR/overrides
  [ -d $INSTALL_TRASH_DIR/db ] && mv $INSTALL_TRASH_DIR/db $FLATPAK_DIR/db
  ${builtins.concatStringsSep "\n" (builtins.map (ref: ''
  ln -s ${pkgs.callPackage ./pkgs/overrides.nix { inherit cfg ref; }} $FLATPAK_DIR/overrides/${ref}
  '') (builtins.attrNames cfg.overrides))}
  [ -d $TARGET_DIR/exports ] && rsync -aL $TARGET_DIR/exports/ $FLATPAK_DIR/exports
  find $FLATPAK_DIR/exports/bin \
    -type f -exec sed -i "s,exec flatpak run,FLATPAK_USER_DIR=$TARGET_DIR FLATPAK_SYSTEM_DIR=$TARGET_DIR exec flatpak run,gm" '{}' \;
  find $FLATPAK_DIR/exports/share/applications \
    -type f -exec sed -i "s,Exec=flatpak run,Exec=FLATPAK_USER_DIR=$TARGET_DIR FLATPAK_SYSTEM_DIR=$TARGET_DIR flatpak run,gm" '{}' \;

  ${cfg.postInitCommand}

  echo $CURR_BOOTID >$MODULE_DATA_ROOT/last-successful
''