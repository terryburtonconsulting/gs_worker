package Starman::Server::Watchdog;

#
# Starman::Server subclass that monitors worker processing times
# and kills workers that exceed a configurable timeout.
#
# Copyright (c) 2026 Terry Burton
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
#

use strict;
use warnings;
use parent 'Starman::Server';
use Time::HiRes qw(time);
use IO::Select;

our $VERSION = '1.0';

our $REQUEST_TIMEOUT = $ENV{REQUEST_TIMEOUT} || 5;  # seconds
our $DEBUG = $ENV{WATCHDOG_DEBUG} || 0;
our %processing_since;

# Override process_request to report "waiting" status before the keepalive
# idle wait, so the watchdog doesn't kill workers that are merely idle
# between keepalive requests.
sub process_request {
    my $self = shift;

    # Monkey-patch IO::Select::can_read for this connection to report
    # "waiting" to the parent before blocking, and "processing" after
    my $write = $self->{server}->{_WRITE};
    my $orig_can_read = \&IO::Select::can_read;
    local *IO::Select::can_read = sub {
        my ($sel, $timeout) = @_;
        # Only intercept keepalive waits (timeout > read_timeout)
        if ($timeout && $timeout > 10) {
            print $write "$$ waiting\n" if $write;
            my $ready = $orig_can_read->($sel, $timeout);
            print $write "$$ processing\n" if $write && $ready;
            return $ready;
        }
        return $orig_can_read->(@_);
    };

    $self->SUPER::process_request(@_);
}

# Called in parent when reading status updates from children
# Line format: "$pid $status\n" where status is waiting|processing|dequeue|exiting
sub parent_read_hook {
    my ($self, $line) = @_;

    if ($line =~ /^(\d+)\s+(waiting|processing|dequeue|exiting)$/) {
        my ($pid, $status) = ($1, $2);
        if ($status eq 'processing') {
            $processing_since{$pid} = time();
            warn "[WATCHDOG] Worker $pid started processing\n" if $DEBUG;
        } else {
            if ($DEBUG && exists $processing_since{$pid}) {
                my $elapsed = time() - $processing_since{$pid};
                warn "[WATCHDOG] Worker $pid finished ($status) after ${elapsed}s\n";
            }
            delete $processing_since{$pid};
        }
    }

    return 0;  # Don't stop processing
}

# Called periodically in parent (every check_for_waiting seconds)
sub idle_loop_hook {
    my ($self, $fh) = @_;
    my $now = time();

    for my $pid (keys %processing_since) {
        my $elapsed = $now - $processing_since{$pid};
        if ($elapsed > $REQUEST_TIMEOUT) {
            warn "[WATCHDOG] Killing stuck worker $pid (processing for ${elapsed}s > ${REQUEST_TIMEOUT}s)\n";
            kill 'TERM', $pid;
            sleep 1;
            if (kill(0, $pid)) {
                warn "[WATCHDOG] Worker $pid still alive, sending KILL\n";
                kill 'KILL', $pid;
            }
            delete $processing_since{$pid};
        }
    }
}

# Called when a child process dies
sub cleanup_dead_child_hook {
    my ($self, $pid) = @_;
    delete $processing_since{$pid};
}

1;

__END__

=head1 NAME

Starman::Server::Watchdog - Starman server with worker timeout monitoring

=head1 SYNOPSIS

    # In app.psgi or startup script
    use Starman::Server::Watchdog;

    # Set timeout via environment variable (default 5 seconds)
    # REQUEST_TIMEOUT=5

    # Run with: plackup -s Starman::Server::Watchdog app.psgi

=head1 DESCRIPTION

This module extends Starman::Server to monitor worker processing times
and kill workers that exceed a configurable timeout. This protects against
infinite loops or extremely slow operations that could exhaust server resources.

Workers in keepalive idle wait are reported as "waiting" to the parent
process so they are not mistakenly killed by the watchdog. The watchdog
only times requests that are actively being processed.

=head1 CONFIGURATION

=over 4

=item REQUEST_TIMEOUT

Environment variable to set the maximum allowed processing time in seconds.
Default is 5 seconds.

=item WATCHDOG_DEBUG

Set to 1 to enable verbose watchdog logging.

=back

=head1 LICENSE

MIT License

=cut
