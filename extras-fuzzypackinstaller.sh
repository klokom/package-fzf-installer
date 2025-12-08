#!/usr/bin/env bash
set -Eeuo pipefail


DEFAULT_DEST="/usr/local/bin"
read -r -p "Install extra pickers to which directory? [${DEFAULT_DEST}] " DEST
DEST="${DEST:-$DEFAULT_DEST}"
echo "=> Using destination: $DEST"

if [[ ! -d "$DEST" ]]; then
  echo "=> Creating $DEST (sudo may be required)"
  sudo mkdir -p "$DEST"
fi

IN_PATH="no"
IFS=':' read -r -a __PATH_ARR <<< "$PATH"
for p in "${__PATH_ARR[@]}"; do
  [[ "$p" == "$DEST" ]] && IN_PATH="yes" && break
done
if [[ "$IN_PATH" != "yes" ]]; then
  echo "WARNING: $DEST is not in your PATH."
  echo "  Bash:  echo 'export PATH=\"$DEST:\$PATH\"' >> ~/.bashrc && source ~/.bashrc"
  echo "  Fish:  set -Ux fish_user_paths $DEST \$fish_user_paths"
fi

PKG_MGR=""
if command -v pacman >/dev/null 2>&1; then
  PKG_MGR="pacman"
elif command -v apt-get >/devnull 2>&1 || command -v apt >/dev/null 2>&1; then
  PKG_MGR="apt"
elif command -v dnf >/dev/null 2>&1; then
  PKG_MGR="dnf"
elif command -v yum >/dev/null 2>&1; then
  PKG_MGR="yum"
else
  echo "ERROR: Could not detect a supported package manager (pacman/apt/dnf/yum)."
  exit 1
fi

echo
echo "Extras to install:"
echo "  1) Flatpak (Flathub)"
echo "  2) Snap (Snap Store)"
echo "  3) Both"
echo "  4) Skip"
read -r -p "Choose [1/2/3/4]: " PICK
PICK="${PICK:-4}"

WANT_FLATPAK="no"
WANT_SNAP="no"
case "$PICK" in
  1) WANT_FLATPAK="yes" ;;
  2) WANT_SNAP="yes" ;;
  3) WANT_FLATPAK="yes"; WANT_SNAP="yes" ;;
  4) echo "=> Skipping extras."; exit 0 ;;
  *) echo "Invalid choice. Exiting."; exit 1 ;;
esac

BASH_BIN="$(command -v bash)"
: "${BASH_BIN:?bash not found}"
sudo -v || true

ensure_flatpak() {
  if command -v flatpak >/dev/null 2>&1; then
    echo "=> flatpak already installed."
  else
    echo "=> Installing flatpak..."
    case "$PKG_MGR" in
      pacman) sudo pacman -S --needed flatpak ;;
      apt)    sudo apt update -qq && sudo apt install -y flatpak ;;
      dnf)    sudo dnf install -y flatpak ;;
      yum)    sudo yum install -y flatpak ;;
    esac
  fi
  if flatpak remotes | awk '{print $1}' | grep -q '^flathub$'; then
    echo "=> Flathub remote already present."
  else
    echo "=> Adding Flathub remote."
    flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
  fi
}

ensure_snapd() {
  if command -v snap >/dev/null 2>&1; then
    echo "=> snap is available."
    return 0
  fi

  echo "=> Installing snapd..."
  case "$PKG_MGR" in
    pacman) \
        if command -v paru >/dev/null 2>&1; then
          paru -S --needed snapd
        elif command -v yay >/dev/null 2>&1; then
          yay -S --needed snapd
        else
          cat <<EOF
WARNING: snapd is not in official repos on Arch/CachyOS and requires an AUR helper.
- Install an AUR helper (paru or yay), then run:
    paru -S snapd    # or: yay -S snapd
- Or use your AUR picker:
    pkg-aur-install   # search for "snapd"
Skipping snap picker setup for now.
EOF
          return 1
        fi
        ;;
    apt)    sudo apt update -qq && sudo apt install -y snapd ;;
    dnf)    sudo dnf install -y snapd || true ;;
    yum)    sudo yum install -y snapd || true ;;
  esac

  if ! command -v snap >/dev/null 2>&1; then
    echo "NOTE: On some RHEL/Fedora derivatives, you must enable the snapd service and /snap symlink."
  fi

  if command -v systemctl >/dev/null 2>&1; then
    echo "=> Enabling snapd.socket (if available)"
    sudo systemctl enable --now snapd.socket || true
  fi

  if [[ ! -e "/snap" && -d "/var/lib/snapd/snap" ]]; then
    echo "=> Creating /snap symlink"
    sudo ln -s /var/lib/snapd/snap /snap || true
  fi


  if command -v snap >/dev/null 2>&1; then
    echo "=> snap is ready."
  else
    echo "WARNING: snap not fully ready. You may need to reboot or re-login after enabling snapd."
  fi
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

if [[ "$WANT_FLATPAK" == "yes" ]]; then
  ensure_flatpak

  cat > "$TMP_DIR/pkg-flatpak-install" <<'FLATPAK_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

BASH_BIN="$(command -v bash)"
: "${BASH_BIN:?bash not found}"
sudo -v || true

# Ensure flathub exists (no-op if present)
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo >/dev/null 2>&1 || true

# Build index of application IDs (this can be large)
build_index() {
  flatpak remote-ls --app --columns=application flathub 2>/dev/null | sort -u
}

# Allow direct installs
if [[ $# -gt 0 ]]; then
  flatpak install -y flathub "$@" < /dev/tty
fi

mapfile -t ALL_PKGS < <(build_index || true)
[[ ${#ALL_PKGS[@]} -gt 0 ]] || ALL_PKGS=("")

TIPS="TAB/SPACE=mark • ENTER=install current • CTRL-S=install marked • ALT-A/D/T=all/dsel/toggle • CTRL-R=reload • ESC=quit"
printf '%s\n' "$TIPS" > /dev/tty

printf '%s\n' "${ALL_PKGS[@]}" | \
  SHELL="$BASH_BIN" fzf --multi \
    --prompt='Install (flatpak flathub)> ' \
    --height=90% --border \
    --preview "
        $BASH_BIN -lc '
            set +u
            appid=\"{}\"
            [[ -n \"\${appid-}\" ]] || { echo \"Type to search; TAB to multi-select\"; exit 0; }

            # Show name + summary from remote-ls (fast and readable)
            flatpak remote-ls --app --columns=application,name,description flathub 2>/dev/null |
              grep -m1 \"^\$appid[[:space:]]\" |
              awk -F\"\t\" \"{print \\\$2 \\\" \\\" \\\$3}\" || echo \"No description available\"

            echo
            echo \"--- Full details ---\"

            flatpak remote-info flathub \"\$appid\" 2>/dev/null || echo \"(no additional info)\"
          '
        " \
    --preview-window=right:70%:wrap \
    --bind "tab:toggle+down,space:toggle" \
    --bind "alt-a:select-all,alt-d:deselect-all,alt-t:toggle-all" \
    --bind "ctrl-r:reload($(declare -f build_index); build_index)" \
    --bind "enter:execute(
      $BASH_BIN -lc '
        set +u
        cur_raw=\"{}\"
        [[ -n \"\${cur_raw-}\" ]] || exit 0
        cur=\"\${cur_raw%% *}\"
        flatpak install -y flathub \"\$cur\" < /dev/tty
        echo; echo \"Installed (Flatpak): \$cur\"; echo \"(Press any key to continue)\"; read -n1 < /dev/tty
        printf \"\033[2J\033[3J\033[H\" > /dev/tty
      '
    )" \
    --bind "ctrl-s:execute(
      $BASH_BIN -lc '
        set +u
        sel=( {+} )
        [[ \${#sel[@]} -gt 0 ]] || exit 0
        flatpak install -y flathub \"\${sel[@]}\" < /dev/tty
        echo; echo \"Installed (Flatpak): \${sel[*]}\"; echo \"(Press any key to continue)\"; read -n1 < /dev/tty
        printf \"\033[2J\033[3J\033[H\" > /dev/tty
      '
    )+clear-selection"

FLATPAK_EOF

  echo "=> Installing pkg-flatpak-install to $DEST"
  sudo install -Dm755 "$TMP_DIR/pkg-flatpak-install" "$DEST/pkg-flatpak-install"
fi

if [[ "$WANT_SNAP" == "yes" ]]; then
  ensure_snapd

  cat > "$TMP_DIR/pkg-snap-install" <<'SNAP_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

BASH_BIN="$(command -v bash)"
: "${BASH_BIN:?bash not found}"
sudo -v || true

# Dynamic search: reload results as the user types, using {q}
# For a fresh query, `snap find` returns packages whose name/summary matches the query.
# We show only the NAME column to fzf; summary appears in preview.

initial_list() {
  # Start with an empty list and instruct user to type to search
  printf '%s\n' ""
}

search_cmd='
  q="{q}"
  if [ -z "$q" ]; then
    echo ""
  else
    # snap find outputs: Name  Version  Publisher  Notes  Summary
    snap find "$q" 2>/dev/null | awk "NR>1 {print \$1}" | sed "s/^[[:space:]]*//" | sort -u
  fi
'

TIPS="Type to search • TAB/SPACE=mark • ENTER=install current • CTRL-S=install marked • ALT-A/D/T=all/dsel/toggle • ESC=quit"
printf '%s\n' "$TIPS" > /dev/tty

initial_list | \
  SHELL="$BASH_BIN" fzf --multi \
    --prompt='Install (snap)> ' \
    --height=90% --border \
    --bind "change:reload($BASH_BIN -lc $'$(echo "$search_cmd" | sed "s/'/'\\\\''/g")')" \
    --preview "
      $BASH_BIN -lc '
        set +u
        name=\"{}\"
        [[ -n \"\${name-}\" ]] || { echo \"Type to search to fetch results\"; exit 0; }
        snap info \"\$name\" 2>/dev/null | sed -n \"1,120p\" || echo \"No info\"
      '
    " \
    --preview-window=right:70%:wrap \
    --bind "tab:toggle+down,space:toggle" \
    --bind "alt-a:select-all,alt-d:deselect-all,alt-t:toggle-all" \
    --bind "enter:execute(
      $BASH_BIN -lc '
        set +u
        cur_raw=\"{}\"
        [[ -n \"\${cur_raw-}\" ]] || exit 0
        cur=\"\${cur_raw%% *}\"
        sudo snap install \"\$cur\" < /dev/tty
        echo; echo \"Installed (snap): \$cur\"; echo \"(Press any key to continue)\"; read -n1 < /dev/tty
        printf \"\033[2J\033[3J\033[H\" > /dev/tty
      '
    )" \
    --bind "ctrl-s:execute(
      $BASH_BIN -lc '
        set +u
        sel=( {+} )
        [[ \${#sel[@]} -gt 0 ]] || exit 0
        sudo snap install \"\${sel[@]}\" < /dev/tty
        echo; echo \"Installed (snap): \${sel[*]}\"; echo \"(Press any key to continue)\"; read -n1 < /dev/tty
        printf \"\033[2J\033[3J\033[H\" > /dev/tty
      '
    )+clear-selection"
SNAP_EOF

  echo "=> Installing pkg-snap-install to $DEST"
  sudo install -Dm755 "$TMP_DIR/pkg-snap-install" "$DEST/pkg-snap-install"
fi

echo
echo "Done."
[[ "$WANT_FLATPAK" == "yes" ]] && echo "  - Flatpak picker: $DEST/pkg-flatpak-install"
[[ "$WANT_SNAP" == "yes"     ]] && echo "  - Snap picker    : $DEST/pkg-snap-install"
echo
echo "Usage:"
[[ "$WANT_FLATPAK" == "yes" ]] && echo "  pkg-flatpak-install    # fuzzy install from Flathub"
[[ "$WANT_SNAP" == "yes"     ]] && echo "  pkg-snap-install       # fuzzy install from Snap Store (type to search)"
echo
echo "Tips:"
echo "  TAB/SPACE=mark • ENTER=install current • CTRL-S=install marked • ALT-A/D/T=all/dsel/toggle • CTRL-R=reload • ESC=quit"
