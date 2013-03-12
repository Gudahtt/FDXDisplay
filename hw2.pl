#!/usr/bin/perl

use strict;
use warnings;
use diagnostics;


sub parse_input {
    my $line = shift;    

    $line =~ m/\$(\d+?)\s?<-\s?([\*\+])\(\$(\d+?),\$(\d+?)\)/ms
	or die("Input could not be parsed. Must be of form 'R1<-D(R2,R3)', where D is * or +\n");

    return ($1, $2, $3, $4);
}

sub parse_machine {
    my $M_fn = shift;

    open my $machine, '<', $M_fn
	or die("Can't open machine file");

    my @lines = <$machine>;
    if (scalar @lines != 5) {
	die("Wrong number of lines in machine file");
    }

    $lines[0] =~ m/=\s*(\d+)/ms;
    my $d_units = $1;

    $lines[1] =~ m/=\s*(\d+)/ms;
    my $global_registers = $1;

    $lines[2] =~ m/=\s*(\d+)/ms;
    my $plus_time = $1;
    
    $lines[3] =~ m/=\s*(\d+)/ms;
    my $mult_time = $1;

    $lines[4] =~ m/=\s*(\d+)/ms;
    my $lu_time = $1;

    return ($d_units, $global_registers, $plus_time, $mult_time, $lu_time);
}

sub instruction_queue {
    my $P_fn = shift;
    my $global_registers = shift;

    open my $program, '<', $P_fn;
    my @queue;

    while (my $line = <$program>) {
	my ($left, $op, $right_first, $right_second) = parse_input($line);
	
	if ($left >= $global_registers || $right_first >= $global_registers || $right_second >= $global_registers) {
	    die("Not enough registers");
	}

	my @instruction = ($left, $op, $right_first, $right_second);
	push (@queue, \@instruction);
    }

    return @queue;
}

sub run_program {
    my $P_fn = shift;
    my $M_fn = shift;
    
    my ($d_units, $global_registers, $plus_time, $mult_time, $lu_time) = parse_machine($M_fn);
    
    my $d_in_use = 0;
    my $iu_in_use = 0;
    # indicates that they are about to be freed
    my $iu_freed = 0;
    my $d_freed = 0;

    my @instr_queue = instruction_queue($P_fn, $global_registers);
    my @in_progress;
    my @output;
    my @dependency_blocks;


    my $time_slice = 0;
    my $instruction_counter = 0;

    while (scalar @instr_queue > 0 || scalar @in_progress > 0) {
	# check for iu availability
	if ($iu_in_use eq 0 && scalar @instr_queue > 0) {
	    my $instr = $instr_queue[0];
	    my $operator = $$instr[1];

	    my $d_time;
	    if ($operator eq '+') {
	        $d_time += $plus_time;
	    }
	    else {
		$d_time += $mult_time;
	    }

	    # check for reg depedency
	    my $l_reg = $$instr[0];
	    my $r_reg1 = $$instr[2];
	    my $r_reg2 = $$instr[3];

	    my $block = 0;

	    foreach my $prog_instr (@in_progress) {
		my $in_progress_l_reg         = $$prog_instr[0];
		my $in_progress_r_reg1        = $$prog_instr[2];
		my $in_progress_r_reg2        = $$prog_instr[3];
		my $in_progress_load_time     = $$prog_instr[4];
		my $in_progress_d_time        = $$prog_instr[5];
		my $in_progress_instr_counter = $$prog_instr[6];

		# read-after-write dependency
		if ($in_progress_l_reg eq $r_reg1 or $in_progress_l_reg eq $r_reg2) {
		    my @dependency_entry = ($instruction_counter, $time_slice, "OI", $in_progress_instr_counter);
		    push (@dependency_blocks, \@dependency_entry);
		    
		    $block = 1;
		    last;
		}
		# write-after-write dependency
		elsif ($in_progress_l_reg eq $l_reg) {
		    if (($in_progress_load_time + $in_progress_d_time) >= ($lu_time + $d_time)) {
			my @dependency_entry = ($instruction_counter, $time_slice, "OO", $in_progress_instr_counter);
			push (@dependency_blocks, \@dependency_entry);

			$block = 1;
			last;
		    }
		}
		# write-after-read dependency
		elsif ($in_progress_r_reg1 eq $l_reg || $in_progress_r_reg2 eq $l_reg) {
		    if ($in_progress_load_time >= ($lu_time + $d_time)) {
			my @dependency_entry = ($instruction_counter, $time_slice, "IO", $in_progress_instr_counter);
			push (@dependency_blocks, \@dependency_entry);

			$block = 1;
			last;
		    }
		}
		
	    }

	    if ($block == 0) {
		# no dependency, process instruction
		shift @instr_queue;
		$iu_in_use = 1;

		my @progress = @$instr;

		my $load_time = $lu_time;

		push (@progress, $load_time);
		push (@progress, $d_time);
		push (@progress, $instruction_counter);

		my @output_entry = ($instruction_counter, $time_slice, $lu_time, $d_time, $operator);
		push(@output, \@output_entry);
		$instruction_counter++;

		push(@in_progress, \@progress);
	    }
	}

	# no IU-units available
	elsif (scalar @instr_queue > 0) {
	    my @dependency_entry = ($instruction_counter, $time_slice, "IU", -1);
	    push (@dependency_blocks, \@dependency_entry);
	}

	# process in-progress
	my @to_be_removed;
	for (my $j = 0; $j < scalar @in_progress; $j++) {
	    my @cur_instr = @{$in_progress[$j]};
	    
	    #print "Instruction: " . $cur_instr[6] . " d_units: " . $d_in_use . " d_time: " . $cur_instr[5] . " time slice: " . $time_slice . "\n";
	    # load_time
	    if ($cur_instr[4] > 0) {
		$cur_instr[4]--;
		if ($cur_instr[4] eq 0) {
		    $iu_freed = 1;
		    $cur_instr[4] = -1; # indicates that d_time should start
		}
	    }
	    # d_time start
	    elsif ($cur_instr[4] eq -1) {
		if ($d_in_use < $d_units) {
		    $d_in_use++;
		    $cur_instr[5]--;

		    $cur_instr[4] = 0; # set flag back to normal
		    
		    my $d_start_time = $time_slice;
		    my $found_entry = 0;
		    for ( my $output_entry = 0; $output_entry < scalar (@output); $output_entry++) {
			# find current instruction to add d_start_time
			if (${$output[$output_entry]}[0] eq $cur_instr[6]) {
			    push (@{$output[$output_entry]}, $d_start_time);
			    $found_entry = 1;
			    last;
			}
		    }
		}
		# no d-units available
		else {
		    my @dependency_entry = ($cur_instr[6], $time_slice, "D", -1);
		    push (@dependency_blocks, \@dependency_entry);
		}
	    }
	    # d_time
	    else {
		$cur_instr[5]--;
	    }

	    $in_progress[$j] = \@cur_instr;

	    # instruction finished
	    if ($cur_instr[5] <= 0) {
		$d_freed++;

		push(@to_be_removed, $j);
	    }
	}

	foreach my $num (@to_be_removed) {
	    splice(@in_progress, $num, 1);
	}

	$time_slice++;
	if ($iu_freed eq 1) {
	    $iu_freed = 0;
	    $iu_in_use = 0;
	}
	
	for (my $y = $d_freed; $y > 0; $y--) {
	    $d_in_use--;
	}
	$d_freed = 0;

    }

    return (\@output, \@dependency_blocks);
}

sub display_HP {
    my $output_ref = shift;
    my $dep_blocks_ref = shift;

    my @output = @$output_ref;
    my @dep_blocks = @$dep_blocks_ref;

    # tracks number of columns for drawing x-axis
    my $col_max = 0;

    foreach my $instr (@output) {
	my $instr_number = $$instr[0];
	my $time_slice   = $$instr[1];
	my $lu_time      = $$instr[2];
	my $d_time       = $$instr[3];
	my $operator     = $$instr[4];
	my $d_start_time = $$instr[5];

	my $col_counter = 0;
	my $line = "S" . $instr_number . ":   ";
	
	for (my $i = $time_slice; $i > 0; $i--) {
	    $line .= "    ";
	    $col_counter++;
	}
	$line =~ s/\s$/|/g;

	$line  .= "IU |";
	$col_counter++;

	for (my $j = $lu_time-1; $j > 0; $j--) {
	    $line .= "IU |";
	    $col_counter++;
	}

	if (defined $d_start_time) {
	    # find 'waiting for d-unit' time
	    for ( my $t = $d_start_time - ($time_slice + $lu_time); $t > 0; $t--) {
		$line .= " - |";
		$col_counter++;
	    }
	}

	$line = $line . " $operator |";
	$col_counter++;

	for (my $k = $d_time-1; $k > 0; $k--) {
	    $line = $line . " $operator |";
	    $col_counter++;
	}

	print $line;
	print "\n";

	if ($col_counter > $col_max) {
	    $col_max = $col_counter;
	}
    }

    my $time_axis = "time:  0";
    for (my $i = 1; $i <= $col_max - 1; $i++) {
	if ($i < 11) {
	    $time_axis = $time_axis . "   " . $i;
	}
	else {
	    $time_axis = $time_axis . "  " . $i;
	}
    }
    $time_axis = $time_axis . "\n";
    print $time_axis;
    print "\n";

    foreach my $dep_block (@dep_blocks) {
	my $line = "S" . $$dep_block[0] . " was blocked at time=" . $$dep_block[1];

	my $dep_type = $$dep_block[2];
	if ($dep_type eq "D") {
	    $line .= " due to a lack of available D-units";
	}
	elsif($dep_type eq "IU") {
	    $line .= " due to a lack of available IU units";
	}
	else {
	    $line .= " by a " . $dep_type . " dependency, caused by S" . $$dep_block[3];
	}

	print $line;
	print "\n";
    }

}

MAIN: {
    my $P_fn = shift;
    my $M_fn = shift;

    if (! defined $P_fn || ! defined $M_fn) {
	die("Not enough arguments.  Usage: perl hw2.pl [program] [machine]");
    }

    my ($output, $dep_blocks) = run_program($P_fn, $M_fn);

    display_HP($output, $dep_blocks);
}
