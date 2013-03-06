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
    my $d_unit = $1;

    $lines[1] =~ m/=\s*(\d+)/ms;
    my $reg = $1;

    $lines[2] =~ m/=\s*(\d+)/ms;
    my $plus = $1;
    
    $lines[3] =~ m/=\s*(\d+)/ms;
    my $mult = $1;

    $lines[4] =~ m/=\s*(\d+)/ms;
    my $lu = $1;

    return ($d_unit, $reg, $plus, $mult, $lu);
}

sub instruction_queue {
    my $P_fn = shift;
    my $reg = shift;

    open my $program, '<', $P_fn;
    my @queue;

    while (my $line = <$program>) {
	my ($left, $op, $right_first, $right_second) = parse_input($line);
	
	if ($left >= $reg || $right_first >= $reg || $right_second >= $reg) {
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
    
    my ($d_unit, $reg, $plus, $mult, $lu) = parse_machine($M_fn);
    
    my $d_in_use = 0;

    my @instr_queue = instruction_queue($P_fn, $reg);
    my @in_progress;
    my @output;
    my @dependency_blocks;


    my $time_slice = 0;
    my $instruction_counter = 0;

    while (scalar @instr_queue > 0) {
	# check for d-unit dependency
	if ($d_in_use < $d_unit) {
	    my $instr = $instr_queue[0];
	    
	    my $d_time;
	    if ($$instr[1] eq '+') {
	        $d_time += $plus;
	    }
	    else {
		$d_time += $mult;
	    }

	    # check for reg depedency
	    my $l_reg = $$instr[0];
	    my $r_reg1 = $$instr[2];
	    my $r_reg2 = $$instr[3];

	    my $block = 0;

	    foreach my $prog_instr (@in_progress) {
		if ($$prog_instr[0] eq $r_reg1 or $$prog_instr[0] eq $r_reg2) {
		    my @dependency_entry = ($instruction_counter, $time_slice, "OI", $$prog_instr[6]);
		    push (@dependency_blocks, \@dependency_entry);
		    
		    $block = 1;
		    last;
		}
		elsif ($$prog_instr[0] eq $l_reg) {
		    if (($$prog_instr[4] + $$prog_instr[5]) >= ($lu + $d_time)) {
			my @dependency_entry = ($instruction_counter, $time_slice, "OO", $$prog_instr[6]);
			push (@dependency_blocks, \@dependency_entry);

			$block = 1;
			last;
		    }
		}
		elsif ($$prog_instr[2] eq $l_reg || $$prog_instr[3] eq $l_reg) {
		    if ($$prog_instr[4] >= ($lu + $d_time)) {
			my @dependency_entry = ($instruction_counter, $time_slice, "IO", $$prog_instr[6]);
			push (@dependency_blocks, \@dependency_entry);

			$block = 1;
			last;
		    }
		}
		
	    }

	    if ($block == 0) {
		# no dependency, process instruction
		shift @instr_queue;
		$d_in_use++;

		my @progress = @$instr;

		my $load_time = $lu;

		push (@progress, $load_time);
		push (@progress, $d_time);
		push (@progress, $instruction_counter);

		my @output_entry = ($instruction_counter, $time_slice, $lu, $d_time);
		push(@output, \@output_entry);
		$instruction_counter++;

		push(@in_progress, \@progress);
	    }
	}
	else {
	    my @dependency_entry = ($instruction_counter, $time_slice, "D", -1);
	    push (@dependency_blocks, \@dependency_entry);
	}

	# process in-progress
	for (my $j = 0; $j < scalar @in_progress; $j++) {
	    my @cur_instr = @{$in_progress[$j]};
	    
	    if ($cur_instr[4] > 0) {
		$cur_instr[4]--;
	    }
	    else {
		$cur_instr[5]--;
	    }

	    $in_progress[$j] = \@cur_instr;

	    # instruction finished
	    if ($cur_instr[5] <= 0) {
		$d_in_use--;

		splice(@in_progress, $j, 1);
	    }
	}

	$time_slice++;
    }

    return (\@output, \@dependency_blocks);
}

sub display_HP {
    my $output_ref = shift;
    my $dep_blocks_ref = shift;

    my @output = @$output_ref;
    my @dep_blocks = @$dep_blocks_ref;

    my $col_max = 0;

    foreach my $instr (@output) {
	my $col_counter = 0;
	my $line = "S" . $$instr[0] . ":   ";
	
	for (my $i = $$instr[1]; $i > 0; $i--) {
	    $line = $line . "    ";
	    $col_counter++;
	}
	$line =~ s/\s$/|/g;

	$line  = $line . "IU |";
	$col_counter++;

	for (my $j = $$instr[2]-1; $j > 0; $j--) {
	    $line = $line . "   |";
	    $col_counter++;
	}

	$line = $line . " D |";
	$col_counter++;

	for (my $k = $$instr[3]-1; $k > 0; $k--) {
	    $line = $line . "   |";
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
	    $line = $line . " due to a lack of available D-units";
	}
	else {
	    $line = $line . " by a " . $dep_type . " dependency, caused by S" . $$dep_block[3];
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
