#!/bin/sh
# select.sh - TUI selector driven by pkglist.json -> custom_pkgs.json
# usage: ./select.sh [pkglist.json] [custom_pkgs.json]
# keys: up/down or j/k, 1-9 jump, Enter/right select, left/b back, q quit

PKGLIST=${1:-pkglist.json}
OUT=${2:-custom_pkgs.json}
TAB=$(printf '\t')
NL='
'
ESC=$(printf '\033')

[ -r "$PKGLIST" ] || { echo "cannot read $PKGLIST" >&2; exit 1; }
[ -t 0 ] || { echo "stdin must be a terminal" >&2; exit 1; }

# JSON -> TSV:  Q<TAB>node<TAB>question  /  O<TAB>node<TAB>label<TAB>value<TAB>next
parse() {
awk '
function isopt(d) { return d > 1 && type[d-1] == "[" && pkey[d-1] == "options" }
function val(v, lit,   k) {
  k = key[d]
  if (type[d] != "{") return
  if (lit && v == "null") v = ""
  if (isopt(d)) {
    if (k == "label") lab[d] = v
    else if (k == "value") vl[d] = v
    else if (k == "next") nx[d] = v
  } else {
    if (k == "id") nid[d] = v
    else if (k == "question") qs[d] = v
  }
}
{ s = s $0 "\n" }
END {
  n = length(s); d = 0; i = 1
  while (i <= n) {
    c = substr(s, i, 1)
    if (c == "\"") {
      j = i + 1; str = ""
      while (j <= n) {
        ch = substr(s, j, 1)
        if (ch == "\\") { str = str ch substr(s, j+1, 1); j += 2; continue }
        if (ch == "\"") break
        str = str ch; j++
      }
      i = j + 1
      if (type[d] == "{" && expkey[d]) { key[d] = str; expkey[d] = 0 }
      else val(str, 0)
    } else if (c == "{" || c == "[") {
      ak = (d > 0) ? key[d] : ""
      d++; type[d] = c; pkey[d] = ak; key[d] = ""
      expkey[d] = (c == "{")
      lab[d] = vl[d] = nx[d] = ku[d] = nid[d] = qs[d] = ""
      i++
    } else if (c == "}" || c == "]") {
      if (c == "}") {
        if (isopt(d)) print "O\t" nid[d-2] "\t" lab[d] "\t" vl[d] "\t" nx[d] "\t" ku[d]
        else if (nid[d] != "" && qs[d] != "") print "Q\t" nid[d] "\t" qs[d]
      }
      d--; i++
    } else if (c == ":") { expkey[d] = 0; i++ }
    else if (c == ",") { if (type[d] == "{") expkey[d] = 1; i++ }
    else if (c ~ /[ \t\r\n]/) i++
    else {
      j = i; lit = ""
      while (j <= n) { ch = substr(s, j, 1); if (ch ~ /[],} \t\r\n]/) break; lit = lit ch; j++ }
      i = j; val(lit, 1)
    }
  }
}'
}

TABLE=$(parse < "$PKGLIST")
[ -n "$TABLE" ] || { echo "no nodes parsed from $PKGLIST" >&2; exit 1; }

OLD=$(stty -g)
cleanup() { stty "$OLD"; printf '\033[?25h'; }
trap cleanup EXIT
trap 'exit 130' INT TERM
stty -icanon -echo min 1 time 0
printf '\033[?25l'

readkey() {
  KEY=$(dd bs=1 count=1 2>/dev/null)
  if [ "$KEY" = "$ESC" ]; then
    stty min 0 time 1
    r=$(dd bs=1 count=2 2>/dev/null)
    stty min 1 time 0
    case "$r" in
      "[A"|"OA") KEY=up ;;
      "[B"|"OB") KEY=down ;;
      "[C"|"OC") KEY=right ;;
      "[D"|"OD") KEY=left ;;
      *) KEY=q ;;
    esac
  fi
}

draw() {
  printf '\033[H\033[J'
  printf '\033[1m%s\033[0m\n\n' "$q"
  printf '%s\n' "$opts" | awk -F'\t' -v s="$sel" '{
    l = $1; gsub(/\\"/, "\"", l)
    if (NR == s) printf "\033[7m > %s \033[0m\n", l
    else printf "   %s\n", l }'
  printf '\n\033[2mup/down j/k move | Enter select | left/b back | q quit\033[0m\n'
}

node=root
SEL=""
while [ -n "$node" ]; do
  q=$(printf '%s\n' "$TABLE" | awk -F'\t' -v n="$node" '$1=="Q"&&$2==n{print $3; exit}')
  opts=$(printf '%s\n' "$TABLE" | awk -F'\t' -v n="$node" '$1=="O"&&$2==n{print $3 "\t" $4 "\t" $5 "\t" $6}')
  if [ -z "$opts" ]; then
    printf '\033[H\033[J'; echo "node '$node' has no options" >&2; exit 1
  fi
  q=$(printf '%s' "$q" | sed 's/\\"/"/g')
  count=$(printf '%s\n' "$opts" | wc -l | tr -d ' ')
  sel=1
  action=""
  while [ -z "$action" ]; do
    draw
    readkey
    case "$KEY" in
      up|k)   [ "$sel" -gt 1 ] && sel=$((sel-1)) ;;
      down|j) [ "$sel" -lt "$count" ] && sel=$((sel+1)) ;;
      [1-9])  [ "$KEY" -le "$count" ] && sel=$KEY ;;
      ""|right|l) action=pick ;;
      left|b) action=back ;;
      q|Q)    printf '\033[H\033[J'; echo "aborted, nothing written"; exit 1 ;;
    esac
  done

  if [ "$action" = back ]; then
    if [ -n "$SEL" ]; then
      node=$(printf '%s\n' "$SEL" | tail -n 1 | cut -f1)
      SEL=$(printf '%s\n' "$SEL" | sed '$d')
    fi
    continue
  fi

  line=$(printf '%s\n' "$opts" | sed -n "${sel}p")
  value=$(printf '%s' "$line" | cut -f2)
  next=$(printf '%s' "$line" | cut -f3)
  kupd=$(printf '%s' "$line" | cut -f4)
  SEL="${SEL:+$SEL$NL}$node$TAB$value$TAB$kupd"
  node=$next
done

printf '%s\n' "$SEL" | awk -F'\t' '
{ a[NR] = $1; b[NR] = $2; if ($3 != "") ku = $3 }
END {
  print "\"pkgs\": {"
  for (i = 1; i <= NR; i++)
    printf "  \"%s\": \"%s\"%s\n", a[i], b[i], (i < NR ? "," : "")
  print "}"
}' > "$OUT"

printf '\033[H\033[J'
echo "wrote $OUT:"
cat "$OUT"
