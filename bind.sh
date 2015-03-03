#!/bin/bash

# 現在の bash の version に従って以下の二つのファイルを生成します:
#
#   $_ble_base/cache/ble-decode-bind.$_ble_bash.bind
#   $_ble_base/cache/ble-decode-bind.$_ble_bash.unbind
#

function ble-decode/generate-binder/append {
  local xarg="\"$1\":ble-decode-byte:bind $2; eval \"\$_ble_decode_bind_hook\""
  local rarg="$1"
  echo "builtin bind -x '${xarg//$apos/$APOS}'" >> "$fbind1"
  echo "builtin bind -r '${rarg//$apos/$APOS}'" >> "$fbind2"
}
function ble-decode/generate-binder/bind-s {
  local sarg="$1"
  echo "builtin bind '${sarg//$apos/$APOS}'" >> "$fbind1"
}
function ble-decode/generate-binder/bind-r {
  local rarg="$1"
  echo "builtin bind -r '${rarg//$apos/$APOS}'" >> "$fbind2"
}

function ble-decode/generate-binder {
  local fbind1="$_ble_base/cache/ble-decode-bind.$_ble_bash.bind"
  local fbind2="$_ble_base/cache/ble-decode-bind.$_ble_bash.unbind"

  echo -n "ble.sh: updating binders... $_ble_term_cr" >&2

  : > "$fbind1"
  : > "$fbind2"

  local apos=\' APOS="'\\''"
  local binder=ble-decode/generate-binder/append

  # ※bash-4.3 以降は bind -x の振る舞いがこれまでと色々と違う様だ
  #   何より 3 byte 以上の物にも bind できる様になった点が大きい (が ble.sh では使っていない)

  # * C-@ (0) は bash-4.3 では何故か bind -x すると
  #   bash: bash_execute_unix_command: コマンドのキーマップがありません
  #   bash_execute_unix_command: cannot find keymap for command
  #   になってしまう。"C-@ *" に全て割り当てても駄目である。
  #   bind '"\C-@":""' は使える様なので、UTF-8 の別表現に翻訳してしまう。
  local esc00="$((_ble_bash>=40300))"

  # * C-x (24) は直接 bind -x すると何故か bash が crash する。
  #   なので C-x は割り当てないで、
  #   代わりに C-x ? の組合せを全て登録する事にする。
  #   bash-3.1 ～ bash-4.2 で再現する。bash-4.3 では問題ない。
  local bind18XX="$((_ble_bash<40300))"

  # * bash-3 では "ESC *" の組合せも全部登録しておかないと駄目??
  #   (もしかすると bind -r 等に失敗していただけかも知れないが)
  local bind1BXX="$((_ble_bash<40100||40300<=_ble_bash))"

  # * bash-3.1
  #   ESC [ を bind -x で捕まえようとしてもエラーになるので、
  #   一旦 "ESC [" の ESC を UTF-8 2-byte code にしてから受信し直す。
  #   bash-3.1 で確認。bash-4.1 ではOK。他は未確認。
  # * bash-4.3
  #   ESC *, ESC [ *, etc を全部割り当てないと以下のエラーになる。
  #   bash_execute_unix_command: cannot find keymap for command
  #   これを避ける為に二つの方針がある
  #   1 全てを登録する方針 (bindAllSeq)
  #   2 ESC [ を別のシーケンスに割り当てる (esc1B5B)
  #   初め 1 の方法を用いていたが 2 でも動く事が分かったので 2 を使う。
  local esc1B5B="$((_ble_bash<40100||40300<=_ble_bash))"
  local bindAllSeq=0

  # * bash-4.1 では ESC ESC に bind すると
  #   bash_execute_unix_command: cannot find keymap for command
  #   が出るので ESC [ ^ に適当に redirect して ESC [ ^ を
  #   ESC ESC として解釈する様にする。
  local esc1B1B="$((40100<=_ble_bash&&_ble_bash<40300))"

  local i
  for ((i=0;i<256;i++)); do
    local ret; .ble-decode.c2dqs "$i"

    # *
    if ((i==0)); then
      # C-@
      if ((esc00)); then
        # UTF-8 2-byte code of 0 (■UTF-8依存)
        ble-decode/generate-binder/bind-s '"\C-@":"\xC0\x80"'
        ble-decode/generate-binder/bind-r '\C-@'
      else
        $binder "$ret" "$i"
      fi
    elif ((i==24)); then
      # C-x
      ((bind18XX)) || $binder "$ret" "$i"
    else
      $binder "$ret" "$i"
    fi

    # # C-@ * for bash-4.3 (2015-02-11) 無駄?
    # $binder "\\C-@$ret" "0 $i"

    # C-x *
    ((bind18XX)) && $binder "$ret" "24 $i"

    # ESC *
    if ((bind1BXX)); then
      # ESC [
      if ((i==91&&esc1B5B)); then
        # * obsoleted work around
        #   ESC [ を CSI (encoded in utf-8) に変換して受信する。
        #   受信した後で CSI を ESC [ に戻す。
        #   CSI = \u009B = utf8{\xC2\x9B} = utf8{\302\233}
        # printf 'bind %q' '"\e[":"\302\233"'               >> "$fbind1"
        # echo "ble-bind -f 'CSI' '.ble-decode-char 27 91'" >> "$fbind1"

        # ■UTF-8依存
        ble-decode/generate-binder/bind-s '"\e[":"\xC0\x9B["'
        ble-decode/generate-binder/bind-r '\e['
      else
        $binder "\\e$ret" "27 $i"
      fi
    fi

    # ESC ESC
    if ((i==27&&esc1B1B)); then
      # ESC ESC for bash-4.1
      ble-decode/generate-binder/bind-s '"\e\e":"\e[^"'
      echo "ble-bind -k 'ESC [ ^' __esc__"                >> "$fbind1"
      echo "ble-bind -f __esc__ '.ble-decode-char 27 27'" >> "$fbind1"
      ble-decode/generate-binder/bind-r '\e\e'
    fi
  done

  if ((bindAllSeq)); then
    # 決まったパターンのキーシーケンスは全て登録
    #   bash-4.3 で keymap が見付かりませんのエラーが出るので。
    # ※3文字以上の bind -x ができるのは bash-4.3 以降
    #   (bash-4.3-alpha で bugfix が入っている)
    echo 'source "$_ble_decode_bind_fbinder.bind"' >> "$fbind1"
    echo 'source "$_ble_decode_bind_fbinder.unbind"' >> "$fbind2"
  fi

  echo "ble.sh: updating binders... done" >&2
}

ble-decode/generate-binder