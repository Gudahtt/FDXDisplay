#!/usr/bin/perl

use strict;
use warnings;
use diagnostics;


sub parse_input {
    my $line = shift;    

    $line =~ m/\$(\d+?)\s?<-\s?([\*\+])\(\$(\d+?),\$(\d+?)\)/ms
        or die("Input could not be parsed. Must be of form 'R1<-D(R2,R3)', where D is * or +\n");

	my $input = {
		'R1' => $1,
		'Op' => $2,
		'R2' => $3,
		'R3' => $4
	};
	
    return $input;
}

sub parse_machine {
    my $M_fn = shift;

    open my $machine_file, '<', $M_fn
        or die("Can't open machine file");

    my @lines = <$machine_file>;
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
	
	my $machine = {
		'd_units' => $d_units,
		'global_registers' => $global_registers,
		'plus_time' => $plus_time,
		'mult_time' => $mult_time,
		'lu_time' => $lu_time
	};

    return $machine;
}

sub instruction_queue {
    my $P_fn = shift;
    my $global_registers = shift;

    open my $program, '<', $P_fn;
    my @queue;

    while (my $line = <$program>) {
		my $input = parse_input($line);
        
        if ($input->{'R1'} >= $global_registers || $input->{'R2'} >= $global_registers || $input->{'R3'} >= $global_registers) {
            die("Not enough registers");
        }

        push (@queue, $input);
    }

    return @queue;
}

sub run_program {
    my $P_fn = shift;
    my $M_fn = shift;
    
	my $machine = parse_machine($M_fn);

    my @instr_queue = instruction_queue($P_fn, $machine->{'global_registers'});
    
    # Queues used to keep track of program operation
    my @in_progress;
    my @output;
    my @dependency_blocks;
    
    # Keeps track of which components are in use
    my $d_in_use = 0;
    my $iu_in_use = 0;

    # These flags indicate that a component will be freed
    my $iu_freed = 0;
    my $d_freed = 0;

    # Keeps track of current 'time' (i.e. number of steps)
    my $time_slice = 0;

    # Incremented whenever an instruction is issued
    my $instruction_counter = 0;

    while (scalar @instr_queue > 0 || scalar @in_progress > 0) {
        # Process next instruction (if possible)
        # First check for iu availability
        if ($iu_in_use eq 0 && scalar @instr_queue > 0) {
            # Get next instruction (without removing from queue)
            my $instr = $instr_queue[0];

            # check for reg depedency
            my $block = 0;

            foreach my $prog_instr (@in_progress) {
                # read-after-write dependency
                if ($prog_instr->{'R1'} eq $instr->{'R2'} or $prog_instr->{'R1'} eq $instr->{'R3'}) {
                    my $dependency_entry = {
                        'num' => $instruction_counter,
                        'time' => $time_slice,
                        'type' => 'OI',
                        'conflicting_num' => $prog_instr->{'counter'}
                    };

                    push (@dependency_blocks, $dependency_entry);
                    
                    $block = 1;
                    last;
                }
                # write-after-write dependency
                elsif ($prog_instr->{'R1'} eq $instr->{'R1'}) {
                    my $dependency_entry = {
                        'num' => $instruction_counter,
                        'time' => $time_slice,
                        'type' => 'OO',
                        'conflicting_num' => $prog_instr->{'counter'}
                    };

                    push (@dependency_blocks, $dependency_entry);

                    $block = 1;
                    last;
                }
                # write-after-read dependency
                elsif ($prog_instr->{'R2'} eq $instr->{'R1'} || $prog_instr->{'R3'} eq $instr->{'R1'}) {
                    my $dependency_entry = {
                        'num' => $instruction_counter,
                        'time' => $time_slice,
                        'type' => 'IO',
                        'conflicting_num' => $prog_instr->{'counter'}
                    };

                    push (@dependency_blocks, $dependency_entry);

                    $block = 1;
                    last;
                }
            }
            
            # no dependency, process instruction
            if ($block == 0) {
                # Remove $instr from instruction queue
                shift @instr_queue;
                $iu_in_use = 1;

                # time to process operation
                my $d_time;
                if ($instr->{'Op'} eq '+') {
                    $d_time += $machine->{'plus_time'};
                }
                else {
                    $d_time += $machine->{'mult_time'};
                }

                # Gather process info, and add to process queue
                my $progress_entry = {
                    'R1' => $instr->{'R1'},
                    'Op' => $instr->{'Op'},
                    'R2' => $instr->{'R2'},
                    'R3' => $instr->{'R3'},
                    'lu_time' => $machine->{'lu_time'},
                    'd_time' => $d_time,
                    'counter' => $instruction_counter
                };

                push(@in_progress, $progress_entry);
                
                # Gather info for output, and add to output queue
                my $output_entry = {
                    'counter' => $instruction_counter,
                    'time_slice' => $time_slice,
                    'lu_time' => $machine->{'lu_time'},
                    'd_time' => $d_time,
                    'Op' => $instr->{'Op'}
                };
                
                push(@output, $output_entry);
                
                
                $instruction_counter++;
            }
        }

        # no IU-units available
        elsif (scalar @instr_queue > 0) {
            my $dependency_entry = {
                'num' => $instruction_counter,
                'time' => $time_slice,
                'type' => 'IU',
                'conflicting_num' => -1
            };

            push (@dependency_blocks, $dependency_entry);
        }

        # process in-progress
        my @to_be_removed;
        for (my $j = 0; $j < scalar @in_progress; $j++) {
            my $cur_instr = $in_progress[$j];
            
            # load_time
            if ($cur_instr->{'lu_time'} > 0) {
                $cur_instr->{'lu_time'}--;
                if ($cur_instr->{'lu_time'} eq 0) {
                    $iu_freed = 1;
                    $cur_instr->{'lu_time'} = -1; # indicates that d_time should start
                }
            }
            # d_time start
            elsif ($cur_instr->{'lu_time'} eq -1) {
                if ($d_in_use < $machine->{'d_units'}) {
                    $d_in_use++;
                    $cur_instr->{'d_time'}--;

                    $cur_instr->{'lu_time'} = 0; # set flag back to normal
                    
                    my $d_start_time = $time_slice;
                    my $found_entry = 0;
                    for ( my $output_entry = 0; $output_entry < scalar (@output); $output_entry++) {
                        # find current instruction to add d_start_time
                        if ($output[$output_entry]->{'counter'} eq $cur_instr->{'counter'}) {
                            $output[$output_entry]->{'d_start_time'} = $d_start_time;
                            $found_entry = 1;
                            last;
                        }
                    }
                }
                # no d-units available
                else {
                    my $dependency_entry = {
                        'num' => $cur_instr->{'counter'},
                        'time' => $time_slice,
                        'type' => 'D',
                        'conflicting_num' => -1
                    };
                    
                    push (@dependency_blocks, $dependency_entry);
                }
            }
            # d_time
            else {
                $cur_instr->{'d_time'}--;
            }

            $in_progress[$j] = $cur_instr;

            # instruction finished
            if ($cur_instr->{'d_time'} <= 0) {
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
        my $col_counter = 0;
        my $line = "S" . $instr->{'counter'} . ":   ";
        
        for (my $i = $instr->{'time_slice'}; $i > 0; $i--) {
            $line .= "    ";
            $col_counter++;
        }
        $line =~ s/\s$/|/g;

        $line  .= "IU |";
        $col_counter++;

        for (my $j = $instr->{'lu_time'}-1; $j > 0; $j--) {
            $line .= "IU |";
            $col_counter++;
        }

        if (defined $instr->{'d_start_time'}) {
            # find 'waiting for d-unit' time
            for ( my $t = $instr->{'d_start_time'} - ($instr->{'time_slice'} + $instr->{'lu_time'}); $t > 0; $t--) {
                $line .= " - |";
                $col_counter++;
            }
        }

        $line = $line . " " . $instr->{'Op'} . " |";
        $col_counter++;

        for (my $k = $instr->{'d_time'}-1; $k > 0; $k--) {
            $line = $line . " " . $instr->{'Op'} . " |";
            $col_counter++;
        }

        print $line;
        print "\n";

        if ($col_counter > $col_max) {
            $col_max = $col_counter;
        }
    }

    my $dividing_line = "------";
    for (my $i = 0; $i < $col_max; $i++) {
        $dividing_line .= "----";
    }
    $dividing_line .= "\n";
    print $dividing_line;

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
        my $line = "S" . $dep_block->{'num'} . " was blocked at time=" . $dep_block->{'time'};

        if ($dep_block->{'type'} eq "D") {
            $line .= " due to a lack of available D-units";
        }
        elsif ($dep_block->{'type'} eq "IU") {
            $line .= " due to a lack of available IU units";
        }
        else {
            $line .= " by a " . $dep_block->{'type'} . " dependency, caused by S" . $dep_block->{'conflicting_num'};
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

