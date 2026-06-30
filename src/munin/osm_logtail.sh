# shellcheck shell=bash
#
# osm_logtail.sh -- incremental, rotation-aware tail of an Overpass log for
# munin plugins. Source it and call osm_logtail; it returns the bytes appended
# to a log since the previous run, following a logrotate copytruncate rotation
# across the boundary so DERIVE counters never reset and in-flight state is
# never lost.
#
# Not a plugin: this file is sourced, never symlinked into /etc/munin/plugins,
# and ships non-executable alongside munin's own plugin.sh in the plugin
# library. Source it by absolute path, the same way stock plugins source
# plugin.sh:
#   . "${MUNIN_LIBDIR:-/usr/share/munin}/plugins/osm_logtail.sh"
#
# Usage:
#   osm_logtail <logfile> <statefile>
#
# On success (return 0) it sets, in the caller's scope:
#   OSM_LOGTAIL_CHUNK   path to a tempfile holding the complete lines appended
#                       since the previous run (a trailing partial line is held
#                       back for next time). The caller owns this file and must
#                       remove it.
#   OSM_LOGTAIL_OFFSET  byte offset to persist as the new read position.
#   OSM_LOGTAIL_HEAD    first-line fingerprint to persist for rotation
#                       detection on the next run.
# The caller passes OFFSET and HEAD into its own awk and writes them -- together
# with whatever domain counters it keeps -- to <statefile>. osm_logtail reads
# only the "offset" and "head" lines from <statefile> and never writes it; the
# caller's awk is the sole writer of the state file.
#
# Returns 1 without setting any variable if <logfile> is not readable.

# _osm_logtail_emit <file> <start> <end> <chunk>: append the complete lines of
# <file> in the byte range [start,end) to <chunk>, and set
# _OSM_LOGTAIL_CONSUMED to the number of bytes consumed. Consumption always
# ends on a line boundary, so a partial trailing line (a log entry still being
# written) is held back for the next run.
_osm_logtail_emit() {
  local file=$1 start=$2 end=$3 chunk=$4 remaining tmp part_len keep
  _OSM_LOGTAIL_CONSUMED=0
  remaining=$(( end - start ))
  (( remaining <= 0 )) && return 0
  tmp=$(mktemp)
  tail -c "+$(( start + 1 ))" "$file" | head -c "$remaining" > "$tmp"
  if [[ -s "$tmp" && -z "$(tail -c1 "$tmp")" ]]; then
    cat "$tmp" >> "$chunk"            # ends in a newline: every line complete
    _OSM_LOGTAIL_CONSUMED=$remaining
  else                                # trailing partial: keep up to last newline
    # LC_ALL=C keeps length() a byte count under both mawk and gawk, so the
    # held-back amount matches the byte offsets used everywhere else.
    part_len=$(LC_ALL=C awk 'END{print length($0)}' "$tmp")
    keep=$(( remaining - part_len ))
    (( keep > 0 )) && head -c "$keep" "$tmp" >> "$chunk"
    _OSM_LOGTAIL_CONSUMED=$keep
  fi
  rm -f "$tmp"
}

osm_logtail() {
  local log=$1 state=$2
  local cur_size cur_head prev_offset prev_head chunk new_offset
  local rot rot_size key rest

  [[ -r "$log" ]] || return 1

  cur_size=$(stat -c %s "$log")
  # Fingerprint of the first line: stable as the file grows (appends never
  # change it) but it changes when copytruncate resets the file. Together with
  # a size regression this is how rotation is detected; the inode does not
  # change under copytruncate, so it is useless here.
  cur_head=$(head -n 1 "$log" | cksum | cut -d' ' -f1)

  # No state yet: start caught up at end of file, so a fresh container or a
  # first run does not parse the entire historical log.
  prev_offset=$cur_size
  prev_head=$cur_head
  if [[ -f "$state" ]]; then
    while read -r key rest; do
      case "$key" in
        offset) prev_offset=$rest ;;
        head)   prev_head=$rest ;;
      esac
    done < "$state"
  fi

  chunk=$(mktemp)
  if (( cur_size < prev_offset )) || [[ "$cur_head" != "$prev_head" ]]; then
    # Rotation (copytruncate): the live file was copied to <log>.1 and
    # truncated in place. The writer keeps the log open for its lifetime, so a
    # rename rotation would not work (it would keep writing to the renamed
    # file); copytruncate preserves the inode. The unread tail
    # [prev_offset, old end] now lives only in <log>.1, so drain it (when it
    # still lines up with our offset -- it will not after multiple missed
    # rotations), then read the truncated file from the start.
    rot="$log.1"
    if [[ -f "$rot" ]]; then
      rot_size=$(stat -c %s "$rot")
      (( prev_offset <= rot_size )) && _osm_logtail_emit "$rot" "$prev_offset" "$rot_size" "$chunk"
    fi
    _osm_logtail_emit "$log" 0 "$cur_size" "$chunk"
    new_offset=$_OSM_LOGTAIL_CONSUMED
  else
    _osm_logtail_emit "$log" "$prev_offset" "$cur_size" "$chunk"
    new_offset=$(( prev_offset + _OSM_LOGTAIL_CONSUMED ))
  fi

  OSM_LOGTAIL_CHUNK=$chunk
  OSM_LOGTAIL_OFFSET=$new_offset
  OSM_LOGTAIL_HEAD=$cur_head
}
