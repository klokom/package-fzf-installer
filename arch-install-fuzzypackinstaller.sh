#!/usr/bin/env bash
set -Eeuo pipefail


DEFAULT_DEST="/usr/local/bin"
read -r -p "Install scripts to which directory? [${DEFAULT_DEST}] " DEST
DEST="${DEST:-$DEFAULT_DEST}"
echo "=> Using destination: $DEST"


if [[ ! -d "$DEST" ]]; then
  echo "=> Creating $DEST (sudo may be required)"
  sudo mkdir -p "$DEST"
fi


IN_PATH="no"
IFS=':' read -r -a PATH_ARR <<< "$PATH"
for p in "${PATH_ARR[@]}"; do
  [[ "$p" == "$DEST" ]] && IN_PATH="yes" && break
done
if [[ "$IN_PATH" != "yes" ]]; then
  echo "⚠️  $DEST is not in your PATH."
  echo "   Add it to your shell profile to run scripts by name:"
  echo "   Bash:  echo 'export PATH=\"$DEST:\$PATH\"' >> ~/.bashrc && source ~/.bashrc"
  echo "   Fish:  set -Ux fish_user_paths $DEST \$fish_user_paths"
fi


if command -v pacman >/dev/null 2>&1; then
  need_pkgs=()
  command -v fzf >/dev/null 2>&1 || need_pkgs+=(fzf)
  pacman -Qi pacman-contrib >/dev/null 2>&1 || need_pkgs+=(pacman-contrib)
  if ((${#need_pkgs[@]})); then
    echo "=> Installing missing dependencies via pacman: ${need_pkgs[*]}"
    sudo pacman -S --needed "${need_pkgs[@]}"
  fi
else
  echo "ℹ️  Non-Arch system detected. Please install 'fzf' manually."
fi


install_aur_helper() {
  local choice tmpdir repo
  echo
  echo "No AUR helper detected (paru/yay)."
  read -r -p "Install an AUR helper now? [Y/n] " yn
  yn=${yn:-Y}
  if [[ "${yn,,}" != "y" ]]; then
    echo "Skipping AUR helper installation."
    return 0
  fi


  read -r -p "Which helper? [paru/yay] (default: paru) " choice
  choice=${choice:-paru}
  if [[ "$choice" != "paru" && "$choice" != "yay" ]]; then
    echo "Invalid choice. Aborting helper installation."
    return 1
  fi


  echo "=> Installing prerequisites: base-devel git"
  sudo pacman -S --needed base-devel git


  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' RETURN
  pushd "$tmpdir" >/dev/null

  if [[ "$choice" == "paru" ]]; then
    repo="https://aur.archlinux.org/paru.git"
  else
    repo="https://aur.archlinux.org/yay.git"
  fi

  echo "=> Cloning $repo"
  git clone "$repo"
  cd "$(basename "$repo" .git)"

  echo "=> Building with makepkg (you may be prompted)"
  makepkg -si

  popd >/dev/null
  echo "=> Installed $choice."
}

if ! command -v paru >/dev/null 2>&1 && ! command -v yay >/dev/null 2>&1; then
  if command -v pacman >/dev/null 2>&1; then
    install_aur_helper
  else
    echo "⚠️  AUR helpers are Arch-only; skipping on this system."
  fi
fi


TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

cat > "$TMP_DIR/pkg-install" <<'PKG_INSTALL_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

: "${PACMAN:=pacman}"
BASH_BIN="$(command -v bash)"
: "${BASH_BIN:?bash not found}"

sudo -v || true

build_index() {
  $PACMAN -Sl 2>/dev/null | awk '{print $1 "/" $2}' | sort -u
}

# If names were passed directly, install them and then open picker
if [[ $# -gt 0 ]]; then
  sudo "$PACMAN" -S --needed "$@" < /dev/tty
fi

mapfile -t ALL_PKGS < <(build_index || true)
[[ ${#ALL_PKGS[@]} -gt 0 ]] || ALL_PKGS=("")

TIPS="TAB/SPACE=mark • ENTER=install current • CTRL-S=install marked • ALT-A/D/T=all/dsel/toggle • CTRL-R=reload • ESC=quit"
printf '%s\n' "$TIPS" > /dev/tty

printf '%s\n' "${ALL_PKGS[@]}" | \
  SHELL="$BASH_BIN" fzf --multi \
    --prompt='Install (repos)> ' \
    --height=90% --border \
    --preview "
      $BASH_BIN -lc '
        set +u
        line=\"{}\"
        [[ -n \"\${line-}\" ]] || { echo \"Type to search; TAB to multi-select\"; exit 0; }
        pkg=\${line##*/}   # strip repo/
        $PACMAN -Si \"\$pkg\" 2>/dev/null || echo \"No info\"
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
        cur=\"\${cur_raw##*/}\"   # strip repo/
        [[ -n \"\${cur-}\" ]] || exit 0
        sudo $PACMAN -S --needed \"\$cur\" < /dev/tty
        echo; echo \"✔ Installed: \$cur\"; echo \"(Press any key to continue)\"; read -n1 < /dev/tty
      '
    )" \
    --bind "ctrl-s:execute(
      $BASH_BIN -lc '
        set +u
        sel=( {+} )
        [[ \${#sel[@]} -gt 0 ]] || exit 0
        names=()
        for s in \"\${sel[@]}\"; do
          names+=(\"\${s##*/}\")   # strip repo/
        done
        sudo $PACMAN -S --needed \"\${names[@]}\" < /dev/tty
        echo; echo \"✔ Installed: \${names[*]}\"; echo \"(Press any key to continue)\"; read -n1 < /dev/tty
      '
    )+clear-selection"
PKG_INSTALL_EOF

cat > "$TMP_DIR/pkg-aur-install" <<'PKG_AUR_INSTALL_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

if command -v paru >/dev/null 2>&1; then
  AUR_HELPER="paru"
elif command -v yay >/dev/null 2>&1; then
  AUR_HELPER="yay"
else
  AUR_HELPER=""
fi

BASH_BIN="$(command -v bash)"
: "${BASH_BIN:?bash not found}"

sudo -v || true

build_index() {
  if [[ -n "$AUR_HELPER" ]]; then
    curl -s 'https://aur.archlinux.org/packages.gz' | gunzip -c 2>/dev/null || true
  else
    :
  fi
}

mapfile -t ALL_PKGS < <(build_index || true)
[[ ${#ALL_PKGS[@]} -gt 0 ]] || ALL_PKGS=("")

TIPS="TAB/SPACE=mark • ENTER=install current • CTRL-S=install marked • ALT-A/D/T=all/dsel/toggle • CTRL-R=reload • ESC=quit"
printf '%s\n' "$TIPS" > /dev/tty

printf '%s\n' "${ALL_PKGS[@]}" | \
  SHELL="$BASH_BIN" fzf --multi \
    --prompt='Install (AUR)> ' \
    --height=90% --border \
    --preview "
      $BASH_BIN -lc '
        set +u
        if [[ -z \"$AUR_HELPER\" ]]; then
          echo \"No AUR helper (paru/yay) detected.\"
          echo \"Install paru first to enable AUR installs.\"
          exit 0
        fi
        name=\$(echo {} | sed \"s|^aur/||;s|^community/||\")
        [[ -n \"\${name-}\" ]] && $AUR_HELPER -Si \"\$name\" 2>/dev/null || echo \"Type to search; TAB to multi-select\"
      '
    " \
    --preview-window=right:70%:wrap \
    --bind "tab:toggle+down,space:toggle" \
    --bind "alt-a:select-all,alt-d:deselect-all,alt-t:toggle-all" \
    --bind "ctrl-r:reload($(declare -f build_index); build_index)" \
    --bind "enter:execute(
      $BASH_BIN -lc '
        set +u
        if [[ -z \"$AUR_HELPER\" ]]; then
          echo \"No AUR helper found (paru/yay).\"; read -n1 < /dev/tty; exit 0
        fi
        cur_raw=\"{}\"
        [[ -n \"\${cur_raw-}\" ]] || exit 0
        cur=\"\${cur_raw##*/}\"
        [[ -n \"\${cur-}\" ]] || exit 0
        $AUR_HELPER -S --needed \"\$cur\" < /dev/tty
        echo; echo \"✔ Installed (AUR): \$cur\"; echo \"(Press any key to continue)\"; read -n1 < /dev/tty
      '
    )" \
    --bind "ctrl-s:execute(
      $BASH_BIN -lc '
        set +u
        if [[ -z \"$AUR_HELPER\" ]]; then
          echo \"No AUR helper found (paru/yay).\"; read -n1 < /dev/tty; exit 0
        fi
        sel=( {+} )
        [[ \${#sel[@]} -gt 0 ]] || exit 0
        names=()
        for s in \"\${sel[@]}\"; do
          names+=(\"\${s##*/}\")
        done
        $AUR_HELPER -S --needed \"\${names[@]}\" < /dev/tty
        echo; echo \"✔ Installed (AUR): \${names[*]}\"; echo \"(Press any key to continue)\"; read -n1 < /dev/tty
      '
    )+clear-selection"
echo "=> Installing scripts to $DEST"
sudo install -Dm755 "$TMP_DIR/pkg-install"      "$DEST/pkg-install"
sudo install -Dm755 "$TMP_DIR/pkg-aur-install"  "$DEST/pkg-aur-install"

echo
echo "✅ Done."
echo "   - Repo picker: $DEST/pkg-install"
echo "   - AUR picker : $DEST/pkg-aur-install"
echo
echo "Usage:"
echo "   pkg-install        # official repos"
echo "   pkg-aur-install    # AUR (needs paru or yay)"
echo
echo "Tips (also printed above the menu at runtime):"
echo "   TAB/SPACE=mark • ENTER=install current • CTRL-S=install marked • ALT-A/D/T=all/dsel/toggle • CTRL-R=reload • ESC=quit"
