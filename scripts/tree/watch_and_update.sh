#!/usr/bin/env bash
# Author: Kiyoon Kim (https://github.com/kiyoon)

if [[ $# -ne 7 ]]; then
	echo "Usage: $0 <MAIN_PANE_ID> <SIDE_PANE_ID> <SIDE_PANE_ROOT> <NVIM_ADDR> <REFRESH_INTERVAL> <REFRESH_INTERVAL_INACTIVE_PANE> <REFRESH_INTERVAL_INACTIVE_WINDOW>"
	echo "Arthor: Kiyoon Kim (https://github.com/kiyoon)"
	echo "Track directory changes in the main pane, and refresh the side pane's Nvim-Tree every <REFRESH_INTERVAL> seconds."
	echo "When going into child directories (cd dir), the side pane will keep the root directory."
	echo "When going out of the root directory (cd /some/dir), the side pane will change the root directory to that of the main pane."
	exit 100
fi

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

source "$CURRENT_DIR"/awk_helper.sh

MAIN_PANE_ID="$1"
SIDE_PANE_ID="$2"
SIDE_PANE_ROOT="$3"
NVIM_ADDR="$4"
REFRESH_INTERVAL="$5"
REFRESH_INTERVAL_INACTIVE_PANE="$6"
REFRESH_INTERVAL_INACTIVE_WINDOW="$7"

echo "$0 $@"
echo "OSTYPE: $OSTYPE"	# log OS type
tmux -V					# log tmux version

# `tmux display` doesn't match strictly and it will give you any pane if not found.
read -r -d '' main_pane_pid side_pane_pid < <(
	tmux display -pt "$MAIN_PANE_ID" '#{pane_pid}' \; display -pt "$SIDE_PANE_ID" '#{pane_pid}' 2>/dev/null
)
if [[ -z $main_pane_pid || -z $side_pane_pid ]]; then
	echo "Main pane $MAIN_PANE_ID or side pane $SIDE_PANE_ID not found. Exiting."
	exit 101
fi

# The main pane's cwd. /proc where there is one (no process start); lsof
# elsewhere (macOS).
pane_cwd() {
	if [[ -e /proc/$1/cwd ]]; then
		readlink "/proc/$1/cwd"
	else
		lsof -a -d cwd -p "$1" 2> /dev/null | awk_by_name '{print $(f["NAME"])}' | tail -n +2
	fi
}

# Call scripts/tree/follow.lua in the sidebar nvim: tree_call <function> <args...>
# Prints the function's result. Arguments are passed as a Vim list of
# single-quoted strings ('' escapes a quote).
tree_call() {
	local fn="$1" arg list=""
	shift
	for arg in "$CURRENT_DIR/follow.lua" "$@"; do
		list+="'${arg//\'/\'\'}',"
	done
	nvim --server "$NVIM_ADDR" --remote-expr "luaeval('dofile(_A[1]).$fn(unpack(_A, 2))', [${list%,}])" 2>/dev/null
}

# sleep without starting a process: read on a pipe nothing ever writes to
exec {sleep_fd}<> <(:)
nap() { read -rt "$1" -u "$sleep_fd"; }

main_pane_prevcwd="$(pane_cwd "$main_pane_pid")"
echo "Watching main pane (pid = $main_pane_pid), updating side pane (pid = $side_pane_pid)"
echo "Initial main pane cwd: $main_pane_prevcwd"
echo "Initial nvim-tree/neo-tree pane root: $SIDE_PANE_ROOT"
echo "Waiting for the nvim-tree/neo-tree.."
tree_filetype=""
for _ in $(seq 500); do
	tree_filetype="$(tree_call filetype)"
	[[ $tree_filetype == neo-tree || $tree_filetype == NvimTree ]] && break
	kill -0 "$side_pane_pid" 2>/dev/null || exit 0
	nap 0.02
done
if [[ $tree_filetype != neo-tree && $tree_filetype != NvimTree ]]; then
	echo "Nvim-Tree/Neo-Tree did not start (filetype: $tree_filetype). Exiting.."
	exit 104
fi
side_pane_root="$(tree_call go_random "$main_pane_prevcwd" "$SIDE_PANE_ROOT")"
echo "$tree_filetype detected! Side pane root: $side_pane_root"

interval="$REFRESH_INTERVAL"
tick=0
# Both panes alive: their processes (the pane's shell, the sidebar's nvim)
# stand for them, and kill -0 costs no process start.
while kill -0 "$main_pane_pid" 2>/dev/null && kill -0 "$side_pane_pid" 2>/dev/null; do
	# Same directory as before (same inode): nothing to read or do.
	if ! [[ /proc/$main_pane_pid/cwd -ef $main_pane_prevcwd ]]; then
		main_pane_cwd="$(pane_cwd "$main_pane_pid")"
		if [[ -z "$main_pane_cwd" ]]; then
			echo "Can't find main pane's cwd. Exiting.."
			break
		fi
	else
		main_pane_cwd="$main_pane_prevcwd"
	fi

	if [[ "$main_pane_cwd" != "$main_pane_prevcwd" ]]; then
		new_root_dir=""
		if [[ "$main_pane_cwd"/ != "$side_pane_root"/* ]]; then
			echo "Root changed: $main_pane_cwd"
			new_root_dir="$(tree_call change_root "$main_pane_cwd")"
		elif [[ "$main_pane_prevcwd" == "$main_pane_cwd"/* ]]; then
			# Going up within the root: close the child directory left
			main_pane_child_dir=${main_pane_prevcwd#$main_pane_cwd/}
			main_pane_first_child="$main_pane_cwd/${main_pane_child_dir%%/*}"
			echo "Closing directory: $main_pane_first_child"
			new_root_dir="$(tree_call go_parent "$main_pane_first_child" "$side_pane_root")"
		else
			# Into a child, or elsewhere within the root: reveal and open it
			echo "Opening directory: $main_pane_cwd"
			new_root_dir="$(tree_call go_random "$main_pane_cwd" "$side_pane_root")"
		fi
		[[ -n $new_root_dir ]] && side_pane_root="$new_root_dir"
		main_pane_prevcwd="$main_pane_cwd"
	fi

	# Poll fast only while the main pane or the sidebar is focused. Asking tmux
	# starts a process, so while focused ask once per second, not every tick.
	if (( tick % 10 == 0 )) || [[ $interval != "$REFRESH_INTERVAL" ]]; then
		read -r -d '' main_pane_active window_active side_pane_active < <(
			tmux display -pt "$MAIN_PANE_ID" '#{pane_active} #{window_active}' \; display -pt "$SIDE_PANE_ID" '#{pane_active}' 2>/dev/null
		)
		if [[ "$main_pane_active" == 1 || "$side_pane_active" == 1 ]]; then
			interval="$REFRESH_INTERVAL"
		elif [[ "$window_active" == 1 ]]; then
			interval="$REFRESH_INTERVAL_INACTIVE_PANE"
		else
			interval="$REFRESH_INTERVAL_INACTIVE_WINDOW"
		fi
	fi
	tick=$((tick + 1))
	nap "$interval"
done
