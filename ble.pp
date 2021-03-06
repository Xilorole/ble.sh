#!/bin/bash
#%$> out/ble.sh
#%[release = 0]
#%[use_gawk = 0]
#%[measure_load_time = 0]
#%[debug_keylogger = 1]
#%#----------------------------------------------------------------------------
#%define inc
#%%[guard_name = "@_included".replace("[^_a-zA-Z0-9]", "_")]
#%%expand
#%%%if $"guard_name" != 1
#%%%%[$"guard_name" = 1]
###############################################################################
# Included from @.sh

#%%%%if measure_load_time
time {
echo @.sh >&2
#%%%%%include @.sh
}
#%%%%else
#%%%%%include @.sh
#%%%%end
#%%%end
#%%end.i
#%end
#%#----------------------------------------------------------------------------
# bash script to souce from interactive shell sessions
#
# ble - bash line editor
#
# Author: 2013, 2015-2017, K. Murase <myoga.murase@gmail.com>
#

#%if measure_load_time
time {
# load_time (2015-12-03)
#   core           12ms
#   decode         10ms
#   color           2ms
#   edit            9ms
#   syntax          5ms
#   ble-initialize 14ms
time {
echo prologue >&2
#%end
#------------------------------------------------------------------------------
# check shell

if [ -z "$BASH_VERSION" ]; then
  echo "ble.sh: This is not a bash. Please use this script with bash." >&2
  return 1 2>/dev/null || builtin exit 1
fi

if [ -z "${BASH_VERSINFO[0]}" ] || [ "${BASH_VERSINFO[0]}" -lt 3 ]; then
  echo "ble.sh: bash with a version under 3.0 is not supported." >&2
  return 1 2>/dev/null || builtin exit 1
fi

_ble_bash=$((BASH_VERSINFO[0]*10000+BASH_VERSINFO[1]*100+BASH_VERSINFO[2]))

if [[ $- != *i* ]]; then
  unset _ble_bash
  { ((${#BASH_SOURCE[@]})) && [[ ${BASH_SOURCE[${#BASH_SOURCE[@]}-1]} == *bashrc ]]; } ||
    echo "ble.sh: This is not an interactive session."
  return 1 2>/dev/null || builtin exit 1
fi

if [[ -o posix ]]; then
  unset _ble_bash
  echo "ble.sh: ble.sh is not intended to be used in bash POSIX modes (--posix)." >&2
  return 1 2>/dev/null || builtin exit 1
fi

_ble_bash_setu=
_ble_bash_setv=
_ble_bash_options_adjusted=
function ble/base/adjust-bash-options {
  [[ $_ble_bash_options_adjusted ]] && return 1
  _ble_bash_options_adjusted=1
  _ble_bash_setv=; [[ -o verbose ]] && _ble_bash_setv=1 && set +v
  _ble_bash_setu=; [[ -o nounset ]] && _ble_bash_setu=1 && set +u
}
function ble/base/restore-bash-options {
  [[ $_ble_bash_options_adjusted ]] || return 1
  _ble_bash_options_adjusted=
  [[ $_ble_bash_setv && ! -o verbose ]] && set -v
  [[ $_ble_bash_setu && ! -o nounset ]] && set -u
}
ble/base/adjust-bash-options

function ble/base/workaround-POSIXLY_CORRECT {
  # This function will be overwritten by ble-decode
  true
}
function ble/base/unset-POSIXLY_CORRECT {
  if [[ ${POSIXLY_CORRECT+set} ]]; then
    unset POSIXLY_CORRECT
    ble/base/workaround-POSIXLY_CORRECT 
  fi
}
function ble/base/adjust-POSIXLY_CORRECT {
  _ble_edit_POSIXLY_CORRECT_set=${POSIXLY_CORRECT+set}
  _ble_edit_POSIXLY_CORRECT=$POSIXLY_CORRECT
  unset POSIXLY_CORRECT

  # ユーザが触ったかもしれないので何れにしても workaround を呼び出す。
  ble/base/workaround-POSIXLY_CORRECT
}
function ble/base/restore-POSIXLY_CORRECT {
  if [[ $_ble_edit_POSIXLY_CORRECT_set ]]; then
    POSIXLY_CORRECT=$_ble_edit_POSIXLY_CORRECT
  else
    ble/base/unset-POSIXLY_CORRECT
  fi
}
ble/base/adjust-POSIXLY_CORRECT

builtin bind &>/dev/null # force to load .inputrc
if [[ ! -o emacs && ! -o vi ]]; then
  unset _ble_bash
  echo "ble.sh: ble.sh is not intended to be used with the line-editing mode disabled (--noediting)." >&2
  return 1
fi

if shopt -q restricted_shell; then
  unset _ble_bash
  echo "ble.sh: ble.sh is not intended to be used in restricted shells (--restricted)." >&2
  return 1
fi

_ble_init_original_IFS=$IFS
IFS=$' \t\n'

#------------------------------------------------------------------------------
# check environment

# ble/bin

## 関数 ble/bin/.default-utility-path commands...
##   取り敢えず ble/bin/* からコマンドを呼び出せる様にします。
function ble/bin/.default-utility-path {
  local cmd
  for cmd; do
    eval "function ble/bin/$cmd { command $cmd \"\$@\"; }"
  done
}
## 関数 ble/bin/.freeze-utility-path commands...
##   PATH が破壊された後でも ble が動作を続けられる様に、
##   現在の PATH で基本コマンドのパスを固定して ble/bin/* から使える様にする。
##
##   実装に ble/util/assign を使用しているので ble-core 初期化後に実行する必要がある。
##
function ble/bin/.freeze-utility-path {
  local cmd path q=\' Q="'\''" fail=
  for cmd; do
    if ble/util/assign path "builtin type -P -- $cmd 2>/dev/null" && [[ $path ]]; then
      eval "function ble/bin/$cmd { '${path//$q/$Q}' \"\$@\"; }"
    else
      fail=1
    fi
  done
  ((!fail))
}

# POSIX utilities

_ble_init_posix_command_list=(sed date rm mkdir mkfifo sleep stty sort awk chmod grep man cat wc mv)
function ble/.check-environment {
  if ! type "${_ble_init_posix_command_list[@]}" &>/dev/null; then
    local cmd commandMissing=
    for cmd in "${_ble_init_posix_command_list[@]}"; do
      if ! type "$cmd" &>/dev/null; then
        commandMissing="$commandMissing\`$cmd', "
      fi
    done
    echo "ble.sh: Insane environment: The command(s), ${commandMissing}not found. Check your environment variable PATH." >&2

    # try to fix PATH
    local default_path=$(command -p getconf PATH 2>/dev/null)
    if [[ $default_path ]]; then
      local original_path=$PATH
      export PATH=${PATH}${PATH:+:}${default_path}
      [[ :$PATH: == *:/usr/bin:* ]] || PATH=$PATH${PATH:+:}/usr/bin
      [[ :$PATH: == *:/bin:* ]] || PATH=$PATH${PATH:+:}/bin
      if ! type "${_ble_init_posix_command_list[@]}" &>/dev/null; then
        PATH=$original_path
        return 1
      fi
    fi

    echo "ble.sh: modified PATH=\$PATH${PATH:${#original_path}}" >&2
  fi

#%if use_gawk
  if ! type gawk &>/dev/null; then
    echo "ble.sh: \`gawk' not found. Please install gawk (GNU awk), or check your environment variable PATH." >&2
    return 1
  fi
  ble/bin/.default-utility-path gawk
#%end

  # 暫定的な ble/bin/$cmd 設定
  ble/bin/.default-utility-path "${_ble_init_posix_command_list[@]}"

  return 0
}
if ! ble/.check-environment; then
  _ble_bash=
  return 1
fi

if [[ $_ble_base ]]; then
  echo "ble.sh: ble.sh seems to be already loaded." >&2
  return 1
fi

#------------------------------------------------------------------------------

_ble_bash_loaded_in_function=0
[[ ${FUNCNAME+set} ]] && _ble_bash_loaded_in_function=1

# will be overwritten by ble-core.sh
function ble/util/assign {
  builtin eval "$1=\$(builtin eval \"\${@:2}\")"
}

# readlink -f (taken from akinomyoga/mshex.git)
function ble/util/readlink {
  ret=
  local path=$1
  case "$OSTYPE" in
  (cygwin|linux-gnu)
    # 少なくとも cygwin, GNU/Linux では readlink -f が使える
    ble/util/assign ret 'PATH=/bin:/usr/bin readlink -f "$path"' ;;
  (darwin*|*)
    # Mac OSX には readlink -f がない。
    local PWD=$PWD OLDPWD=$OLDPWD
    while [[ -h $path ]]; do
      local link; ble/util/assign link 'PATH=/bin:/usr/bin readlink "$path" 2>/dev/null || true'
      [[ $link ]] || break

      if [[ $link = /* || $path != */* ]]; then
        # * $link ~ 絶対パス の時
        # * $link ~ 相対パス かつ ( $path が現在のディレクトリにある ) の時
        path=$link
      else
        local dir=${path%/*}
        path=${dir%/}/$link
      fi
    done
    ret=$path ;;
  esac
}

function ble/base/.create-user-directory {
  local var=$1 dir=$2
  if [[ ! -d $dir ]]; then
    # dangling symlinks are silently removed
    [[ ! -e $dir && -h $dir ]] && ble/bin/rm -f "$dir"
    if [[ -e $dir || -h $dir ]]; then
      echo "ble.sh: cannot create a directory '$dir' since there is already a file." >&2
      return 1
    fi
    if ! (umask 077; ble/bin/mkdir -p "$dir"); then
      echo "ble.sh: failed to create a directory '$dir'." >&2
      return 1
    fi
  elif ! [[ -r $dir && -w $dir && -x $dir ]]; then
    echo "ble.sh: permision of '$tmpdir' is not correct." >&2
    return 1
  fi
  eval "$var=\$dir"
}

##
## @var _ble_base
##
##   ble.sh のインストール先ディレクトリ。
##   読み込んだ ble.sh の実体があるディレクトリとして解決される。
##
function ble/base/initialize-base-directory {
  local src=$1
  local defaultDir=$2

  # resolve symlink
  if [[ -h $src ]] && type -t readlink &>/dev/null; then
    local ret; ble/util/readlink "$src"; src=$ret
  fi

  local dir=${src%/*}
  if [[ $dir != "$src" ]]; then
    if [[ ! $dir ]]; then
      _ble_base=/
    elif [[ $dir != /* ]]; then
      _ble_base=$PWD/$dir
    else
      _ble_base=$dir
    fi
  else
    _ble_base=${defaultDir:-$HOME/.local/share/blesh}
  fi

  [[ -d $_ble_base ]]
}
if ! ble/base/initialize-base-directory "${BASH_SOURCE[0]}"; then
  echo "ble.sh: ble base directory not found!" 1>&2
  return 1
fi

##
## @var _ble_base_run
##
##   実行時の一時ファイルを格納するディレクトリ。以下の手順で決定する。
##   
##   1. ${XDG_RUNTIME_DIR:=/run/user/$UID} が存在すればその下に blesh を作成して使う。
##   2. /tmp/blesh/$UID を作成可能ならば、それを使う。
##   3. $_ble_base/tmp/$UID を使う。
##
function ble/base/initialize-runtime-directory/.xdg {
  [[ $_ble_base != */out ]] || return

  local runtime_dir=${XDG_RUNTIME_DIR:-/run/user/$UID}
  if [[ ! -d $runtime_dir ]]; then
    [[ $XDG_RUNTIME_DIR ]] &&
      echo "ble.sh: XDG_RUNTIME_DIR='$XDG_RUNTIME_DIR' is not a directory." >&2
    return 1
  fi
  if ! [[ -r $runtime_dir && -w $runtime_dir && -x $runtime_dir ]]; then
    [[ $XDG_RUNTIME_DIR ]] &&
      echo "ble.sh: XDG_RUNTIME_DIR='$XDG_RUNTIME_DIR' doesn't have a proper permission." >&2
    return 1
  fi

  ble/base/.create-user-directory _ble_base_run "$runtime_dir/blesh"
}
function ble/base/initialize-runtime-directory/.tmp {
  [[ -r /tmp && -w /tmp && -x /tmp ]] || return

  local tmp_dir=/tmp/blesh
  if [[ ! -d $tmp_dir ]]; then
    [[ ! -e $tmp_dir && -h $tmp_dir ]] && ble/bin/rm -f "$tmp_dir"
    if [[ -e $tmp_dir || -h $tmp_dir ]]; then
      echo "ble.sh: cannot create a directory '$tmp_dir' since there is already a file." >&2
      return 1
    fi
    ble/bin/mkdir -p "$tmp_dir" || return
    ble/bin/chmod a+rwxt "$tmp_dir" || return
  elif ! [[ -r $tmp_dir && -w $tmp_dir && -x $tmp_dir ]]; then
    echo "ble.sh: permision of '$tmp_dir' is not correct." >&2
    return 1
  fi

  ble/base/.create-user-directory _ble_base_run "$tmp_dir/$UID"
}
function ble/base/initialize-runtime-directory {
  ble/base/initialize-runtime-directory/.xdg && return
  ble/base/initialize-runtime-directory/.tmp && return

  # fallback
  local tmp_dir=$_ble_base/tmp
  if [[ ! -d $tmp_dir ]]; then
    ble/bin/mkdir -p "$tmp_dir" || return
    ble/bin/chmod a+rwxt "$tmp_dir" || return
  fi
  ble/base/.create-user-directory _ble_base_run "$tmp_dir/$UID"
}
if ! ble/base/initialize-runtime-directory; then
  echo "ble.sh: failed to initialize \$_ble_base_run." 1>&2
  return 1
fi

function ble/base/clean-up-runtime-directory {
  local file pid mark removed
  mark=() removed=()
  for file in "$_ble_base_run"/[1-9]*.*; do
    [[ -e $file ]] || continue
    pid=${file##*/}; pid=${pid%%.*}
    [[ ${mark[pid]} ]] && continue
    mark[pid]=1
    if ! kill -0 "$pid" &>/dev/null; then
      removed=("${removed[@]}" "$_ble_base_run/$pid."*)
    fi
  done
  ((${#removed[@]})) && ble/bin/rm -f "${removed[@]}"
}

# initialization time = 9ms (for 70 files)
if shopt -q failglob &>/dev/null; then
  shopt -u failglob
  ble/base/clean-up-runtime-directory
  shopt -s failglob
else
  ble/base/clean-up-runtime-directory
fi

##
## @var _ble_base_cache
##
##   環境毎の初期化ファイルを格納するディレクトリ。以下の手順で決定する。
##
##   1. ${XDG_CACHE_HOME:=$HOME/.cache} が存在すればその下に blesh を作成して使う。
##   2. $_ble_base/cache.d/$UID を使う。
##
function ble/base/initialize-cache-directory/.xdg {
  [[ $_ble_base != */out ]] || return

  local cache_dir=${XDG_CACHE_HOME:-$HOME/.cache}
  if [[ ! -d $cache_dir ]]; then
    [[ $XDG_CACHE_HOME ]] &&
      echo "ble.sh: XDG_CACHE_HOME='$XDG_CACHE_HOME' is not a directory." >&2
    return 1
  fi
  if ! [[ -r $cache_dir && -w $cache_dir && -x $cache_dir ]]; then
    [[ $XDG_CACHE_HOME ]] &&
      echo "ble.sh: XDG_CACHE_HOME='$XDG_CACHE_HOME' doesn't have a proper permission." >&2
    return 1
  fi

  ble/base/.create-user-directory _ble_base_cache "$cache_dir/blesh"
}
function ble/base/initialize-cache-directory {
  ble/base/initialize-cache-directory/.xdg && return

  # fallback
  local cache_dir=$_ble_base/cache.d
  if [[ ! -d $cache_dir ]]; then
    ble/bin/mkdir -p "$cache_dir" || return
    ble/bin/chmod a+rwxt "$cache_dir" || return

    # relocate an old cache directory if any
    local old_cache_dir=$_ble_base/cache
    if [[ -d $old_cache_dir && ! -h $old_cache_dir ]]; then
      mv "$old_cache_dir" "$cache_dir/$UID"
      ln -s "$cache_dir/$UID" "$old_cache_dir"
    fi
  fi
  ble/base/.create-user-directory _ble_base_cache "$cache_dir/$UID"
}
if ! ble/base/initialize-cache-directory; then
  echo "ble.sh: failed to initialize \$_ble_base_cache." 1>&2
  return 1
fi

#%if measure_load_time
}
#%end

#%x inc.r|@|src/util|

ble/bin/.freeze-utility-path "${_ble_init_posix_command_list[@]}" # <- this uses ble/util/assign.
#%if use_gawk
ble/bin/.freeze-utility-path gawk
#%end

#%x inc.r|@|src/decode|
#%x inc.r|@|src/color|
#%x inc.r|@|src/canvas|
#%x inc.r|@|src/edit|
#%x inc.r|@|lib/core-complete-def|
#%x inc.r|@|lib/core-syntax-def|
#------------------------------------------------------------------------------
# function .ble-time { echo "$*"; time "$@"; }

_ble_attached=
function ble-attach {
  [[ $_ble_attached ]] && return
  _ble_attached=1

  # 取り敢えずプロンプトを表示する
  ble/term/enter      # 3ms (起動時のずれ防止の為 stty)
  ble-edit/initialize # 3ms
  ble-edit/attach     # 0ms (_ble_edit_PS1 他の初期化)
  ble/textarea#redraw # 37ms
  ble/util/buffer.flush >&2

  # keymap 初期化
  local IFS=$' \t\n'
  ble-decode/initialize # 7ms
  ble-decode/reset-default-keymap # 264ms (keymap/vi.sh)
  if ! ble-decode/attach; then # 53ms
    _ble_attached=
    ble/term/finalize
    return 1
  fi
  _ble_edit_detach_flag= # do not detach or exit

  ble-edit/reset-history # 27s for bash-3.0

  # Note: ble-decode/{initialize,reset-default-keymap} 内で
  #   info を設定する事があるので表示する。
  ble-edit/info/default
  ble-edit/bind/.tail
}

function ble-detach {
  [[ $_ble_attached ]] || return
  _ble_attached=
  _ble_edit_detach_flag=${1:-detach} # schedule detach
}

_ble_base_attach_PROMPT_COMMAND=
function ble/base/attach-from-PROMPT_COMMAND {
  PROMPT_COMMAND=$_ble_base_attach_PROMPT_COMMAND
  ble-attach

  # Note: 何故か分からないが PROMPT_COMMAND から ble-attach すると
  # ble/bin/stty や ble/bin/mkfifo や tty 2> /dev/null などが
  # ジョブとして表示されてしまう。joblist.flush しておくと平気。
  # これで取り逃がすジョブもあるかもしれないが仕方ない。
  ble/util/joblist.flush &> /dev/null
  ble/util/joblist.check
}

function ble/base/process-blesh-arguments {
  local opt_attach=attach
  local opt_rcfile=
  local opt_error=
  while (($#)); do
    local arg=$1; shift
    case $arg in
    (--noattach|noattach)
      opt_attach=none ;;
    (--attach=*) opt_attach=${arg#*=} ;;
    (--attach)   opt_attach=$1; shift ;;
    (--rcfile=*|--init-file=*)
      opt_rcfile=${arg#*=} ;;
    (--rcfile|--init-file)
      opt_rcfile=$1; shift ;;
    (*)
      echo "ble.sh: unrecognized argument '$arg'" >&2
      opt_error=1
    esac
  done

  [[ $opt_rcfile ]] && source "$opt_rcfile"
  case $opt_attach in
  (attach) ble-attach ;;
  (prompt) _ble_base_attach_PROMPT_COMMAND=$PROMPT_COMMAND
           PROMPT_COMMAND=ble/base/attach-from-PROMPT_COMMAND ;;
  esac
  [[ ! $opt_error ]]
}

ble/base/process-blesh-arguments "$@"

IFS=$_ble_init_original_IFS
unset _ble_init_original_IFS

#%if measure_load_time
}
#%end

return 0
###############################################################################
