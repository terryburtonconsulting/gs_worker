package Plack::Handler::WatchdogStarman;

#
# Plack handler wrapper for Starman::Server::Watchdog
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
use Starman::Server::Watchdog;

sub new {
    my ($class, %args) = @_;
    bless { %args }, $class;
}

sub run {
    my ($self, $app) = @_;
    Starman::Server::Watchdog->new->run($app, $self);
}

1;

__END__

=head1 NAME

Plack::Handler::WatchdogStarman - Plack handler for Starman with watchdog monitoring

=head1 SYNOPSIS

    plackup -s WatchdogStarman -I lib --port 3000 app.psgi

=head1 DESCRIPTION

This handler allows using Starman::Server::Watchdog via plackup's -s option.

=head1 LICENSE

MIT License

=cut
