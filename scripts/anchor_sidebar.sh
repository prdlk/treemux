#!/usr/bin/env bash

# Keep a right-side sidebar a full-height column at the window's right edge,
# @treemux-tree-width columns wide. Run from tmux hooks (sidebar.tmux) after
# splits, layout changes and panes closing: a full-window split
# (`split-window -f`) elsewhere or a new layout would leave the sidebar short
# or in the middle, and a closing neighbour or an even layout would hand it
# columns. A manual resize-pane of the sidebar lasts until the next of those
# events. Windows with more than one sidebar are left alone, since only one
# can hold the edge.
#
# Usage: anchor_sidebar.sh <window_id>

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

source "$CURRENT_DIR/helpers.sh"
source "$CURRENT_DIR/variables.sh"
source "$CURRENT_DIR/tree_helpers.sh"

WINDOW_ID="$1"

main() {
	[[ "$(tree_position)" =~ "left" ]] && return
	# gone already (pane-exited of its last pane)
	tmux display-message -p -t "$WINDOW_ID" "" >/dev/null 2>&1 || return
	[ "$(tmux display-message -p -t "$WINDOW_ID" '#{window_zoomed_flag}')" = 1 ] && return

	local sidebars
	sidebars="$(tmux show-options -g | awk -v prefix="${REGISTERED_SIDEBAR_PREFIX}-" \
		'index($1, prefix) == 1 { print substr($1, length(prefix) + 1) }')"

	local window_width window_height
	read -r window_width window_height < <(tmux display-message -p -t "$WINDOW_ID" '#{window_width} #{window_height}')

	local sidebar="" other="" id right height width found=0
	local sidebar_right sidebar_height sidebar_width
	while read -r id right height width; do
		if \grep -qxF "$id" <<<"$sidebars"; then
			found=$((found + 1))
			sidebar="$id" sidebar_right="$right" sidebar_height="$height" sidebar_width="$width"
		elif [ -z "$other" ]; then
			other="$id"
		fi
	done < <(tmux list-panes -t "$WINDOW_ID" -F '#{pane_id} #{pane_right} #{pane_height} #{pane_width}')

	[ "$found" -eq 1 ] && [ -n "$other" ] || return
	local want
	want="$(tree_width)"
	if [ "$sidebar_right" -ne $((window_width - 1)) ] || [ "$sidebar_height" -ne "$window_height" ]; then
		tmux move-pane -h -f -d -l "$want" -s "$sidebar" -t "$other"
	elif [ "$sidebar_width" -ne "$want" ]; then
		tmux resize-pane -t "$sidebar" -x "$want"
	fi
}
main
exit 0
