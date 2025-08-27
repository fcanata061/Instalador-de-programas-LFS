#!/bin/sh
# lfs-builder.sh — Script POSIX simples para construir e empacotar programas para um LFS
# Requisitos: POSIX sh, coreutils, tar, xz/gzip/bzip2, patch, make, fakeroot (para pós-toolchain)
# Opcional: curl/wget, gpg, unzip, zstd (se quiser suportar .zip/.zst)
#
# Estrutura esperada dos repositórios de receitas e fontes:
#   $REPO/{base,x11,extras,desktop}/<pkg-version>/*.recipe
#     Ex.: $REPO/base/gcc-12.0.1/{gcc-pass1.recipe,gcc.recipe}
#   $SOURCES/ contém os tarballs e patches (e opcionalmente .asc para verificação)
#
# Modelo de receita (arquivo .recipe é um shell fragment POSIX, apenas setando variáveis):
#   NAME="gcc"                 # nome lógico do pacote (ex.: "gcc")
#   VERSION="12.0.1"           # versão
#   CATEGORY="base"            # (base|x11|extras|desktop|...)
#   PHASE="toolchain"          # opcional ("toolchain" para binutils/gcc pass1/pass2, etc.)
#   PKGNAME="gcc-pass1"        # opcional, nome do artefato/etapa se diferente de NAME
#   SOURCE="gcc-12.0.1.tar.xz" # nome do tarball em $SOURCES (ou URL completa)
#   PATCHES="gcc-fix1.patch"   # lista separada por espaços; serão buscados em $SOURCES
#   DEPENDS="binutils glibc"   # nomes lógicos (NAME) de dependências já instaladas
#   WORKDIR_SUBDIR="gcc-12.0.1"# subdiretório extraído, se o tarball não cria um único nível
#   CONFIGURE="./configure"    # comando de configure (padrão: ./configure)
#   CONFIGURE_ARGS="--prefix=/tools --disable-nls"  # args do configure
#   MAKE_ARGS="-j$(nproc 2>/dev/null || echo 1)"    # args do make
#   INSTALL_ARGS="install"                         # alvo do make install
#   STRIP_BINARIES="yes"       # se "yes", chamará strip em binários dentro de DESTDIR
#   POST_REMOVE_HOOK="/caminho/opcional/script.sh"  # executado após remoção
#   # Receitas avançadas podem definir funções build_step() e install_step() para customizar.
#
# Uso:
#   export REPO=... SOURCES=... WORK=... DESTDIR=... PKG=... SYSROOT=/ (ou /tools na toolchain)
#   sh lfs-builder.sh build path/para/arquivo.recipe
#   sh lfs-builder.sh remove <name>
#   sh lfs-builder.sh info <name>
#   sh lfs-builder.sh list
#   sh lfs-builder.sh rebuild-all         # recompila tudo em ordem por dependências simples
#   sh lfs-builder.sh status <name>
#   sh lfs-builder.sh is-installed <name>
#
# Notas:
# - Durante PHASE=toolchain: apenas "instala" em $DESTDIR (não cria pacote). Registro e logs feitos.
# - Após toolchain (PHASE != toolchain): cria pacote tar.gz sob $PKG usando fakeroot e instala no $SYSROOT.
# - Remoção desfaz instalação usando lista de arquivos registrada.
# - Há suporte básico a .tar.(gz|bz2|xz|zst), .zip (se "unzip" presente). Ajuste conforme seu ambiente.

set -eu

# ========================= Configurações =========================
: "${REPO:=${PWD}/repo}"          # diretório com {base,x11,extras,desktop}
: "${SOURCES:=${PWD}/sources}"     # onde ficam tarballs e patches
: "${WORK:=${PWD}/build}"          # área de trabalho/compilação
: "${DESTDIR:=${PWD}/destdir}"     # destino da instalação staged
: "${PKG:=${PWD}/packages}"        # onde armazenar pacotes gerados (.tar.gz)
: "${SYSROOT:=/}"                  # onde instalar pacotes (padrão /)
: "${STATE:=${PWD}/.state}"        # metadados de instalados, arquivos, etc.
: "${LOGDIR:=${PWD}/logs}"         # logs por pacote
: "${KEEP_BUILD:=no}"              # "yes" para manter diretório de build
: "${SPINNER:=yes}"                # mostrar spinner
: "${COLOR:=auto}"                 # "yes"|"no"|"auto"

mkdir -p "$WORK" "$DESTDIR" "$PKG" "$STATE" "$LOGDIR"

# ========================= Cores e UI =========================
is_tty() { [ -t 1 ]; }
use_color() {
  case "$COLOR" in
    yes) return 0;;
    no) return 1;;
    auto) is_tty;;
    *) is_tty;;
  esac
}

if use_color; then
  C_RESET="\033[0m"; C_BOLD="\033[1m";
  C_INFO="\033[36m"; C_OK="\033[32m"; C_WARN="\033[33m"; C_ERR="\033[31m"; C_DIM="\033[2m"
else
  C_RESET=""; C_BOLD=""; C_INFO=""; C_OK=""; C_WARN=""; C_ERR=""; C_DIM=""
fi

sp_pid=""
start_spinner() {
  [ "$SPINNER" = "yes" ] || return 0
  if is_tty; then
    (
      i=0; chars='|/-\'
      while :; do i=$(( (i+1) % 4 )); printf "\r%s" "$(printf "%s" "$chars" | cut -c $((i+1)) )"; sleep 0.1; done
    ) & sp_pid=$!
  fi
}
stop_spinner() {
  [ -n "$sp_pid" ] || return 0
  kill "$sp_pid" 2>/dev/null || true
  wait "$sp_pid" 2>/dev/null || true
  sp_pid=""
  is_tty && printf "\r \r"
}

log() { printf "%s[%s]%s %s\n" "$C_DIM" "$(date +%H:%M:%S)" "$C_RESET" "$*"; }
info() { printf "%sℹ%s %s\n" "$C_INFO" "$C_RESET" "$*"; }
ok() { printf "%s✔%s %s\n" "$C_OK" "$C_RESET" "$*"; }
warn() { printf "%s⚠%s %s\n" "$C_WARN" "$C_RESET" "$*"; }
err() { printf "%s✖%s %s\n" "$C_ERR" "$C_RESET" "$*"; }

# ========================= Utilidades =========================
# Resolve caminho absoluto simples
abspath() { (cd "${1%/*}" 2>/dev/null && printf "%s/%s\n" "$PWD" "${1##*/}") 2>/dev/null || printf "%s\n" "$1"; }

# Carrega receita em subshell e exporta variáveis para o chamador via stdout
load_recipe() {
  recipe_file=$1
  [ -f "$recipe_file" ] || { err "Receita não encontrada: $recipe_file"; exit 1; }
  (
    # Defaults
    NAME=""; VERSION=""; CATEGORY=""; PHASE=""; PKGNAME="";
    SOURCE=""; PATCHES=""; DEPENDS=""; WORKDIR_SUBDIR="";
    CONFIGURE="./configure"; CONFIGURE_ARGS=""; MAKE_ARGS=""; INSTALL_ARGS="install";
    STRIP_BINARIES="no"; POST_REMOVE_HOOK="";
    # Permite que receitas definam funções build_step() e install_step()
    # shellcheck disable=SC1090
    . "$recipe_file"
    [ -n "$NAME" ] || { echo "E: NAME não definido"; exit 2; }
    [ -n "$VERSION" ] || { echo "E: VERSION não definido"; exit 2; }
    PKGID="${PKGNAME:-$NAME}-$VERSION"

    echo "NAME=$NAME"; echo "VERSION=$VERSION"; echo "CATEGORY=$CATEGORY"; echo "PHASE=$PHASE";
    echo "PKGID=$PKGID"; echo "SOURCE=$SOURCE"; echo "PATCHES=$PATCHES"; echo "DEPENDS=$DEPENDS";
    echo "WORKDIR_SUBDIR=$WORKDIR_SUBDIR"; echo "CONFIGURE=$CONFIGURE"; echo "CONFIGURE_ARGS=$CONFIGURE_ARGS";
    echo "MAKE_ARGS=$MAKE_ARGS"; echo "INSTALL_ARGS=$INSTALL_ARGS"; echo "STRIP_BINARIES=$STRIP_BINARIES";
    echo "POST_REMOVE_HOOK=$POST_REMOVE_HOOK";
    # Indica se a receita define funções customizadas
    ( type build_step >/dev/null 2>&1 && echo "HAS_BUILD_STEP=yes" ) || echo "HAS_BUILD_STEP=no"
    ( type install_step >/dev/null 2>&1 && echo "HAS_INSTALL_STEP=yes" ) || echo "HAS_INSTALL_STEP=no"
  )
}

save_state() { # $1=name $2=key $3=value
  p="$STATE/$1.meta"; mkdir -p "$STATE"; (
    [ -f "$p" ] && grep -v "^$2=" "$p" || true
    printf "%s=%s\n" "$2" "$3"
  ) >"$p.tmp" && mv "$p.tmp" "$p"
}
get_state() { # $1=name $2=key
  p="$STATE/$1.meta"; [ -f "$p" ] || return 1; sed -n "s/^$2=//p" "$p"
}

mark_installed() { # $1=NAME $2=PKGID
  date +%Y-%m-%dT%H:%M:%S >"$STATE/$1.installed"
  save_state "$1" PKGID "$2"
}
mark_uninstalled() { # $1=NAME
  rm -f "$STATE/$1.installed" "$STATE/$1.files"
}

is_installed() { [ -f "$STATE/$1.installed" ]; }

list_all_recipes() {
  find "$REPO" -type f -name "*.recipe" | sort
}

need_deps() { # $1=DEPENDS string
  for d in $1; do is_installed "$d" || { echo "$d"; return 0; }; done; return 1
}

# ========================= Extração e Patches =========================
extract_source() { # $1=tarball path, $2=workdir
  tb=$1; wd=$2
  mkdir -p "$wd"; (
    cd "$wd"
    case "$tb" in
      *.tar.gz|*.tgz)   tar -xzf "$tb" ;;
      *.tar.bz2|*.tbz2) tar -xjf "$tb" ;;
      *.tar.xz|*.txz)   tar -xJf "$tb" ;;
      *.tar.zst|*.tzst) if command -v zstd >/dev/null 2>&1; then zstd -d -c "$tb" | tar -xf -; else echo "zstd não encontrado"; exit 3; fi ;;
      *.zip)            if command -v unzip >/dev/null 2>&1; then unzip -q "$tb"; else echo "unzip não encontrado"; exit 3; fi ;;
      *.tar)            tar -xf "$tb" ;;
      *) echo "Formato não suportado: $tb"; exit 3 ;;
    esac
  )
}

apply_patches() { # $1=patch list, $2=srcdir
  [ -n "$1" ] || return 0
  (
    cd "$2"
    for p in $1; do
      if [ -f "$SOURCES/$p" ]; then
        patch -p1 <"$SOURCES/$p"
      elif [ -f "$p" ]; then
        patch -p1 <"$p"
      else
        echo "Patch não encontrado: $p"; exit 4
      fi
    done
  )
}

strip_bins() { # $1=dir
  [ "${STRIP_BINARIES:-no}" = "yes" ] || return 0
  command -v strip >/dev/null 2>&1 || return 0
  find "$1" -type f -perm -0100 -exec sh -c 'file -bi "$1" | grep -q "application/x-executable\|application/x-sharedlib" && strip -s "$1" || true' _ {} \; 2>/dev/null || true
}

# ========================= Build/Install =========================
build_from_recipe() {
  recipe=$(abspath "$1")
  eval "$(load_recipe "$recipe" | sed 's/\[/\\[/g; s/\]/\\]/g')" || { err "Falha ao carregar receita"; exit 1; }

  pkgname="$NAME"; pkgid="$PKGID"; logf="$LOGDIR/$pkgid.log"
  [ -z "${DEPENDS:-}" ] || {
    missing=$(need_deps "$DEPENDS" || true)
    if [ -n "$missing" ]; then err "Dependências ausentes: $missing"; exit 1; fi
  }

  info "Construindo $pkgid${PHASE:+ ($PHASE)}"
  start_spinner
  src="$SOURCE"
  case "$src" in
    http://*|https://*|ftp://*)
      base=$(basename "$src"); [ -f "$SOURCES/$base" ] || { stop_spinner; info "Baixando $src"; start_spinner; curl -L "$src" -o "$SOURCES/$base" 2>>"$logf" || wget -O "$SOURCES/$base" "$src" 2>>"$logf" || { stop_spinner; err "Falha ao baixar $src"; exit 1; }; }; src="$base" ;;
    *) : ;;
  esac

  srcpath="$SOURCES/$src"; [ -f "$srcpath" ] || { stop_spinner; err "Source não encontrado: $srcpath"; exit 1; }

  bdir="$WORK/$pkgid"; rm -rf "$bdir"; mkdir -p "$bdir"
  extract_source "$srcpath" "$bdir" 2>>"$logf" 1>>"$logf"
  # Descobre o diretório extraído
  sdir="$(
    cd "$bdir" && \
    if [ -n "$WORKDIR_SUBDIR" ] && [ -d "$WORKDIR_SUBDIR" ]; then echo "$WORKDIR_SUBDIR"; else ls -1 | head -n1; fi
  )"
  sdir="$bdir/$sdir"
  apply_patches "$PATCHES" "$sdir" 2>>"$logf" 1>>"$logf"

  # Build
  (
    set -e
    cd "$sdir"
    if [ "${HAS_BUILD_STEP}" = "yes" ]; then
      build_step 2>>"$logf" 1>>"$logf"
    else
      [ -x "$CONFIGURE" ] || CONFIGURE="sh $CONFIGURE"
      $CONFIGURE $CONFIGURE_ARGS 2>>"$logf" 1>>"$logf"
      make ${MAKE_ARGS-} 2>>"$logf" 1>>"$logf"
    fi

    # Install (staged)
    rm -rf "$DESTDIR" && mkdir -p "$DESTDIR"
    if [ "${HAS_INSTALL_STEP}" = "yes" ]; then
      DESTDIR="$DESTDIR" install_step 2>>"$logf" 1>>"$logf"
    else
      make DESTDIR="$DESTDIR" ${INSTALL_ARGS:-install} 2>>"$logf" 1>>"$logf"
    fi
    strip_bins "$DESTDIR" || true
  ) || { stop_spinner; err "Falha na construção de $pkgid. Verifique $logf"; exit 1; }
  stop_spinner

  # Registro de arquivos instalados (staged)
  (cd "$DESTDIR" && find . -type f -o -type l -o -type d | sed 's#^.#/' >"$STATE/$pkgname.files.staged")

  if [ "${PHASE:-}" = "toolchain" ]; then
    ok "Instalação staged da toolchain concluída em $DESTDIR"
    mark_installed "$pkgname" "$pkgid"
    # Não empacota nem escreve em SYSROOT nesta fase
    return 0
  fi

  # Empacotar e instalar no SYSROOT com fakeroot
  pkgball="$PKG/$pkgid.pkg.tar.gz"
  ( cd "$DESTDIR" && fakeroot sh -c "tar -czf '$pkgball' ." ) 2>>"$logf" 1>>"$logf"
  ok "Pacote criado: $pkgball"

  info "Instalando em $SYSROOT"
  start_spinner
  fakeroot sh -c "tar -xzf '$pkgball' -C '$SYSROOT'" 2>>"$logf" 1>>"$logf" || { stop_spinner; err "Falha ao instalar pacote"; exit 1; }
  stop_spinner

  # Grava lista final de arquivos no sistema
  ( cd "$DESTDIR" && find . -type f -o -type l -o -type d | sed 's#^.#/' >"$STATE/$pkgname.files" )
  mark_installed "$pkgname" "$pkgid"
  ok "Instalado: $pkgid"

  [ "$KEEP_BUILD" = "yes" ] || rm -rf "$bdir" "$DESTDIR"
}

remove_pkg() { # $1=NAME
  name=$1
  if ! is_installed "$name"; then warn "$name não está instalado"; return 0; fi
  files="$STATE/$name.files"
  if [ ! -f "$files" ]; then err "Lista de arquivos não encontrada para $name"; exit 1; fi
  info "Removendo $name do $SYSROOT"
  while IFS= read -r f; do
    path="$SYSROOT$f"
    [ -e "$path" ] || continue
    if [ -d "$path" ]; then rmdir "$path" 2>/dev/null || true; else rm -f "$path" 2>/dev/null || true; fi
  done <"$files"
  hook=$(get_state "$name" POST_REMOVE_HOOK || echo "")
  [ -n "$hook" ] && [ -x "$hook" ] && { info "Executando post-remove hook"; sh "$hook" "$name" || true; }
  mark_uninstalled "$name"
  ok "Removido: $name"
}

pkg_info() { # $1=NAME
  name=$1
  if is_installed "$name"; then
    echo "Nome: $name"
    echo "PKGID: $(get_state "$name" PKGID || echo -n)"
    echo "Categoria: $(get_state "$name" CATEGORY || echo -n)"
    echo "Instalado em: $(cat "$STATE/$name.installed" 2>/dev/null || echo -n)"
    echo "Arquivos: $(wc -l <"$STATE/$name.files" 2>/dev/null || echo 0)"
  else
    echo "$name não instalado"
  fi
}

status_pkg() { # $1=NAME
  if is_installed "$1"; then ok "$1 está instalado"; else warn "$1 não está instalado"; fi
}

list_installed() {
  for i in "$STATE"/*.installed; do [ -e "$i" ] || continue; b=$(basename "$i" .installed); echo "$b"; done | sort
}

# Rebuild de todo o sistema com ordenação simples por dependências
rebuild_all() {
  # Carrega todas as receitas e tenta resolver dependências de forma iterativa
  queue="$(list_all_recipes)"
  built=""
  changed=yes
  while [ "$changed" = "yes" ]; do
    changed=no
    for r in $queue; do
      eval "$(load_recipe "$r" 2>/dev/null | sed 's/\[/\\[/g; s/\]/\\]/g')" || continue
      # Se já instalado e deseja recompilar, remover antes
      if is_installed "$NAME"; then
        info "Recompilando $NAME — removendo versão atual"
        remove_pkg "$NAME"
      fi
      missing=$(need_deps "$DEPENDS" || true)
      if [ -n "$missing" ]; then
        continue # espera dependências
      fi
      build_from_recipe "$r"
      changed=yes
      # Marca CATEGORY no state
      [ -n "$CATEGORY" ] && save_state "$NAME" CATEGORY "$CATEGORY"
      # Remove receita da fila
      queue=$(printf "%s\n" "$queue" | grep -v "^$r$")
    done
  done

  if [ -n "$queue" ]; then
    warn "Não foi possível resolver dependências destas receitas:"; printf "%s\n" $queue
    return 1
  fi
  ok "Rebuild completo"
}

# ========================= CLI =========================
cmd=${1:-}
case "$cmd" in
  build)
    shift
    [ $# -ge 1 ] || { err "Uso: $0 build <arquivo.recipe>"; exit 1; }
    build_from_recipe "$1" ;;
  remove)
    shift; [ $# -ge 1 ] || { err "Uso: $0 remove <name>"; exit 1; }; remove_pkg "$1" ;;
  info)
    shift; [ $# -ge 1 ] || { err "Uso: $0 info <name>"; exit 1; }; pkg_info "$1" ;;
  list)
    list_installed ;;
  status|is-installed)
    shift; [ $# -ge 1 ] || { err "Uso: $0 status <name>"; exit 1; }; status_pkg "$1" ;;
  rebuild-all)
    rebuild_all ;;
  *)
    cat <<USAGE
Uso: $0 <comando>
  build <arquivo.recipe>   # compila, empacota (se não-toolchain) e instala
  remove <name>            # desfaz a instalação usando o registro de arquivos
  info <name>              # informações do pacote instalado
  list                     # lista pacotes instalados (por este script)
  status <name>            # verifica se está instalado
  rebuild-all              # recompila todo o sistema em ordem (dependências simples)
Variáveis (exportar antes de usar):
  REPO SOURCES WORK DESTDIR PKG SYSROOT STATE LOGDIR KEEP_BUILD SPINNER COLOR
USAGE
    ;;
 esac
