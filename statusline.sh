#!/usr/bin/env bash
# Claude Code statusline: model + reasoning effort, context-window usage,
# rate-limit windows (5h/7d), and prompt-cache hit rate + remaining TTL.
#
# Reads the statusLine JSON payload from stdin (see Claude Code docs for the
# schema) and prints one compact, fixed-width line with bright/bold ANSI
# colors (the separator and decorative glyphs are left plain so the colored
# values stand out against them). Every component is always shown: missing
# or null data renders as a padded "--" (or "??" for an unknown model)
# instead of being omitted, and every value is padded to a fixed width so
# segments never shift position between refreshes. A value that crosses a
# warn/crit threshold gets a background highlight covering exactly that
# padded field, not the whole segment.
export LC_NUMERIC=C
input=$(cat)

get() { echo "$input" | jq -r "$1 // empty" 2>/dev/null; }

# --- Colors ----------------------------------------------------------------
# Bright/bold ANSI colors for segments; the separator stays plain (no bold)
# so it reads as less prominent than the segments around it. WARN/CRIT are
# background highlights that override a segment's normal color per value.
RESET=$'\033[0m'
BRIGHT_MAGENTA=$'\033[1;95m'
BRIGHT_CYAN=$'\033[1;96m'
BRIGHT_YELLOW=$'\033[1;93m'
BRIGHT_GREEN=$'\033[1;92m'
BRIGHT_BLUE=$'\033[1;94m'
BRIGHT_WHITE=$'\033[1;97m'
GRAY=$'\033[90m'
WARN=$'\033[1;30;103m'   # bold black on yellow background
CRIT=$'\033[1;97;41m'    # bold white on red background
SEP="${GRAY} · ${RESET}"

# --- Warn/crit thresholds (tune here) --------------------------------------
CTX_WARN=60      CTX_CRIT=80      # context_window.used_percentage, % (>=)
LIMIT_WARN=70    LIMIT_CRIT=90    # each rate_limits.*.used_percentage, % (>=)
CACHE_WARN=70    CACHE_CRIT=40    # prompt_cache hit rate, % (<, lower=worse)
TTL_WARN=600     TTL_CRIT=120     # cache TTL remaining, seconds (<=, lower=worse; "expired"/<=0 counts as crit)

# --- Fixed field widths (keep segments from shifting between refreshes) ----
W_PCT=3      # percentages: "  5", " 42", "100"
W_TOK=6      # token counts: "84.0k", "1.0M"
W_TIME5=5    # 5h reset time: "HH:MM"
W_TIME7=9    # 7d reset time: "Dow HH:MM" (always includes weekday, even today)
W_TTL=6      # TTL remaining: "  42m", "1h06m", "   5s", "   exp"
W_MODEL=16   # model display name
W_EFFORT=6   # reasoning effort ("low"/"medium"/"high"/"xhigh"/"max")
W_COST=6     # session cost in USD: "  0.42", "123.45"

# --- Level classification (awk handles fractional percentages correctly) ---
# normal|warn|crit for a value where *higher* is worse (>= thresholds).
level_ge() {
    awk -v v="$1" -v w="$2" -v c="$3" 'BEGIN{
        if (v+0 >= c+0) print "crit"; else if (v+0 >= w+0) print "warn"; else print "normal"
    }'
}
# normal|warn|crit for a value where *lower* is worse (< thresholds, strict).
level_lt() {
    awk -v v="$1" -v w="$2" -v c="$3" 'BEGIN{
        if (v+0 < c+0) print "crit"; else if (v+0 < w+0) print "warn"; else print "normal"
    }'
}
# normal|warn|crit for a value where *lower* is worse (<= thresholds).
level_le() {
    awk -v v="$1" -v w="$2" -v c="$3" 'BEGIN{
        if (v+0 <= c+0) print "crit"; else if (v+0 <= w+0) print "warn"; else print "normal"
    }'
}
# Maps a level (normal|warn|crit) to its color, falling back to $2 (the
# segment's normal color) when the level is "normal".
level_color() {
    case "$1" in
        crit) printf '%s' "$CRIT" ;;
        warn) printf '%s' "$WARN" ;;
        *)    printf '%s' "$2" ;;
    esac
}
# Wraps already-padded plain ASCII text in a color + reset.
paint() { printf '%s%s%s' "$1" "$2" "$RESET"; }

# --- Padding helpers ---------------------------------------------------
# Pad (or truncate) plain ASCII text to an exact width. Multibyte glyphs
# (·, →, ⏱) are always glued on *outside* these calls, never passed through
# them, so byte-vs-display-column width never matters here.
padr() { printf '%*.*s' "$2" "$2" "$1"; }   # right-align (numbers)
padl() { printf '%-*.*s' "$2" "$2" "$1"; }  # left-align (labels/text)

# Compact large token counts, e.g. 84000 -> 84.0k, 1500000 -> 1.5M.
# "--" (unpadded; the caller pads it) when there is no value.
fmt_tokens() {
    local n="$1"
    if [ -z "$n" ]; then printf -- '--'; return; fi
    awk -v n="$n" 'BEGIN{
        if (n >= 1000000) printf "%.1fM", n/1000000
        else if (n >= 1000) printf "%.1fk", n/1000
        else printf "%d", n
    }'
}

# Epoch seconds -> short local time. $2=1 always includes the weekday (used
# for the 7-day window so its width never changes, even when the reset is
# today); $2=0 prints "HH:MM" only (used for the 5-hour window). Fails (and
# prints nothing) when the epoch is empty, so the caller can fall back.
fmt_reset() {
    local epoch="$1" with_weekday="$2"
    [ -z "$epoch" ] && return 1
    if [ "$with_weekday" = "1" ]; then
        date -d "@$epoch" "+%a %H:%M" 2>/dev/null
    else
        date -d "@$epoch" "+%H:%M" 2>/dev/null
    fi
}

# Remaining seconds until the cached prefix goes cold (may be negative once
# expired). Fails (prints nothing) when there is no expiry epoch.
ttl_remaining_seconds() {
    local expires="$1"
    [ -z "$expires" ] && return 1
    echo $(( expires - $(date +%s) ))
}

# Remaining seconds -> short duration string ("42m", "1h06m", "5s"), or
# "exp" once <= 0 (the caller pads/truncates this to width).
fmt_ttl() {
    local remaining="$1"
    if [ "$remaining" -le 0 ]; then
        printf 'exp'
    elif [ "$remaining" -ge 3600 ]; then
        printf '%dh%02dm' "$(( remaining / 3600 ))" "$(( (remaining % 3600) / 60 ))"
    elif [ "$remaining" -ge 60 ]; then
        printf '%dm' "$(( remaining / 60 ))"
    else
        printf '%ds' "$remaining"
    fi
}

# --- First line: identity + location (user@host · cwd · git branch) ---------
# Printed as its own line above the metrics; "--" when the value is unknown.
# Painted later, in the layout step, since cwd/branch may need truncating.
cwd=$(get '.workspace.current_dir // .cwd')
branch=""
if [ -n "$cwd" ]; then
    branch=$(GIT_OPTIONAL_LOCKS=0 git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null)
fi
ident="$(whoami)@$(hostname -s)"
# Show paths under $HOME as ~/... (only on a whole path-component match).
cwd_disp="${cwd:---}"
case "$cwd" in
    "$HOME")   cwd_disp='~' ;;
    "$HOME"/*) cwd_disp="~${cwd#"$HOME"}" ;;
esac

segments=()   # line 2: session state (model, context, cache)
billing=()    # line 3: account/billing (rate limits, cost)

# --- Model + reasoning effort: always shown; "??"/"--" when unknown --------
model=$(get '.model.display_name')
effort=$(get '.effort.level')
model_txt=$(padl "${model:-??}" "$W_MODEL")
effort_txt=$(padl "${effort:---}" "$W_EFFORT")
segments+=("$(paint "$BRIGHT_MAGENTA" "$model_txt")·$(paint "$BRIGHT_MAGENTA" "$effort_txt")")

# --- Context window usage ---------------------------------------------------
ctx_pct=$(get '.context_window.used_percentage')
ctx_used=$(get '.context_window.total_input_tokens')
ctx_size=$(get '.context_window.context_window_size')
if [ -n "$ctx_pct" ]; then
    ctx_pct_txt=$(padr "$(printf '%.0f' "$ctx_pct")" "$W_PCT")
    ctx_color=$(level_color "$(level_ge "$ctx_pct" "$CTX_WARN" "$CTX_CRIT")" "$BRIGHT_CYAN")
else
    ctx_pct_txt=$(padr '--' "$W_PCT")
    ctx_color="$BRIGHT_CYAN"
fi
ctx_used_txt=$(padr "$(fmt_tokens "$ctx_used")" "$W_TOK")
ctx_size_txt=$(padr "$(fmt_tokens "$ctx_size")" "$W_TOK")
segments+=("$(paint "$BRIGHT_CYAN" 'ctx ')$(paint "$ctx_color" "$ctx_pct_txt")$(paint "$BRIGHT_CYAN" "%(${ctx_used_txt}/${ctx_size_txt})")")

# --- Rate limits: 5-hour (session) and 7-day (weekly) usage windows --------
five_pct=$(get '.rate_limits.five_hour.used_percentage')
five_reset_epoch=$(get '.rate_limits.five_hour.resets_at')
if [ -n "$five_pct" ]; then
    five_pct_txt=$(padr "$(printf '%.0f' "$five_pct")" "$W_PCT")
    five_color=$(level_color "$(level_ge "$five_pct" "$LIMIT_WARN" "$LIMIT_CRIT")" "$BRIGHT_YELLOW")
else
    five_pct_txt=$(padr '--' "$W_PCT")
    five_color="$BRIGHT_YELLOW"
fi
five_reset_str=$(fmt_reset "$five_reset_epoch" 0) || five_reset_str='--:--'
five_reset_txt=$(padr "$five_reset_str" "$W_TIME5")
billing+=("$(paint "$BRIGHT_YELLOW" '5h ')$(paint "$five_color" "$five_pct_txt")$(paint "$BRIGHT_YELLOW" '%')→$(paint "$BRIGHT_YELLOW" "$five_reset_txt")")

seven_pct=$(get '.rate_limits.seven_day.used_percentage')
seven_reset_epoch=$(get '.rate_limits.seven_day.resets_at')
if [ -n "$seven_pct" ]; then
    seven_pct_txt=$(padr "$(printf '%.0f' "$seven_pct")" "$W_PCT")
    seven_color=$(level_color "$(level_ge "$seven_pct" "$LIMIT_WARN" "$LIMIT_CRIT")" "$BRIGHT_YELLOW")
else
    seven_pct_txt=$(padr '--' "$W_PCT")
    seven_color="$BRIGHT_YELLOW"
fi
seven_reset_str=$(fmt_reset "$seven_reset_epoch" 1) || seven_reset_str='--- --:--'
seven_reset_txt=$(padr "$seven_reset_str" "$W_TIME7")
billing+=("$(paint "$BRIGHT_YELLOW" '7d ')$(paint "$seven_color" "$seven_pct_txt")$(paint "$BRIGHT_YELLOW" '%')→$(paint "$BRIGHT_YELLOW" "$seven_reset_txt")")

# --- Prompt-cache hit rate + remaining TTL -----------------------------------
# TTL comes straight from the real schema field prompt_cache.expires_at (Unix
# epoch when the cached prefix goes cold; null if the last response reported
# no cache tokens) -- no need to derive it from a transcript timestamp.
cache_read=$(get '.context_window.current_usage.cache_read_input_tokens')
hit_ratio=$(get '.prompt_cache.hit_ratio')
expires_at=$(get '.prompt_cache.expires_at')

if [ -n "$hit_ratio" ]; then
    hit_pct_raw=$(awk -v r="$hit_ratio" 'BEGIN{printf "%.4f", r*100}')
    hit_pct_txt=$(padr "$(awk -v r="$hit_ratio" 'BEGIN{printf "%.0f", r*100}')" "$W_PCT")
    hit_color=$(level_color "$(level_lt "$hit_pct_raw" "$CACHE_WARN" "$CACHE_CRIT")" "$BRIGHT_GREEN")
else
    hit_pct_txt=$(padr '--' "$W_PCT")
    hit_color="$BRIGHT_GREEN"
fi
cache_read_txt=$(padr "$(fmt_tokens "$cache_read")" "$W_TOK")

ttl_remaining=$(ttl_remaining_seconds "$expires_at") || ttl_remaining=""
if [ -n "$ttl_remaining" ]; then
    ttl_str=$(fmt_ttl "$ttl_remaining")
    ttl_color=$(level_color "$(level_le "$ttl_remaining" "$TTL_WARN" "$TTL_CRIT")" "$BRIGHT_GREEN")
else
    ttl_str='--'
    ttl_color="$BRIGHT_GREEN"
fi
ttl_txt=$(padr "$ttl_str" "$W_TTL")

segments+=("$(paint "$BRIGHT_GREEN" 'cache ')$(paint "$hit_color" "$hit_pct_txt")$(paint "$BRIGHT_GREEN" "%(${cache_read_txt} rd) ")⏱$(paint "$ttl_color" "$ttl_txt")")

# --- Session cost ----------------------------------------------------------
# cost.total_cost_usd is Claude Code's client-side estimate at API list prices
# for this session only -- not what a subscription plan actually bills.
cost=$(get '.cost.total_cost_usd')
if [ -n "$cost" ]; then
    cost_txt=$(padr "$(printf '%.2f' "$cost")" "$W_COST")
else
    cost_txt=$(padr '--' "$W_COST")
fi
billing+=("$(paint "$BRIGHT_WHITE" "\$${cost_txt}")")

# --- Layout ------------------------------------------------------------------
# Fits the output to the terminal width. COLUMNS is set by Claude Code; keep a
# margin since the UI adds its own spacing and cuts overflowing lines to "…".
#   - fits:        all lines are stretched to the full width as aligned
#                  columns (line 1 on its own when a long path/branch would
#                  widen the columns too much to fit)
#   - too narrow:  each line wraps at the separators (never inside a
#                  segment); a path/branch wider than the terminal on its own
#                  is truncated with "…"
#   - no COLUMNS:  aligned columns, no stretching or wrapping
MARGIN=6
MIN_AVAIL=10
avail=0
if [ "${COLUMNS:-0}" -gt 0 ] 2>/dev/null; then
    avail=$(( COLUMNS - MARGIN ))
    (( avail < MIN_AVAIL )) && avail=$MIN_AVAIL
fi
SEP_W=3   # visible width of SEP (" · ")

# Visible width of a painted segment: strip ANSI codes, then count characters
# (not bytes -- the glyphs ·, → and ⏱ are multibyte in UTF-8).
vis_width() {
    local LC_ALL=C.UTF-8 s
    s=$(printf '%s' "$1" | sed $'s/\033\\[[0-9;]*m//g')
    printf '%d' "${#s}"
}
spaces() { printf '%*s' "$1" ''; }

# Truncate plain text to a max width with "…": truncate_left keeps the tail
# (paths: the innermost dirs matter), truncate_right keeps the head (branches:
# the prefix matters). Text that already fits is returned unchanged.
truncate_left() {
    local LC_ALL=C.UTF-8 s=$1
    if (( ${#s} <= $2 )); then printf '%s' "$s"; else printf '…%s' "${s: -$(( $2 - 1 ))}"; fi
}
truncate_right() {
    local LC_ALL=C.UTF-8 s=$1
    if (( ${#s} <= $2 )); then printf '%s' "$s"; else printf '%s…' "${s:0:$(( $2 - 1 ))}"; fi
}

# Greedy wrap: join segments with the separator, starting a new line whenever
# the next segment would overflow width $1.
wrap_segments() {
    local width=$1 line="" lw=0 s sw
    shift
    for s in "$@"; do
        sw=$(vis_width "$s")
        if [ -z "$line" ]; then
            line=$s; lw=$sw
        elif (( lw + SEP_W + sw <= width )); then
            line+="${SEP}${s}"; lw=$(( lw + SEP_W + sw ))
        else
            printf '%s\n' "$line"; line=$s; lw=$sw
        fi
    done
    [ -n "$line" ] && printf '%s\n' "$line"
}

# Print rows (given as names of arrays of painted segments) as aligned
# columns: each column is as wide as its widest entry across the rows, so the
# separators line up, and any width left over is spread across the gaps so
# the widest row ends at the right edge. Returns 1 without printing when the
# grid is wider than $1 (0 = unknown width: align only, no stretching).
print_grid() {
    local width=$1 r i ref s out ncols=0 grid extra gaps add
    local -a colw=() segs
    local -A segw=()
    shift
    for r in "$@"; do
        ref="$r[@]"; segs=("${!ref}")
        (( ${#segs[@]} > ncols )) && ncols=${#segs[@]}
        for i in "${!segs[@]}"; do
            segw[$r,$i]=$(vis_width "${segs[i]}")
            (( segw[$r,$i] > ${colw[i]:-0} )) && colw[i]=${segw[$r,$i]}
        done
    done
    grid=$(( (ncols - 1) * SEP_W ))
    for (( i = 0; i < ncols; i++ )); do grid=$(( grid + colw[i] )); done
    (( width > 0 && grid > width )) && return 1

    extra=0
    (( width > 0 )) && extra=$(( width - grid ))
    gaps=$(( ncols > 1 ? ncols - 1 : 1 ))
    for r in "$@"; do
        ref="$r[@]"; segs=("${!ref}")
        out=""
        for i in "${!segs[@]}"; do
            s=${segs[i]}
            # Pad every segment but the row's last (nothing follows it).
            if (( i < ${#segs[@]} - 1 )); then
                add=$(( extra / gaps + (i < extra % gaps ? 1 : 0) ))
                s+=$(spaces $(( colw[i] - segw[$r,$i] + add )))
            fi
            if [ -z "$out" ]; then out=$s; else out="${out}${SEP}${s}"; fi
        done
        printf '%s\n' "$out"
    done
}

# --- Line 1: user@host · cwd · branch ----------------------------------------
cwd_txt=$cwd_disp
branch_txt=${branch:---}
if (( avail > 0 )); then
    cwd_txt=$(truncate_left "$cwd_txt" "$avail")
    branch_txt=$(truncate_right "$branch_txt" "$avail")
fi
location=(
    "$(paint "$BRIGHT_GREEN" "$ident")"
    "$(paint "$BRIGHT_BLUE" "$cwd_txt")"
    "$(paint "$BRIGHT_YELLOW" "$branch_txt")"
)

# --- Output --------------------------------------------------------------------
# Preferred: all three lines as one aligned grid. A long path/branch can make
# that too wide; then line 1 is laid out on its own (branch pushed to the
# right edge, or wrapped) and only lines 2+3 share a grid -- or wrap too.
if ! print_grid "$avail" location segments billing; then
    left="${location[0]}${SEP}${location[1]}"
    left_w=$(vis_width "$left")
    br_w=$(vis_width "${location[2]}")
    if (( left_w + SEP_W + br_w <= avail )); then
        printf '%s%s%s\n' "$left" "$(spaces $(( avail - left_w - br_w )))" "${location[2]}"
    else
        wrap_segments "$avail" "${location[@]}"
    fi
    if ! print_grid "$avail" segments billing; then
        wrap_segments "$avail" "${segments[@]}"
        wrap_segments "$avail" "${billing[@]}"
    fi
fi
