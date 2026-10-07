#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# layout.sh - model of what is supposed to be on the tape.
#
# The model lives in $TT_RUN/layout so that it survives test subshells.  One
# line per tape file:  <data-id> <state> <repeat> <bs>
#   data-id  seed of the deterministic data file ($TT_RUN/data/d<id>.bin)
#   state    full    - file must read back exactly and end in a filemark
#            partial - interrupted write: byte-exact prefix, must end at EOD
#                      (st must not write a filemark once the position is lost)
#            partialfm - prefix terminated by a filemark (e.g. close after ENOSPC)
#            partialany - prefix, filemark optional (behaviour not specified)
#   repeat   the data file is written <repeat> times back to back
#   bs       write size (== tape block size in variable mode)
#
# Every file uses a different seed so misordered or duplicated files are
# detected, not just corrupted bytes.

declare -ga L_ID=() L_ST=() L_REP=() L_BS=()

data_file() {	# id -> path (created on first use)
	local f=$TT_RUN/data/d$1.bin
	if [[ ! -f $f ]]; then
		mkdir -p "$TT_RUN/data"
		python3 "$TAPECTL" gendata "$f" --bytes "$TT_FILE_BYTES" --seed "$((1000 + $1))" \
			> /dev/null || die "cannot create $f"
	fi
	echo "$f"
}

layout_load() {
	L_ID=(); L_ST=(); L_REP=(); L_BS=()
	[[ -f $TT_RUN/layout ]] || return 0
	local a b c d
	while read -r a b c d; do
		L_ID+=("$a"); L_ST+=("$b"); L_REP+=("$c"); L_BS+=("$d")
	done < "$TT_RUN/layout"
}

layout_save() {
	local i
	: > "$TT_RUN/layout.new"
	for i in "${!L_ID[@]}"; do
		echo "${L_ID[$i]} ${L_ST[$i]} ${L_REP[$i]} ${L_BS[$i]}" >> "$TT_RUN/layout.new"
	done
	mv "$TT_RUN/layout.new" "$TT_RUN/layout"
}

layout_count() { layout_load; echo "${#L_ID[@]}"; }

layout_dirty() {	# model no longer trustworthy: force a rebuild
	echo "$*" > "$TT_RUN/layout.dirty"
}

layout_is_baseline() {
	[[ -f $TT_RUN/layout.dirty ]] && return 1
	layout_load
	[[ ${#L_ID[@]} -eq $TT_NFILES ]] || return 1
	local i
	for i in "${!L_ID[@]}"; do
		[[ ${L_ID[$i]} == "$i" && ${L_ST[$i]} == full && ${L_REP[$i]} == 1 &&
		   ${L_BS[$i]} == "$TT_BS" ]] || return 1
	done
	return 0
}

# write one file at the current position (or after --pre ops); updates R
_layout_write() {	# id repeat bs [pre-ops...]
	local id=$1 rep=$2 bs=$3 f; shift 3
	f=$(data_file "$id")
	local pre=() p
	for p in "$@"; do pre+=(--pre "$p"); done
	tc write "$DEV" --src "$f" --bs "$bs" --repeat "$rep" "${pre[@]}"
}

# layout_build: rewind and write the baseline files
layout_build() {
	local i
	rm -f "$TT_RUN/layout.dirty"
	L_ID=(); L_ST=(); L_REP=(); L_BS=()
	for ((i = 0; i < TT_NFILES; i++)); do
		if [[ $i -eq 0 ]]; then
			_layout_write "$i" 1 "$TT_BS" rewind
		else
			_layout_write "$i" 1 "$TT_BS"
		fi
		if [[ ${R[errno]} != 0 ]]; then
			layout_save
			layout_dirty "baseline write $i failed"
			return 1
		fi
		L_ID+=("$i"); L_ST+=(full); L_REP+=(1); L_BS+=("$TT_BS")
	done
	layout_save
}

layout_ensure_baseline() {
	layout_is_baseline && return 0
	step "building baseline tape layout ($TT_NFILES files x $TT_FILE_BYTES bytes)"
	layout_build || abort_test "cannot build the baseline layout (errno ${R[errno]})"
}

# layout_append <id> [repeat] [bs]: write a file at EOD and record it
layout_append() {
	local id=$1 rep=${2:-1} bs=${3:-$TT_BS}
	layout_load
	_layout_write "$id" "$rep" "$bs" eod
	if [[ ${R[errno]} == 0 ]]; then
		L_ID+=("$id"); L_ST+=(full); L_REP+=("$rep"); L_BS+=("$bs")
		layout_save
		return 0
	fi
	layout_dirty "append of d$id failed with ${R[errno]}"
	return 1
}

# Record a file whose write was interrupted (at index k, replacing the tail).
layout_set_partial() {	# k id repeat bs [state]
	local st=${5:-partial}
	layout_load
	L_ID=("${L_ID[@]:0:$1}"); L_ST=("${L_ST[@]:0:$1}")
	L_REP=("${L_REP[@]:0:$1}"); L_BS=("${L_BS[@]:0:$1}")
	L_ID+=("$2"); L_ST+=("$st"); L_REP+=("$3"); L_BS+=("$4")
	layout_save
}

# Overwrite tape file k (and everything after it) with data id.
layout_rewrite_at() {	# k id [repeat] [bs]
	local k=$1 id=$2 rep=${3:-1} bs=${4:-$TT_BS}
	local pre=(rewind)
	[[ $k -gt 0 ]] && pre+=("fsf:$k")
	_layout_write "$id" "$rep" "$bs" "${pre[@]}"
	layout_load
	L_ID=("${L_ID[@]:0:$k}"); L_ST=("${L_ST[@]:0:$k}")
	L_REP=("${L_REP[@]:0:$k}"); L_BS=("${L_BS[@]:0:$k}")
	if [[ ${R[errno]} == 0 ]]; then
		L_ID+=("$id"); L_ST+=(full); L_REP+=("$rep"); L_BS+=("$bs")
		layout_save
		return 0
	fi
	layout_save
	layout_dirty "rewrite at $k failed with ${R[errno]}"
	return 1
}

# read tape file at the current position and compare with the model entry i
_layout_read_entry() {	# i [pre-ops]
	local i=$1 f; shift
	local pre=() p
	for p in "$@"; do pre+=(--pre "$p"); done
	if [[ ${L_ID[$i]} == - ]]; then		# empty file: just a filemark
		tc read "$DEV" --bs "$TT_BS" --one "${pre[@]}"
		R[expected_bytes]=0
		if [[ ${R[errno]} == 0 && ${R[bytes]} == 0 ]]; then R[verify]=equal
		else R[verify]=mismatch; fi
		return
	fi
	f=$(data_file "${L_ID[$i]}")
	tc read "$DEV" --bs "$(( L_BS[i] > TT_BS ? L_BS[i] : TT_BS ))" --expect "$f" \
		--expect-repeat "${L_REP[$i]}" --verify "$TT_VERIFY" \
		--tape-block "${L_BS[$i]}" "${pre[@]}"
}

# layout_verify <description>: read back the whole tape against the model.
# Returns the number of problems found.
layout_verify() {
	local d=${1:-verify} i bad=0 v
	layout_load
	if [[ -f $TT_RUN/layout.dirty ]]; then
		note "layout model is dirty ($(cat "$TT_RUN/layout.dirty")); verify skipped"
		return 0
	fi
	step "verify tape contents: ${#L_ID[@]} file(s) [$d]"
	local blank=0
	for i in "${!L_ID[@]}"; do
		if [[ $i -eq 0 ]]; then _layout_read_entry "$i" rewind
		else _layout_read_entry "$i"; fi
		v=${R[verify]}
		blank=0
		# st returns EIO for BLANK CHECK unless it directly follows a
		# filemark (read_tape()), so an unterminated file ends in EIO.
		# If nothing at all was written after the previous filemark the
		# first read returns 0 (first blank check after FM) and only the
		# second read fails; a stray filemark would return 0 twice.
		if [[ ${L_ST[$i]} == partial* && ${R[errno]} == 0 && ${R[bytes]} == 0 ]]; then
			local ev=$v eb=${R[expected_bytes]}
			tc read "$DEV" --bs "$TT_BS" --one
			# EIO: blank tape, no filemark (blank=1)
			# 0:   a filemark, and this was the first blank check after it:
			#      end of data already reached (blank=2)
			if [[ ${R[errno_read]} == EIO ]]; then blank=1
			elif [[ ${R[errno]} == 0 && ${R[bytes]} == 0 ]]; then blank=2; fi
			R=([errno]=0 [bytes]=0 [verify]=$ev [expected_bytes]=$eb [mismatch_at]=-1)
		elif [[ ${L_ST[$i]} == partial* && ${R[errno_read]} == EIO &&
		      ( $v == equal || $v == prefix ) ]]; then
			blank=1
		elif [[ ${R[errno]} != 0 ]]; then
			fail "$d: reading file $i (d${L_ID[$i]}) failed with ${R[errno]} after ${R[bytes]} bytes"
			bad=$((bad + 1)); break
		fi
		case "${L_ST[$i]}" in
		full)
			if [[ $v == equal ]]; then
				pass "$d: file $i intact (${R[bytes]} bytes)"
			else
				fail "$d: file $i (d${L_ID[$i]}) verify=$v bytes=${R[bytes]}/${R[expected_bytes]} mismatch_at=${R[mismatch_at]}"
				bad=$((bad + 1))
			fi
			;;
		partial|partialfm|partialany)
			if [[ $v == equal || $v == prefix ]]; then
				pass "$d: interrupted file $i is a clean prefix (${R[bytes]}/${R[expected_bytes]} bytes)"
			else
				fail "$d: interrupted file $i (d${L_ID[$i]}) verify=$v mismatch_at=${R[mismatch_at]}"
				bad=$((bad + 1))
			fi
			if [[ ${L_ST[$i]} == partial && $blank -ne 1 ]]; then
				fail "$d: interrupted file $i is followed by a filemark; st must not write one after losing position"
				bad=$((bad + 1))
			elif [[ ${L_ST[$i]} == partial ]]; then
				pass "$d: no filemark after the interrupted file (blank check)"
			elif [[ ${L_ST[$i]} == partialfm && $blank -eq 1 ]]; then
				fail "$d: file $i should end in a filemark but runs into blank tape"
				bad=$((bad + 1))
			fi
			;;
		esac
	done
	if [[ $bad -eq 0 && ${#L_ID[@]} -eq 0 ]]; then
		# Blank tape: st returns 0 or EIO (blank check at BOT); never data.
		tc read "$DEV" --bs "$TT_BS" --one --pre rewind
		if [[ ${R[bytes]} == 0 && ( ${R[errno]} == 0 || ${R[errno]} == EIO ) ]]; then
			pass "$d: tape is blank (read at BOT: errno=${R[errno]})"
		else
			fail "$d: tape should be blank: read at BOT returned errno=${R[errno]} bytes=${R[bytes]}"
			bad=$((bad + 1))
		fi
	elif [[ $bad -eq 0 && $blank -ge 1 ]]; then
		pass "$d: end of data after file $(( ${#L_ID[@]} - 1 )) (blank check)"
	elif [[ $bad -eq 0 ]]; then
		# Nothing may follow the last file: the next read must hit EOD.
		tc read "$DEV" --bs "$TT_BS" --one
		if [[ ${R[errno]} == 0 && ${R[bytes]} == 0 ]]; then
			if status "$DEV" && [[ ${S[eod]} == 1 ]]; then
				pass "$d: end of data after file $(( ${#L_ID[@]} - 1 ))"
			else
				fail "$d: unexpected extra (empty) file after the last file (eod flag=${S[eod]})"
				bad=$((bad + 1))
			fi
		else
			fail "$d: unexpected data after the last file (errno=${R[errno]} bytes=${R[bytes]})"
			bad=$((bad + 1))
		fi
	fi
	return $bad
}

# Position in the middle of file 1, block 2 (needs baseline layout)
goto_mid() {
	expect_ok "position: rewind" op "$DEV" rewind || return 1
	expect_ok "position: fsf 1" op "$DEV" fsf 1 || return 1
	expect_ok "position: fsr 2" op "$DEV" fsr 2 || return 1
	status "$DEV"
	check_eq "${S[file]}:${S[block]}" "1:2" "positioned at file 1 block 2"
}
