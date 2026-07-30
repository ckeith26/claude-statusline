#!/usr/bin/env bash
# Claude Code Status Line - Catppuccin Macchiato theme
# Line 1: project, git branch + diff stats, model, context gauge
# Line 2: weekly gauge, current gauge, session cost

# --- Colors (Catppuccin Macchiato truecolor) ---
R='\033[0m'                           # reset
C_RED='\033[38;2;237;135;150m'        # #ed8796 - project name
C_GREEN='\033[38;2;166;218;149m'      # #a6da95 - git branch
C_AMBER='\033[38;2;238;212;159m'      # #eed49f - diff stats, cost
C_PURPLE='\033[38;2;198;160;246m'     # #c6a0f6 - model
C_TEAL='\033[38;2;139;213;202m'       # #8bd5ca - healthy gauge fill
C_PEACH='\033[38;2;245;169;127m'      # #f5a97f - bypass mode
C_MUTED='\033[38;2;110;115;141m'      # #6e738d - labels, hints
C_OVERLAY='\033[38;2;54;58;79m'       # #363a4f - empty gauge, separators

# --- Read JSON from stdin ---
input=$(cat)
if [ -z "$input" ]; then
  printf "Claude"
  exit 0
fi

# --- Parse fields ---
project_dir=$(echo "$input" | jq -r '.workspace.project_dir // .workspace.current_dir // empty')
[ -z "$project_dir" ] || [ "$project_dir" = "null" ] && project_dir=$(echo "$input" | jq -r '.cwd // empty')
project_name=$(basename "${project_dir:-Claude}")
# Short version for narrow tiers
if [ ${#project_name} -gt 12 ]; then
  project_short="${project_name:0:10}.."
else
  project_short="$project_name"
fi

model_full=$(echo "$input" | jq -r '.model.display_name // "Claude"' | sed 's/ context//')
model_name=$(echo "$model_full" | sed 's/^\([A-Z][a-z]\)[a-z]*/\1/')
# Tiny: drop version number, e.g. "Op (1M)"
model_tiny=$(echo "$model_name" | sed 's/ [0-9][0-9.]*//')
session_cost=$(echo "$input" | jq -r '.cost.total_cost_usd // 0')

# --- Git info ---
git_branch=""
diff_str=""
if [ -n "$project_dir" ] && git -C "$project_dir" rev-parse --git-dir >/dev/null 2>&1; then
  git_branch=$(git -C "$project_dir" rev-parse --abbrev-ref HEAD 2>/dev/null)
  git_status=$(git -C "$project_dir" --no-optional-locks status --porcelain 2>/dev/null)
  if [ -n "$git_status" ]; then
    m=$(echo "$git_status" | grep -c '^ M\|^M' || true)
    a=$(echo "$git_status" | grep -c '^A\|^??' || true)
    d=$(echo "$git_status" | grep -c '^ D\|^D' || true)
    parts=()
    [ "$m" -gt 0 ] 2>/dev/null && parts+=("${m}M")
    [ "$a" -gt 0 ] 2>/dev/null && parts+=("${a}A")
    [ "$d" -gt 0 ] 2>/dev/null && parts+=("${d}D")
    if [ ${#parts[@]} -gt 0 ]; then
      diff_str=$(IFS=','; echo "${parts[*]}")
    fi
  fi
fi

# --- Helpers ---
format_tokens() {
  local t=$1
  if [ "$t" -ge 1000000 ] 2>/dev/null; then
    awk "BEGIN {printf \"%.0fM\", $t / 1000000}"
  elif [ "$t" -ge 10000 ] 2>/dev/null; then
    awk "BEGIN {printf \"%.0fK\", $t / 1000}"
  elif [ "$t" -ge 1000 ] 2>/dev/null; then
    awk "BEGIN {printf \"%.1fK\", $t / 1000}"
  else
    echo "$t"
  fi
}

# Gauge with color thresholds using background-colored spaces (avoids Unicode width glitches).
# Args: pct, mode (context|budget)
gauge() {
  local pct=$1 mode=${2:-context}
  [ "$pct" -lt 0 ] 2>/dev/null && pct=0
  [ "$pct" -gt 100 ] 2>/dev/null && pct=100
  local nf=$((pct * 10 / 100)) ne
  [ "$pct" -gt 0 ] && [ "$nf" -eq 0 ] && nf=1
  [ "$nf" -gt 10 ] && nf=10
  ne=$((10 - nf))

  local fill_bg
  if [ "$mode" = "budget" ]; then
    if [ "$pct" -lt 50 ]; then fill_bg='\033[48;2;166;218;149m'      # green bg
    elif [ "$pct" -lt 80 ]; then fill_bg='\033[48;2;238;212;159m'    # amber bg
    else fill_bg='\033[48;2;237;135;150m'                             # red bg
    fi
  else
    if [ "$pct" -lt 40 ]; then fill_bg='\033[48;2;139;213;202m'      # teal bg
    elif [ "$pct" -lt 70 ]; then fill_bg='\033[48;2;238;212;159m'    # amber bg
    else fill_bg='\033[48;2;237;135;150m'                             # red bg
    fi
  fi
  local empty_bg='\033[48;2;54;58;79m'  # overlay bg

  local filled="" empty=""
  for ((i=0; i<nf; i++)); do filled+=" "; done
  for ((i=0; i<ne; i++)); do empty+=" "; done
  printf "%b%s%b%s%b" "$fill_bg" "$filled" "$empty_bg" "$empty" "$R"
}

fmt_reset() {
  local iso="$1"
  [ -z "$iso" ] || [ "$iso" = "null" ] && return

  # Strip fractional seconds: "2026-03-13T19:00:00.511778+00:00" -> "2026-03-13T19:00:00+00:00"
  local clean
  if [[ "$iso" == *"."* ]]; then
    local before_dot="${iso%%.*}"
    local after_dot="${iso#*.}"
    # after_dot is like "511778+00:00" or "511778Z"
    local tz_part=""
    if [[ "$after_dot" == *"+"* ]]; then
      tz_part="+${after_dot#*+}"
    elif [[ "$after_dot" == *"-"* ]]; then
      tz_part="-${after_dot#*-}"
    elif [[ "$after_dot" == *"Z"* ]]; then
      tz_part="Z"
    fi
    clean="${before_dot}${tz_part}"
  else
    clean="$iso"
  fi

  # Convert ISO with any timezone offset to epoch
  # Extract the datetime and offset parts
  local dt_part tz_part=""
  if [[ "$clean" == *"Z" ]]; then
    dt_part="${clean%%Z*}"
    tz_part="+00:00"
  elif [[ "$clean" =~ (.+)([+-][0-9]{2}:[0-9]{2})$ ]]; then
    dt_part="${BASH_REMATCH[1]}"
    tz_part="${BASH_REMATCH[2]}"
  else
    dt_part="$clean"
  fi

  local epoch
  if [ -n "$tz_part" ]; then
    # Parse datetime as-is, then adjust for offset to get true UTC epoch
    local raw_epoch
    raw_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$dt_part" "+%s" 2>/dev/null)
    if [ -n "$raw_epoch" ]; then
      # raw_epoch interpreted the time as local; we need to undo that and apply the real offset
      # Get local UTC offset in seconds
      local local_off_str local_off_sec
      local_off_str=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$dt_part" "+%z" 2>/dev/null)
      local sign_l=${local_off_str:0:1} hh_l=${local_off_str:1:2} mm_l=${local_off_str:3:2}
      local_off_sec=$(( (10#$hh_l * 3600 + 10#$mm_l * 60) ))
      [ "$sign_l" = "-" ] && local_off_sec=$(( -local_off_sec ))
      # Parse the actual offset from the timestamp (strip colon: +00:00 -> +0000)
      local tz_flat="${tz_part/:/}"
      local sign_t=${tz_flat:0:1} hh_t=${tz_flat:1:2} mm_t=${tz_flat:3:2}
      local tz_off_sec=$(( (10#$hh_t * 3600 + 10#$mm_t * 60) ))
      [ "$sign_t" = "-" ] && tz_off_sec=$(( -tz_off_sec ))
      # Correct: raw_epoch assumed local offset, but real offset is tz_off_sec
      epoch=$(( raw_epoch + local_off_sec - tz_off_sec ))
    fi
  fi
  # Fallback: GNU date handles ISO offsets natively
  [ -z "$epoch" ] && epoch=$(date -d "$clean" "+%s" 2>/dev/null)
  [ -z "$epoch" ] && return

  # Format in local time
  local today_date reset_date time_str
  today_date=$(date "+%Y-%m-%d")
  reset_date=$(date -r "$epoch" "+%Y-%m-%d" 2>/dev/null)
  time_str=$(date -r "$epoch" "+%-I:%M%p" 2>/dev/null | tr 'A-Z' 'a-z' | sed 's/:00//')
  if [ "$reset_date" = "$today_date" ]; then
    printf "%s" "$time_str"
  else
    local mode="${2:-short}"
    local md
    if [ "$mode" = "full" ]; then
      md=$(date -r "$epoch" "+%B %-d" 2>/dev/null)
    else
      md=$(date -r "$epoch" "+%-m/%-d" 2>/dev/null)
    fi
    printf "%s, %s" "$time_str" "$md"
  fi
}

# --- Context window ---
ctx_pct=0
ctx_used=0
ctx_max=200000
ctx_used_pct=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
if [ -n "$ctx_used_pct" ] && [ "$ctx_used_pct" != "null" ]; then
  ctx_pct=$(printf "%.0f" "$ctx_used_pct")
fi
ctx_max=$(echo "$input" | jq -r '.context_window.context_window_size // 200000')
ctx_usage=$(echo "$input" | jq '.context_window.current_usage // empty')
if [ -n "$ctx_usage" ] && [ "$ctx_usage" != "null" ] && [ "$ctx_usage" != "" ]; then
  ctx_used=$(echo "$ctx_usage" | jq '(.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0)' 2>/dev/null)
  [ -z "$ctx_used" ] && ctx_used=0
  if [ "$ctx_pct" -eq 0 ] && [ "$ctx_max" -gt 0 ] 2>/dev/null; then
    ctx_pct=$((ctx_used * 100 / ctx_max))
  fi
fi
# If we still don't have used tokens, estimate from percentage
if [ "$ctx_used" -eq 0 ] && [ "$ctx_pct" -gt 0 ] 2>/dev/null; then
  ctx_used=$((ctx_pct * ctx_max / 100))
fi

ctx_used_fmt=$(format_tokens "$ctx_used")
ctx_max_fmt=$(format_tokens "$ctx_max")
ctx_gauge=$(gauge "$ctx_pct" context)

# --- OAuth usage API (cached) ---
USAGE_CACHE="/tmp/claude/statusline-usage-cache.json"
mkdir -p /tmp/claude 2>/dev/null

get_oauth_token() {
  if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    echo "$CLAUDE_CODE_OAUTH_TOKEN"; return 0
  fi
  if command -v security >/dev/null 2>&1; then
    local blob
    blob=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)
    if [ -n "$blob" ]; then
      local tok
      tok=$(echo "$blob" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
      if [ -n "$tok" ] && [ "$tok" != "null" ]; then echo "$tok"; return 0; fi
    fi
  fi
  local cf="${HOME}/.claude/.credentials.json"
  if [ -f "$cf" ]; then
    local tok
    tok=$(jq -r '.claudeAiOauth.accessToken // empty' "$cf" 2>/dev/null)
    if [ -n "$tok" ] && [ "$tok" != "null" ]; then echo "$tok"; return 0; fi
  fi
  echo ""
}

USAGE_LOCK="/tmp/claude/statusline-usage.lock"
CACHE_TTL=60  # 1 minute; embedded timestamp controls freshness

now=$(date +%s)
usage_data=""
needs_refresh=true
if [ -f "$USAGE_CACHE" ]; then
  usage_data=$(cat "$USAGE_CACHE" 2>/dev/null)
  fetched_at=$(echo "$usage_data" | jq -r '.fetched_at // 0' 2>/dev/null)
  cache_age=$((now - fetched_at))
  [ "$cache_age" -lt "$CACHE_TTL" ] && needs_refresh=false
fi
if $needs_refresh; then
  # Clean up stale lock (older than 15 seconds means the holder crashed)
  if [ -f "$USAGE_LOCK" ]; then
    lock_age=$(( now - $(stat -f%m "$USAGE_LOCK" 2>/dev/null || echo 0) ))
    [ "$lock_age" -gt 15 ] && rm -f "$USAGE_LOCK"
  fi
  # Lock prevents multiple sessions from refreshing simultaneously
  if ( set -o noclobber; echo $$ > "$USAGE_LOCK" ) 2>/dev/null; then
    trap 'rm -f "$USAGE_LOCK"' EXIT
    tok=$(get_oauth_token)
    if [ -n "$tok" ] && [ "$tok" != "null" ]; then
      resp=$(curl -s --max-time 5 \
        -H "Accept: application/json" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $tok" \
        -H "anthropic-beta: oauth-2025-04-20" \
        -H "User-Agent: claude-code/2.1.74" \
        "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)
      if [ -n "$resp" ] && echo "$resp" | jq -e '.five_hour' >/dev/null 2>&1; then
        usage_data=$(echo "$resp" | jq --argjson ts "$now" '. + {fetched_at: $ts}')
        echo "$usage_data" > "${USAGE_CACHE}.$$"
        mv -f "${USAGE_CACHE}.$$" "$USAGE_CACHE"
      fi
    fi
    rm -f "$USAGE_LOCK"
    trap - EXIT
  fi
  # Fall back to stale cache (another session is refreshing, or refresh failed)
  [ -z "$usage_data" ] && [ -f "$USAGE_CACHE" ] && usage_data=$(cat "$USAGE_CACHE" 2>/dev/null)
fi

# --- Parse usage data ---
weekly_pct=0; weekly_reset=""
current_pct=0; current_reset=""
extra_pct=0; extra_used=""; extra_limit=""; extra_enabled=false
if [ -n "$usage_data" ]; then
  weekly_pct=$(echo "$usage_data" | jq -r '.seven_day.utilization // 0' | awk '{printf "%.0f", $1}')
  current_pct=$(echo "$usage_data" | jq -r '.five_hour.utilization // 0' | awk '{printf "%.0f", $1}')
  [ "$weekly_pct" -gt 100 ] 2>/dev/null && weekly_pct=100
  [ "$current_pct" -gt 100 ] 2>/dev/null && current_pct=100
  weekly_reset_iso=$(echo "$usage_data" | jq -r '.seven_day.resets_at // empty')
  weekly_reset=$(fmt_reset "$weekly_reset_iso" short)
  weekly_reset_full=$(fmt_reset "$weekly_reset_iso" full)
  current_reset=$(fmt_reset "$(echo "$usage_data" | jq -r '.five_hour.resets_at // empty')" short)
  # Extra usage (only show if enabled and budget > 0)
  extra_enabled=$(echo "$usage_data" | jq -r '.extra_usage.is_enabled // false')
  if [ "$extra_enabled" = "true" ]; then
    extra_limit_raw=$(echo "$usage_data" | jq -r '.extra_usage.monthly_limit // 0')
    if [ "$extra_limit_raw" -gt 0 ] 2>/dev/null; then
      extra_pct=$(echo "$usage_data" | jq -r '.extra_usage.utilization // 0' | awk '{printf "%.0f", $1}')
      [ "$extra_pct" -gt 100 ] 2>/dev/null && extra_pct=100
      extra_used_raw=$(echo "$usage_data" | jq -r '.extra_usage.used_credits // 0')
      extra_remaining=$(echo "$extra_used_raw $extra_limit_raw" | awk '{printf "$%.0f", ($2-$1)/100}')
    else
      extra_enabled=false
    fi
  fi
fi

# --- Separator ---
sep=" ${C_OVERLAY}|${R} "

# =====================================================================
# Width-adaptive layout: detect terminal width, pick best tier
# =====================================================================

# stdin is JSON, so tput/stty need /dev/tty to reach the real terminal
term_cols=$(tput cols < /dev/tty 2>/dev/null || stty size < /dev/tty 2>/dev/null | awk '{print $2}' || echo 80)
# Right-side Claude Code chrome (effort, tokens, version) shares the first line.
avail=$((term_cols - 35))

# Color-coded percentage (no gauge bar). Args: pct, mode
cpct() {
  local pct=$1 mode=${2:-context}
  local color
  if [ "$mode" = "budget" ]; then
    if [ "$pct" -lt 50 ]; then color="$C_GREEN"
    elif [ "$pct" -lt 80 ]; then color="$C_AMBER"
    else color="$C_RED"
    fi
  else
    if [ "$pct" -lt 40 ]; then color="$C_TEAL"
    elif [ "$pct" -lt 70 ]; then color="$C_AMBER"
    else color="$C_RED"
    fi
  fi
  printf "%b%d%%%b" "$color" "$pct" "$R"
}

# Background-color gauge. Args: pct, width, mode
bgauge() {
  local pct=$1 w=${2:-8} mode=${3:-context}
  [ "$pct" -lt 0 ] 2>/dev/null && pct=0
  [ "$pct" -gt 100 ] 2>/dev/null && pct=100
  local nf=$((pct * w / 100))
  [ "$pct" -gt 0 ] && [ "$nf" -eq 0 ] && nf=1
  [ "$nf" -gt "$w" ] && nf=$w
  local ne=$((w - nf))
  local fill_bg
  if [ "$mode" = "budget" ]; then
    if [ "$pct" -lt 50 ]; then fill_bg='\033[48;2;166;218;149m'
    elif [ "$pct" -lt 80 ]; then fill_bg='\033[48;2;238;212;159m'
    else fill_bg='\033[48;2;237;135;150m'
    fi
  else
    if [ "$pct" -lt 40 ]; then fill_bg='\033[48;2;139;213;202m'
    elif [ "$pct" -lt 70 ]; then fill_bg='\033[48;2;238;212;159m'
    else fill_bg='\033[48;2;237;135;150m'
    fi
  fi
  local empty_bg='\033[48;2;54;58;79m'
  local filled="" empty=""
  for ((i=0; i<nf; i++)); do filled+=" "; done
  for ((i=0; i<ne; i++)); do empty+=" "; done
  printf "%b%s%b%s%b" "$fill_bg" "$filled" "$empty_bg" "$empty" "$R"
}

# --- Build single-line output based on available width ---
# All tiers are single-line (multi-line is unreliable in Claude Code).
# Content widths measured from actual visible characters:
#   FULL:    project  branch [diffs] | model | gauge ctx% | c% | w%  (~87 chars)
#   WIDE:    project  branch | model | ctx% | c% | w%                (~64 chars)
#   COMPACT: project  branch [diffs] | ctx% | c% | w%               (~52 chars)
#   NARROW:  project  branch | ctx% | c% | w%                       (~40 chars)
#   ULTRA:   branch ctx% c% w%                                      (~16 chars)

# Precompute widths for tier selection
# WIDE uses short model name (Op 4.6 (1M))
model_line_vis=$((${#project_name} + 2 + ${#git_branch} + 3 + ${#model_name} + 3 + 3 + 3 + 5 + 3 + 4))
# FULL uses full model name (Opus 4.6 (1M)) + gauge
full_model_vis=$((${#project_name} + 2 + ${#git_branch} + 3 + ${#model_full} + 3 + 10 + 1 + 4))
full_line_vis=$full_model_vis

# --- nightshift: running PMs (optional integration) ---
# Renders nothing unless the repo has a nightshift registry with active PMs, so this is
# invisible for everyone who does not use it. No dependency on nightshift being installed:
# it only reads files, and their absence is the normal case.
#   ns >2          two PMs working
#   ns !1 >1       one wants a decision, one working
#   ns x1 >1 $4.20 one crashed, one working, spend so far
ns_segment() {
  local reg="$1/.claude/worktrees/registry"
  [ -d "$reg" ] || return 0
  NS_REG="$reg" python3 -c '
import glob, json, os, re
reg = os.environ["NS_REG"]
run = needs = dead = 0
cost = 0.0
for p in glob.glob(os.path.join(reg, "*.json")):
    try:
        d = json.load(open(p))
    except Exception:
        continue
    st = (d.get("status") or "").upper()
    if st in ("DONE", "STOPPED"):
        continue
    wt = d.get("worktree", "")
    if not wt or not os.path.isdir(wt):
        continue
    cost += float(d.get("cost_usd") or 0)
    lst = ""
    try:
        with open(os.path.join(wt, "LEDGER.md")) as f:
            for _ in range(40):
                line = f.readline()
                if not line:
                    break
                m = re.match(r"^STATUS:\s*(\S+)", line)
                if m:
                    lst = m.group(1)
                    break
    except Exception:
        pass
    if lst == "READY-FOR-HUMAN":
        needs += 1
    elif st == "CRASHED":
        dead += 1
    else:
        run += 1
if not (run or needs or dead):
    raise SystemExit
p = []
if needs: p.append("\033[38;2;238;212;159m!%d\033[0m" % needs)
if dead:  p.append("\033[38;2;237;135;150mx%d\033[0m" % dead)
if run:   p.append("\033[38;2;139;213;202m>%d\033[0m" % run)
if cost:  p.append("\033[38;2;110;115;141m$%.2f\033[0m" % cost)
print("\033[38;2;110;115;141mns\033[0m " + " ".join(p), end="")
' 2>/dev/null || true
}
NS=$(ns_segment "$project_dir")

if [ "$avail" -ge 88 ] && [ "$avail" -ge "$full_line_vis" ]; then
  # FULL: line 1 = project + branch + diffs + model + ctx gauge
  #       line 2 = c gauge + reset | w gauge + reset | ext
  line1="${C_RED}${project_name}${R}"
  [ -n "$git_branch" ] && line1+="  ${C_GREEN}${git_branch}${R}"
  [ -n "$diff_str" ] && line1+=" ${C_AMBER}[${diff_str}]${R}"
  line1+="${sep}${C_PURPLE}${model_full}${R}"
  line1+="${sep}$(bgauge "$ctx_pct" 8 context) $(cpct $ctx_pct context)"
  line2="${C_MUTED}current${R} $(bgauge "$current_pct" 6 budget) $(cpct $current_pct budget)"
  [ -n "$current_reset" ] && line2+=" ${C_MUTED}${current_reset}${R}"
  line2+="${sep}${C_MUTED}weekly${R} $(bgauge "$weekly_pct" 6 budget) $(cpct $weekly_pct budget)"
  [ -n "$weekly_reset_full" ] && line2+=" ${C_MUTED}${weekly_reset_full}${R}"
  if [ "$extra_enabled" = "true" ]; then
    line2+="${sep}${C_MUTED}extra${R} $(bgauge "$extra_pct" 6 budget) ${C_MUTED}${extra_remaining} left${R}"
  fi
  [ -n "$NS" ] && line1+="${sep}${NS}"
  printf '%b\n%b' "$line1" "$line2"

elif [ "$avail" -ge 88 ] && [ "$avail" -ge "$model_line_vis" ]; then
  # WIDE: line 1 = project + branch + model + ctx%
  #       line 2 = usage gauges + resets
  line1="${C_RED}${project_name}${R}"
  [ -n "$git_branch" ] && line1+="  ${C_GREEN}${git_branch}${R}"
  [ -n "$diff_str" ] && line1+=" ${C_AMBER}[${diff_str}]${R}"
  line1+="${sep}${C_PURPLE}${model_name}${R}"
  line1+="${sep}$(cpct $ctx_pct context)"
  line2="${C_MUTED}c${R} $(bgauge "$current_pct" 6 budget) $(cpct $current_pct budget)"
  [ -n "$current_reset" ] && line2+=" ${C_MUTED}${current_reset}${R}"
  line2+="${sep}${C_MUTED}w${R} $(bgauge "$weekly_pct" 6 budget) $(cpct $weekly_pct budget)"
  [ -n "$weekly_reset" ] && line2+=" ${C_MUTED}${weekly_reset}${R}"
  if [ "$extra_enabled" = "true" ]; then
    line2+="${sep}${C_MUTED}ext${R} $(bgauge "$extra_pct" 6 budget) ${C_MUTED}${extra_remaining} left${R}"
  fi
  [ -n "$NS" ] && line1+="${sep}${NS}"
  printf '%b\n%b' "$line1" "$line2"

elif [ "$avail" -ge 56 ]; then
  # COMPACT: line 1 = short project + branch + model_tiny + ctx gauge
  #          line 2 = c% + w% with gauges
  line1="${C_RED}${project_short}${R}"
  [ -n "$git_branch" ] && line1+="  ${C_GREEN}${git_branch}${R}"
  line1+="${sep}${C_PURPLE}${model_tiny}${R}"
  line1+="${sep}$(bgauge "$ctx_pct" 8 context) $(cpct $ctx_pct context)"
  line2="${C_MUTED}c${R} $(bgauge "$current_pct" 6 budget) $(cpct $current_pct budget)"
  [ -n "$current_reset" ] && line2+=" ${C_MUTED}${current_reset}${R}"
  line2+="${sep}${C_MUTED}w${R} $(bgauge "$weekly_pct" 6 budget) $(cpct $weekly_pct budget)"
  if [ "$extra_enabled" = "true" ]; then
    line2+="${sep}${C_MUTED}ext${R} $(bgauge "$extra_pct" 6 budget) ${C_MUTED}${extra_remaining} left${R}"
  fi
  [ -n "$NS" ] && line1+="${sep}${NS}"
  printf '%b\n%b' "$line1" "$line2"

elif [ "$avail" -ge 36 ]; then
  # NARROW: 1 line, short project + model_tiny + percentages
  line="${C_RED}${project_short}${R}"
  [ -n "$git_branch" ] && line+="  ${C_GREEN}${git_branch}${R}"
  line+="${sep}${C_PURPLE}${model_tiny}${R}"
  line+="${sep}$(cpct $ctx_pct context)"
  line+="${sep}${C_MUTED}c${R}$(cpct $current_pct budget)"
  line+="${sep}${C_MUTED}w${R}$(cpct $weekly_pct budget)"
  [ -n "$NS" ] && line+=" ${NS}"
  printf '%b' "$line"

else
  # ULTRACOMPACT: branch + model_tiny + percentages, no dividers
  line=""
  [ -n "$git_branch" ] && line+="${C_GREEN}${git_branch}${R}" || line+="${C_RED}${project_short}${R}"
  line+=" ${C_PURPLE}${model_tiny}${R}"
  line+=" $(cpct $ctx_pct context)"
  line+=" ${C_MUTED}c${R}$(cpct $current_pct budget)"
  line+=" ${C_MUTED}w${R}$(cpct $weekly_pct budget)"
  [ -n "$NS" ] && line+=" ${NS}"
  printf '%b' "$line"
fi

exit 0
