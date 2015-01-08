package POE::Component::WheelRun::Pool;

use strict;
use warnings;

use POE qw(
    Filter::Line
    Filter::Reference
    Wheel::Run
);

sub spawn {
    my $type = shift;

    # Arguments
    my %args = (
        Alias         => 'pool',
        PoolSize      => 4,
        ProgramArgs   => [],
        StdinFilter   => POE::Filter::Reference->new(),
        StdoutFilter  => POE::Filter::Line->new(),
        StderrFilter  => POE::Filter::Line->new(),
        WorkerError   => undef,
        WorkerClose   => undef,
        WorkerSpawn   => undef,
        StdoutHandler => undef,
        StderrHandler => undef,
        @_
    );

    # Validate the Program
    die "Must specify a Program argument as a coderef or path to a script."
        unless exists %args{Program};

    if(ref $args{Program} ne 'CODE') {
        if(!-x $args{Program}) {
            die "Program $args{Program} is not an executable.";
        }
    }

    my $session_id = POE::Session->create(
        inline_states => {
            # Internal
            _start              => \&pool_start,
            _stop               => \&pool_stop,
            # Interface
            dispatch            => \&pool_dispatch,
            # Worker Management
            worker_spawn        => \&worker_spawn,
            worker_chld         => \&worker_chld,
            worker_error        => \&worker_error,
            worker_close        => \&worker_close,
            worker_stdout       => \&worker_stdout,
            worker_stderr       => \&worker_stderr,
        },
        heap => {
            args           => \%args,
            workers        => 0,
            current_worker => 0,
        }
    );
}

sub pool_start {
    my ($kernel,$heap) = @_[KERNEL,HEAP];

    # Configure our alias
    $kernel->alias_set($heap->{args}{Alias});

    for ( 1 .. $heap->{args}{PoolSize} ) {
        $kernel->yield('worker_spawn');
    }
}

sub pool_stop {
    my ($kernel,$heap) = @_[KERNEL,HEAP];
}

sub pool_dispatch {
    my ($kernel,$heap) = @_[KERNEL,HEAP];
    my @args = @_[ARG0..$#_];
    # Count dispatches
    $heap->{stats}{dispatched} ||= 0;
    $heap->{stats}{dispatched} += $count;

    # Reset processor back to 0
    $heap->{current_worker} = 0 if $heap->{current_worker} >= scalar @{ $heap->{workers} };

    # Dispatch to the child
    my $wid = $heap->{workers}[$heap->{current_worker}];
    $heap->{_workers}{$wid}->put(@args);
    $heap->{current_worker}++;
}

sub worker_spawn {
    my($kernel,$heap,$dead_id) = @_[KERNEL,HEAP,ARG0];

    # Spawn the worker process
    my $worker = POE::Wheel::Run->new(
        Program      => $heap->{args}{Program},
        ProgramArgs  => $heap->{args}{ProgramArgs},
        CloseEvent   => 'worker_close',
        ErrorEvent   => 'worker_error',
        StdoutEvent  => 'worker_stdout',
        StderrEvent  => 'worker_stderr',
        StdinFilter  => $heap->{args}{StdinFilter},
        StdoutFilter => $heap->{args}{StdoutFilter},
        StderrFilter => $heap->{args}{StderrFilter},
    );
    if(!defined $worker) {
        $kernel->delay_add(worker_spawn => 5);
        return;
    }
    # Setup proper child reaping
    $kernel->sig_child($worker->PID, 'worker_chld');

    # Track Processors
    $heap->{_workers}{$worker->ID} = $worker;
    $heap->{_pid_to_worker}{$worker->PID} = $worker->ID;
    $heap->{workers} = [ sort { $a <=> $b } keys %{ $heap->{_workers} } ];
    $heap->{current_worker} = 0;

    # Assign affinity if we're able to
    my @cpus = ();
    eval {
        require Sys::CpuAffinity;

        $heap->{_max_cpu} ||= Sys::CpuAffinity::getNumCpus() - 1;
        die "no processor count established." unless $heap->{_max_cpu};

        # Assign Affinity
        for( 1..2 ) {
            $heap->{_cpu} = $heap->{_max_cpu} if $heap->{_cpu} < 0;
            push @cpus, $heap->{_cpu};
            $heap->{_cpu}--;
        }
        Sys::CpuAffinity::setAffinity($worker->PID, \@cpus);
    };
    if(my $err = $@) {
        # TODO: Log placeholder
    }

    # TODO: Log placeholder
    #INFO("proc_spawn_worker successfully spawned worker:" . $worker->ID . " (cpus:" . join(',', @cpus) . ")");
}
sub _remove_worker {
    my ($heap,$wid) = @_;

    return unless exists $heap->{_workers}{$wid};

    # Remove the Wheel from our HEAP
    delete $heap->{_workers}{$wid};
    $heap->{workers} = [ sort { $a <=> $b } keys %{ $heap->{_workers} } ];

    return 1;
}
sub worker_close {
    my ($kernel,$heap,$wid) = @_[KERNEL,HEAP,ARG0];

    # TODO: Log placeholder
    _remove_worker($heap,$wid);
}
sub worker_chld {
    my ($kernel,$heap,$pid,$status) = @_[KERNEL,HEAP,ARG1,ARG2];

    # TODO: INFO("SIGCHLD from PID:$pid, exit status was '$status'");
    my $wid = undef;
    if( ! exists $heap->{_pid_to_worker}{$pid} ) {
        # TODO: ERROR("SIGCHLD called on invalid PID:$pid, no reference in lookup table");
    }
    else {
        $wid = exists $heap->{_pid_to_worker}{$pid};
        _remove_wheel($heap,$wid);
        # TODO: INFO("reaped a worker:$wid , scheduling respawn");
    }
    $kernel->yield( spawn_worker => $wheel_id );
}
sub worker_error {
    my ($kernel, $heap, $op, $code, $wid, $handle) = @_[KERNEL, HEAP, ARG0, ARG1, ARG3, ARG4];
    if ($op eq 'read' and $code == 0 and $handle eq 'STDOUT') {
        _remove_worker($heap,$wid);
        # TODO: WARN("proc_error: worker_id = $wid closed STDOUT, respawning another worker");
    }
}
sub worker_stdout {
    my ($heap,@args) = @_[HEAP,ARG0..$#_];

    # TODO: DEBUG(sprintf "Stdout received:%d args", scalar(@args);
    if( defined $heap->{args}{StdoutHandler} && ref $heap->{args}{StdoutHandler} eq 'CODE' ) {
        eval {
            $heap->{args}{StdoutHandler}->(@args);
        };
        if(my $error = $@) {
            # TODO: DEBUG("ERROR received processing STDOUT: $error");
        }
    }
}
sub worker_stderr {
    my ($heap,@args) = @_[HEAP,ARG0..$#_];

    # TODO: DEBUG(sprintf "Stderr received:%d args", scalar(@args);
    if( defined $heap->{args}{StderrHandler} && ref $heap->{args}{StderrHandler} eq 'CODE' ) {
        eval {
            $heap->{args}{StderrHandler}->(@args);
        };
        if(my $error = $@) {
            # TODO: DEBUG("ERROR received processing STDERR $error");
        }
    }
    else {
        # TODO: WARN(sprintf "[UNHANDLED STDERR]:%s". join(',', map { chomp; } @args) );
    }
}

1;
