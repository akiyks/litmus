#! /bin/sh
#
# Convert LISA litmus test to auxiliary-variable form.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, you can access it online at
# http://www.gnu.org/licenses/gpl-2.0.html.
#
# Copyright (C) IBM Corporation, 2015
#
# Authors: Paul E. McKenney <paulmck@linux.vnet.ibm.com>

./stripocamlcomment |
gawk '

########################################################################
#
# Data structures:
#
# aux[proc][line]: Litmus test with RCU statements translated.
# lisa[proc][line]: Input litmus-test statements.
# max_line[nproc]: Number of input lines in lisa[].
# ngp: Number of grace periods across all processes.
# npa[proc]: Number of postambles emitted per GP for proc.
# nproc: Number of processes, ignoring prophesy-variable process.
# postamble[proc][gp]: How many postambles emitted for process/gp combo.
# postamblels[proc][gp]: Line number of condition-set for last postamble.
# preamble[proc][gp]: How many preambles emitted for process/gp combo.
# preamblels[proc][gp]: Line number of condition-set for last preamble.
# rcugp[gp]: Process containg RCU grace period gp.
# rcurl[proc]: Number of RCU read-side critical sections in process.
# rcurlonly[proc]: Singe RCU read-side critical section fills entire process.
# refgp[proc]: Grace-period number of GP in some other process (-1 if none).
# rlpreamble[proc][rl]: Preamble # corresponding to this rcu_read_lock().
# rulpreamble[proc][rul]: Postamble # corresponding to this rcu_read_unlock().


########################################################################
#
# Litmus-test variables and registers:
#
# gpstartGG: Has grace period GG not started yet?  (GG count is one-based.)
# gpendGG: Has grace period GG ended yet?
# prophGG: Prophesy variable for gpendGG.
#
# r1001:  Always 1 (to emulate unconditional branch).
# r1008GG: End of grace period GG already not seen?
# r1009GG: Start of grace period GG already seen?
# r1GG0NN:  Holds gpstartGG, NNth read by current process, zero-based.
# r1GG1NN:  Holds gpendGG, NNth read by current process, zero-based.
# r1GG2NN:  Holds prophGG, NNth read by current process.


########################################################################
#
# Emit a preamble
#
function emit_preamble(proc_num, gp_num, line_out,  cpa, line) {
	cpa = preamble[proc_num ":" gp_num] + 0;
	line = line_out;
	aux[proc_num ":" line++] = "(* preamble G" gp_num " #" cpa " *)";
	aux[proc_num ":" line++] = sprintf("r[once] r1%02d0%02d gpstart%02d", gp_num, cpa, gp_num);
	if (cpa + 0 >= 1)
		aux[proc_num ":" line++] = sprintf("b[] r1009%02d GPSS%02d%02d%d", gp_num, gp_num, proc_num, cpa);
	aux[proc_num ":" line++] = sprintf("b[] r1%02d0%02d GPSS%02d%02d%d", gp_num, cpa, gp_num, proc_num, cpa);
	aux[proc_num ":" line++] = "f[mb]";
	preamblels[proc_num ":" gp_num] = line;
	aux[proc_num ":" line++] = sprintf("mov r1009%02d 1", gp_num, gp_num, cpa);
	aux[proc_num ":" line++] = sprintf("GPSS%02d%02d%d:", gp_num, proc_num, cpa);
	aux[proc_num ":" line++] = "(* end preamble G" gp_num " #" cpa " *)";
	preamble[proc_num ":" gp_num]++;
	return line;
}

########################################################################
#
# Emit a postamble
#
function emit_postamble(proc_num, gp_num, line_out,  line, cpa) {
	line = line_out;
	cpa = postamble[proc_num ":" gp_num] + 0;
	aux[proc_num ":" line++] = "(* postamble G" gp_num " #" cpa " *)";
	if (cpa + 0 >= 1)
		aux[proc_num ":" line++] = sprintf("b[] r1008%02d GPES%02d%02d%d", gp_num, gp_num, proc_num, cpa);
	aux[proc_num ":" line++] = sprintf("r[once] r1%02d2%02d proph%02d", gp_num, cpa, gp_num);
	aux[proc_num ":" line++] = sprintf("b[] r1%02d2%02d GPES%02d%02d%d", gp_num, cpa, gp_num, proc_num, cpa);
	aux[proc_num ":" line++] = "f[mb]";
	postamblels[proc_num ":" gp_num] = line;
	aux[proc_num ":" line++] = sprintf("mov r1008%02d 1", gp_num, gp_num, cpa);
	aux[proc_num ":" line++] = sprintf("GPES%02d%02d%d:", gp_num, proc_num, cpa);
	aux[proc_num ":" line++] = sprintf("r[once] r1%02d1%02d gpend%02d", gp_num, cpa, gp_num);
	aux[proc_num ":" line++] = "(* end postamble G" gp_num " #" cpa " *)";
	postamble[proc_num ":" gp_num]++;
	npa[proc_num] = postamble[proc_num ":" gp_num];
	return line;
}

########################################################################
#
# Emit an RCU grace period.
#
function emit_sync(gp_num, line_out,  line) {
	line = line_out;
	aux[proc_num ":" line++] = "(* GP " gp_num " *)";
	aux[proc_num ":" line++] = "f[mb]";
	aux[proc_num ":" line++] = sprintf("w[once] gpstart%02d 0", gp_num);
	aux[proc_num ":" line++] = "f[mb]";
	aux[proc_num ":" line++] = sprintf("w[once] gpend%02d 1", gp_num);
	aux[proc_num ":" line++] = "f[mb]";
	aux[proc_num ":" line++] = "(* end GP " gp_num " *)";
	return line;
}

########################################################################
#
# Grace-period checks are only needed in processes containing RCU
# read-side critical sections, and even then only for grace periods
# in other processes.  This function checks to see if the specified
# process needs to check for the specified grace period.
#
function proc_needs_gp_check(proc_num, gp_num) {
	if (!rcurl[proc_num])
		return 0;
	return rcugp[gp_num] != proc_num;
}

########################################################################
#
# Does the specified statement of the specified process need check code
# against the specified grace period?
#
function stmt_needs_gp_check(stmt) {
	if (stmt == "f[rcu_read_lock]" || stmt == "f[rcu_read_unlock]")
		return 0;
	if (stmt ~ /^[frw]\[/)
		return 1;
	if (stmt == "-EOF-")
		return 1;
	if (stmt ~ /^P[0-9]/)
		return 0;
	return 0;
}

########################################################################
#
# Determine whether the specified line of the specified process needs
# against the specified grace period, and if so, cause the litmus-test
# code for the checks to be inserted into the aux[][] array.
#
function do_gp_checks(proc_num, line_out, rcurscs, rl, rul,  gp_num, line) {
	line = line_out;
	for (gp_num = 1; gp_num <= ngp; gp_num++) {
		if (proc_needs_gp_check(proc_num, gp_num)) {
			if (rul > 0)
				line = emit_postamble(proc_num, gp_num, line);
			if (rcurscs > rl)
				line = emit_preamble(proc_num, gp_num, line);
		}
	}
	return line;
}

########################################################################
#
# Determine whether the specified line of the specified process needs
# checks against any of the grace periods, and cause the litmus-test
# code for the checks to be inserted into the aux[][] array as needed.
#
function do_gp_checks_if_needed(proc_num, line_in, line_out, rcurscs, rl, rul,  line, stmt) {
	line = line_out;
	stmt = lisa[proc_num ":" line_in];
	if (!stmt_needs_gp_check(stmt))
		return line;  # Later check for empty RCU RS CS here
	line = do_gp_checks(proc_num, line, rcurscs, rl, rul);
	return line;
}

########################################################################
#
# Output the clause of the prophesy portion of the "exists" clause
# corresponding to the last prophesy-variable read.
#
function output_exists_clause_exists_proph_last(proc_num, gp_num, i) {
	# If this is the last postamble, if we have not see the
	# end of the grace period, there had better have been a
	# memory barrier.
	printf(" /\\ %d:r1%02d1%02d=", proc_num - 1, gp_num, i);
	printf("%d:r1%02d2%02d\n", proc_num - 1, gp_num, i);
}

########################################################################
#
# Output one clause of the prophesy portion of the "exists" clause.
#
function output_exists_clause_exists_proph(proc_num, gp_num, i) {
	# Handle last access specially.
	if (i + 1 >= npa[proc_num]) {
		output_exists_clause_exists_proph_last(proc_num, gp_num, i);
		return;
	}

	# If the grace period has already ended, the prophesy variable
	# must be 1 (thus no memory barrier).
	printf(" /\\ (%d:r1%02d1%02d=0 \\/", proc_num - 1, gp_num, i);
	printf(" %d:r1%02d2%02d=1)", proc_num - 1, gp_num, i);

	# If we have a memory barrier this time, the grace period has
	# to have ended next time.
	printf(" /\\ (%d:r1%02d2%02d=1 \\/", proc_num - 1, gp_num, i);
	printf(" %d:r1%02d1%02d=1)", proc_num - 1, gp_num, i + 1);

	# Note that the above two imply that there are not two
	# consecutive zero-value prophesy reads.

	# If we do not see the end of the grace period this time, but
	# do see it next time, there had better be a memory barrier
	# this time, that is, zero-valued prophesy.
	printf(" /\\ (~(%d:r1%02d1%02d=0 /\\", proc_num - 1, gp_num, i);
	printf(" %d:r1%02d1%02d=1) \\/", proc_num - 1, gp_num, i + 1);
	printf(" %d:r1%02d2%02d=0)", proc_num - 1, gp_num, i);
	printf("\n");
}

########################################################################
#
# Output the "exists" clause the new way, which uses the exists clause
# to compute whether or not the prophesy was correct.
#
function output_exists_clause_exists(proc_num,  gp_num, i, rgp, rln) {
	# Output prophesy-variable checks for each postamble.
	for (i = 0; i < npa[proc_num]; i++) {
		for (gp_num = 1; gp_num <= ngp; gp_num++) {
			if (rcugp[gp_num] == proc_num)
				continue;
			output_exists_clause_exists_proph(proc_num, gp_num, i);
		}
	}

	# Output grace-period violation checks
	rgp = refgp[proc_num]
	if (rgp == -1)
		return;
	for (gp_num = 1; gp_num <= ngp; gp_num++) {
		if (rcugp[gp_num] == proc_num)
			continue;
		for (rln = 1; rln <= rcurl[proc_num]; rln++)
			printf(" /\\ (%d:r1%02d0%02d=0 \\/ %d:r1%02d1%02d=0)", proc_num - 1, gp_num, rlpreamble[proc_num ":" rln], proc_num - 1, gp_num, rlpostamble[proc_num ":" rln]);
	}
}

########################################################################
#
# Output the "exists" clause.
#
function output_exists_clause() {
	printf "%s\n", exists;
	for (proc_num = 1; proc_num <= nproc; proc_num++) {
		output_exists_clause_exists(proc_num);
	}
	print ")";
}

########################################################################
#
# Start of patternist code.

# Kill blank lines
/^[ 	]*$/ {
	next;
}

# Header line
NR == 1 {
	if ($1 != "LISA") {
		print "Need LISA file!";
		exit;
	}
	print $1, $2 "-Auxiliary";
	inpreamble = 1;
	next;
}

# String and comments.
inpreamble == 1 {
	if ($1 ~ /"/)
		print;
	if ($0 ~ /{/) {
		print;
		if ($0 != "{") {
			print "Line " NR ": Single { to begin initialization!";
			exit;
		}
		inpreamble = 0;
		ininit = 1;
	}
	next;
}

# Initialization statements.
ininit == 1 {
	if ($0 ~ /}/) {
		if ($0 != "}") {
			print "Line " NR ": Single } to end initialization!";
			exit;
		}
		ininit = 0;
		incode = 1;
		line = 1;
		nproc = 0;
		ngp = 0;
	} else {
		print;
	}
	next;
}

# The "exists" statement at the end.  Handled first due to terminal laziness.
incode == 1 && $1 ~ /^exists/ {
	incode = 0;
	inexists = 1;
	exists = $0;
	gsub(/exists */, "exists (", exists);
	next;
}

# The statements of the processes.
incode == 1 {
	gsub(/^[ 	]*/, "");
	gsub(/;[ 	]*$/, "");
	split($0, cur_line, "|");
	if (nproc == 0)
		nproc = length(cur_line);
	else if (nproc != length(cur_line)) {
		print "Line " NR ": Expected " nproc " processes!";
		exit;
	}
	for (i = 1; i <= nproc; i++) {
		gsub(/^[ 	]*/, "", cur_line[i]);
		gsub(/[ 	]*$/, "", cur_line[i]);
		if (cur_line[i] == "f[sync]" || cur_line[i] == "call[sync]") {
			if (rcunest[i] + 0 != 0) {
				# Force LISA syntax error
				cur_line[i] = "call[sync DEADLOCK]";
			} else {
				ngp++;
				rcugp[ngp] = i;
			}
		}
		if (cur_line[i] == "f[rcu_read_lock]") {
			if (rcunest[i] + 0 == 0)
				rcurl[i]++;
			else
				cur_line[i] = "(* nested " cur_line[i] " *)";
			rcunest[i]++;
		} else if (cur_line[i] == "f[rcu_read_unlock]") {
			if (rcunest[i] == 1)
				rcurul[i]++;
			else
				cur_line[i] = "(* nested " cur_line[i] " *)";
			rcunest[i]--;
		}
		if (cur_line[i] != "") {
			max_line[i]++;
			lisa[i ":" max_line[i]] = cur_line[i];
		}
	}
	line++;
	next;
}

# In case we have a multi-line "exists" statement, pull it all together.
inexists == 1 {
	exists = exists " " $0;
}

# Translate and output!
END {
	# Build the refgp[] and rcurlonly[] arrays.
	rcurlonly_all = 1;
	for (proc_num = 1; proc_num <= nproc; proc_num++) {
		refgp[proc_num] = -1;
		for (gp_num = 1; gp_num <= ngp; gp_num++) {
			if (rcugp[gp_num] != proc_num) {
				refgp[proc_num] = gp_num;
				break;
			}
		}
		rcurlonly[proc_num] = 0;
		if (lisa[proc_num ":" 2] == "f[rcu_read_lock]" && lisa[proc_num ":" max_line[proc_num]] == "f[rcu_read_unlock]") {
			rcurlonly[proc_num] = 1;
		}
		if (rcurl[proc_num] > 1 || (rcurl[proc_num] > 0 && !rcurlonly[proc_num]))
			rcurlonly_all = 0;
	}

	# Do the translation from lisa[] to aux[].
	aux_max_line = 0;
	gp_num = 1;
	for (proc_num = 1; proc_num <= nproc; proc_num++) {
		line_in = 1;
		line_out = 1;
		drl = 0; /* Deferred rcu_read_lock(): till next memref. */
		rl = 0;
		rul = 0;
		for (line_in = 1; line_in <= max_line[proc_num]; line_in++) {
			line_out = do_gp_checks_if_needed(proc_num, line_in, line_out, rcurl[proc_num], rl, rul);
			stmt = lisa[proc_num ":" line_in];
			aux[proc_num ":" line_out] = stmt;
			if (line_out > aux_max_line)
				aux_max_line = line_out;
			if (stmt == "f[rcu_read_lock]") {
				drl++;
				if (refgp[proc_num] != -1)
					rlpreamble[proc_num ":" rl + drl] = preamble[proc_num ":" refgp[proc_num]];
				aux[proc_num ":" line_out++] = "(* " stmt " *)";
			} else if (stmt == "f[rcu_read_unlock]") {
				rul += 1;
				if (refgp[proc_num] != -1)
					rlpostamble[proc_num ":" rul] = postamble[proc_num ":" refgp[proc_num]];
				rl += drl;
				drl = 0;
				aux[proc_num ":" line_out++] = "(* " stmt " *)";
			} else if (stmt == "f[sync]" || stmt == "call[sync]") {
				line_out = emit_sync(gp_num++, line_out);
			} else if (stmt ~ /^[frw]\[/) {
				rl += drl;
				drl = 0;
				aux[proc_num ":" line_out++] = stmt;
			} else {
				aux[proc_num ":" line_out++] = stmt;
			}
		}
		line_out = do_gp_checks(proc_num, line_out, rcurl[proc_num], rl, rul);
		if (line_out - 1 > aux_max_line)
			aux_max_line = line_out - 1;
	}

	# Comment out the last condition set per GP per process.
	for (proc_num = 1; proc_num <= nproc; proc_num++) {
		for (gp_num = 1; gp_num <= ngp; gp_num++) {
			line = preamblels[proc_num ":" gp_num];
			if (line != "")
				aux[proc_num ":" line] = "(* " aux[proc_num ":" line] " *)";
			line = postamblels[proc_num ":" gp_num];
			if (line != "")
				aux[proc_num ":" line] = "(* " aux[proc_num ":" line] " *)";
		}
	}

	# Output initialization for auxiliary litmus-test variables.
	for (i = 1; i <= ngp; i++) {
		printf "gpstart%02d=1;\n", i;
		printf "proph%02d=1;\n", i;
	}
	for (i = 1; i <= nproc; i++)
		printf " %d:r1001=1;", i - 1;
	printf("\n");
	for (proc_num = 1; proc_num <= nproc; proc_num++) {
		neednewline=0;
		for (i = 0; i < npa[proc_num]; i++) {
			for (gp_num = 1; gp_num <= ngp; gp_num++) {
				if (rcugp[gp_num] == proc_num)
					continue;
				printf(" %d:r1%02d2%02d=1;", proc_num - 1, gp_num, i);
				neednewline=1;
			}
		}
		if (neednewline)
			printf("\n");
	}
	print "}";

	# Form code for prophesy-variable writes.
	gp_proc = rcugp[1];
	proph_mb = 1;
	for (gp_num = 2; gp_num <= ngp; gp_num++) {
		if (rcugp[gp_num] != gp_proc) {
			proph_mb = 0;
			break;
		}
	}
	line_out = 0;
	aux[nproc + 1 ":" ++line_out] = sprintf("P%d", nproc);
	for (gp_num = 1; gp_num <= ngp; gp_num++) {
		if (gp_num > 1 && proph_mb)
			aux[nproc + 1 ":" ++line_out] = "f[mb]";
		aux[nproc + 1 ":" ++line_out] = sprintf("w[once] proph%02d 0", gp_num);
		if (!rcurlonly_all)
			aux[nproc + 1 ":" ++line_out] = sprintf("w[once] proph%02d 1", gp_num);
		if (line_out > aux_line_max)
			aux_line_max = line_out;
	}

	# Find maximum statement length for each process.
	for (proc_num = 1; proc_num <= nproc + 1; proc_num++) {
		max_length[proc_num] = 0;
		for (line_out = 1; line_out <= aux_max_line; line_out++) {
			stmt = aux[proc_num ":" line_out];
			if (length(stmt) > max_length[proc_num])
				max_length[proc_num] = length(stmt);
		}
	}

	# Output the code and the stores to the prophesy variables.
	for (line_out = 1; line_out <= aux_max_line; line_out++) {
		for (proc_num = 1; proc_num <= nproc + 1; proc_num++) {
			stmt = aux[proc_num ":" line_out];
			pad = max_length[proc_num] - length(stmt);
			printf " %s%*s %s", stmt, pad, "", proc_num <= nproc ? "|" : ";\n";
		}
	}

	# In case there are more prophesy variables than lines of code.
	for (; line_out <= ngp + 1; line_out++) {
		for (proc_num = 1; proc_num <= nproc; proc_num++)
			printf " %*s |", max_length[proc_num], "";
		printf " w[once] proph%2d 0 ;\n", line_out - 1, nproc;
	}

	# exists clause.
	output_exists_clause();
}
'
