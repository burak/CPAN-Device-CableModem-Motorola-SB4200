package Device::CableModem::Motorola::SB4200;
use strict;
use warnings;
use constant DEFAULT_IP => '192.168.100.1';
use LWP::UserAgent;
use HTML::TableParser;
use HTML::Form;
use Data::Dumper;
use Exception::Class (
    'HTTP::Error',
    'HTTP::Error::NotFound' => {
        isa         => 'HTTP::Error',
        description => 'The content not found on the machine',
    },
    'HTTP::Error::Connection' => {
        isa         => 'HTTP::Error',
        description => 'Unable to get a result from the server',
    },
);
use Carp qw( croak );

our $VERSION = '0.10';
my  $AGENT   = sprintf "%s/%s", __PACKAGE__, $VERSION;

sub new {
    my $class = shift;
    my %opt   = @_ % 2 ? () : @_;
    my %page  = (
        status => 'startupdata.html',
        signal => 'signaldata.html',
        addr   => 'addressdata.html',
        conf   => 'configdata.html',
        logs   => 'logsdata.html',
        help   => 'mainhelpdata.html',
    );
    %opt = (
        ip => DEFAULT_IP,
        %opt,
    );
    $opt{base_url} = sprintf 'http://%s/', $opt{ip};
    foreach my $name ( keys %page ) {
        $opt{ 'page_' . $name } = $opt{base_url} . $page{ $name };
    }
    my $self = bless { %opt }, $class;
    return $self;
}

sub restart {
    my $self = shift;
    my $raw   = $self->_get( $self->{page_conf} );
    my $form  = HTML::Form->parse( $raw, $self->{page_conf} );

    foreach my $e ( $form->inputs ) {
        next if $e->type ne 'submit';
        if ( $e->value =~ m{Restart Cable Modem}si ) {
            my $req = $e->click( $form ) || croak "Restart failed";
            $req->uri( $self->{page_conf} );
            my $response = $self->_req( $req );
            return;
        }
    }

    croak "Restart failed: the required button can not be found";
}

sub reset {
    my $self = shift;
    my $raw   = $self->_get( $self->{page_conf} );
    my $form  = HTML::Form->parse( $raw, $self->{page_conf} );

    foreach my $e ( $form->inputs ) {
        next if $e->type ne 'submit';
        if ( $e->value =~ m{Reset All Defaults}si ) {
            my $req = $e->click( $form ) || croak "Reset failed";
            $req->uri( $self->{page_conf} );
            my $response = $self->_req( $req );
            return;
        }
    }

    croak "Reset failed: the required button can not be found";
}
sub config {
    my $self  = shift;
    my $raw   = $self->_get( $self->{page_conf} );
    my $form  = HTML::Form->parse( $raw, $self->{page_conf} );
    my %rv;
    foreach my $e ( $form->inputs ) {
        next if $e->type eq 'submit';
        $rv{ $e->name } = $e->value;
    }
    return %rv;
}

sub set_config {
    my $self  = shift;
    my $name  = shift || croak "Config name not present";
    my $value = shift;
    croak "Config value not present" if not defined $value;
    my $raw   = $self->_get( $self->{page_conf} );
    my $form  = HTML::Form->parse( $raw, $self->{page_conf} );

    my $input;
    my @inputs = $form->inputs;
    foreach my $e ( @inputs ) {
        next if $e->type eq 'submit';
        next if $e->name ne $name;
        if ( my @possible = $e->possible_values ) {
            my %valid = map { (defined $_ ? $_ : 0), 1 } @possible;
            if ( ! $valid{ $value } ) {
                croak "The value ($value) for $name is not valid. "
                     ."You should select one of  these: " . join(' ',keys %valid);
            }
        }
        $input = $e;
        last;
    }
    croak "$name is not a valid configuration option" if ! $input;
    # good to go
    $input->value($value);
    my $req = $form->click() || croak "Saving $name=$value failed";
    $req->uri( $self->{page_conf} );
    my $response = $self->_req( $req );
    return;
}

sub addresses {
    my $self = shift;
    my $raw  = $self->_get( $self->{page_addr} );

    my(%list, @mac);

    my $list = sub {
        my ( $id, $line, $cols, $udata ) = @_;
        (my $name = lc $cols->[0]) =~ tr/ /_/d;
        $list{ $name } = $cols->[1];
        return;
    };

    my $mac = sub {
        my ( $id, $line, $cols, $udata ) = @_;
        my($num, $addr, $status) = @{ $cols };
        push @mac, { address => $addr, status => $status };
        return;
    };

    HTML::TableParser->new(
        [
            { id => 1.4, row  => $list },
            { id => 1.5, row  => $mac  },
        ],
        { Decode => 1, Trim => 1, Chomp => 1 }
    )->parse( $raw );

    my $di = $list{dhcp_information};
    $list{dhcp_information} = {};
    foreach my $info ( split m{ \r?\n }xmsi, $di ) {
        my($name, $value) = split m{ : \s+ }xms, $info;
        my($num, $type, $other) = split m{\s+}xms, $value;
        my $has_type = defined $num && defined $type && ! defined $other;
        $list{dhcp_information}->{ $name } = $has_type ? { value => $num, type => $type } : { value => $value };
    }
    
    my %rv = (
        %list,
        known_cpe_mac_addresses => [ @mac ],
    );

    return %rv;
}

sub signal {
    my $self = shift;
    my $raw  = $self->_get( $self->{page_signal} );

    # remove junk info, otherwise it will not be parsed correctly
    $raw =~ s{
        <table \s+ WIDTH="300" .+? >
            .+?
            \QThe Downstream Power Level reading is\E
            .+?
        </table>
    }{}xmsi;

    my(%down, %up);

    my $down_row = sub {
        my ( $id, $line, $cols, $udata ) = @_;
        (my $name = lc $cols->[0]) =~ tr/ /_/d;
        $down{ $name } = $cols->[1];
        return;
    };

    my $up_row = sub {
        my ( $id, $line, $cols, $udata ) = @_;
        (my $name = lc $cols->[0]) =~ tr/ /_/d;
        $up{ $name } = $cols->[1];
        return;
    };

    HTML::TableParser->new(
        [
            { id => 1.4, row  => $down_row          },
            { id => 1.5, row  => $up_row          },
        ],
        { Decode => 1, Trim => 1, Chomp => 1 }
    )->parse( $raw );

    foreach my $v (
        \@up{   qw( frequency power_level symbol_rate           ) },
        \@down{ qw( frequency power_level signal_to_noise_ratio ) },
    ) {
        my($value, $unit, $status) = split m{\s+}xms, $$v;
        $$v = {
            value  => $value,
            unit   => $unit,
        };
        $$v->{status} = $status if defined $status;
    }

    my %rv = (
        upstream   => { %up },
        downstream => { %down },
    );

    return %rv;
}

sub status {
    my $self = shift;
    my $raw  = $self->_get( $self->{page_status} );
    my %rv;

    my $cb_row = sub {
        my ( $id, $line, $cols, $udata ) = @_;
        (my $name = lc $cols->[0]) =~ tr/ /_/d;
        $rv{ $name } = $cols->[1];
        return;
    };

    HTML::TableParser->new(
        [
            { id => 1.4, row  => $cb_row                 },
            { id => 1  , cols => qr/(?:Task|Status)/xmsi },
        ],
        { Decode => 1, Trim => 1, Chomp => 1 }
    )->parse( $raw );

    return %rv;
}

sub logs {
    my $self = shift;
    my $raw  = $self->_get( $self->{page_logs} );
    my @logs;

    my $cb_row = sub {
        my ( $id, $line, $cols, $udata ) = @_;
        push @logs, {
            time     => shift @{ $cols },
            priority => shift @{ $cols },
            code     => shift @{ $cols },
            message  => shift @{ $cols },
        };
        my $cur = $logs[-1];
        my($pn,$ps) = split m/\-/xms, $cur->{priority};
        $cur->{priority} = {
            code   => $pn,
            string => $ps,
        };
        $cur->{time} = undef if $cur->{time} eq '************';
        return;
    };

    HTML::TableParser->new(
        [
            { id => 1.4, row  => $cb_row                                },
            { id => 1  , cols => qr/(?:Time|Priority|Code|Message)/xmsi },
        ],
        { Decode => 1, Trim => 1, Chomp => 1 }
    )->parse( $raw );

    return @logs;
}

sub versions {
    my $self = shift;
    my $raw  = $self->_get( $self->{page_help} );
    croak "Can not get version from $self->{page_help} output: $raw"
        if $raw !~ m{<td.+?>(.+?version.+?)</td>}xmsi;
    (my $v = $1) =~ s{<br>}{}xmsig;
    my %rv;
    foreach my $vs ( split m/ \r? \n /xms, $self->_trim( $v ) ) {
        my($name, $value) = split m/ : \s+ /xms, $vs;
          ($name, undef)  = split m/   \s+ /xms, $name;
        $rv{ lc $name }   = $value;
    }
    my @soft = split m/ \- /xms, $rv{software};
    $rv{software} = {
        model   => shift @soft,
        version => shift @soft,
        string  => join('-', @soft),
    };
    return %rv;
}

sub _trim {
    my $self = shift;
    my $s = shift;
    $s =~ s{ \A \s+    }{}xmsg;
    $s =~ s{    \s+ \z }{}xmsg;
    return $s;
}

sub agent {
    my $self = shift;
    my $ua   = LWP::UserAgent->new;
    $ua->agent($AGENT);
    $ua->timeout(5);
    return $ua;
}

sub _get {
    my $self = shift;
    my $url  = shift;
    my $r    = $self->agent->get($url);

    if ( $r->is_success ) {
        my $raw = $r->decoded_content;
        if ( $raw =~ m{<title> File \s Not \s Found </title>}xmsi ) {
            HTTP::Error::NotFound->throw(
                "The address $url is invalid. Server returned a 404 error"
            );
        }
        return $raw;
    }

    HTTP::Error::Connection->throw("GET request failed: ". $r->as_string);
}

sub _req {
    my $self = shift;
    my $req  = shift;
    my $r    = $self->agent->request($req);

    if ( $r->is_success ) {
        my $raw = $r->decoded_content;
        if ( $raw =~ m{<title> File \s Not \s Found </title>}xmsi ) {
            HTTP::Error::NotFound->throw(
                "The request is invalid. Server returned a 404 error"
            );
        }
        return $raw;
    }

    HTTP::Error::Connection->throw("HTTP::Request failed: ". $r->as_string);
}

1;

__END__

=head1 NAME

Device::CableModem::Motorola::SB4200 - Interface to Motorola SurfBoard 4200 Cable Modem

=head1 SYNOPSIS

   use Device::CableModem::Motorola::SB4200;
   
   my $m = Device::CableModem::Motorola::SB4200->new(%opts);
   
   my %version = $m->versions;
   my %status  = $m->status;
   my %signal  = $m->signal;
   my %addr    = $m->addresses;
   my %config  = $m->config;
   my @logs    = $m->logs;
   
   $m->restart;
   $m->reset;
   
   my $fw = $version{software};
   printf "Firmware version is %s-%s\n", $fw->{version}, $fw->{string};
   die "Unknown device disguised as SB4200" if $fw->{model} ne 'SB4200';

=head1 DESCRIPTION

This module can be used to manage/fetch every setting available via the modem's
web interface. It is also possible to restart/reset the modem.

All methods will die upon failure.

=head1 GENERAL METHODS

=head2 new

Contructor. Accepts named parameters listed below.

=head3 ip

Highly unlikely, but if the ip address of SB4200 is not C<192.168.100.1>,
then you can set the ip address with this parameter.

=head2 agent

Returns a C<LWP::UserAgent> object.

=head1 INFORMATION METHODS

Use L<Data::Dumper> to see the outputs of these methods.

=head2 addresses

Provides information about the servers the Cable Modem is using,
and the computers to which it is connected.

=head2 config

Provides information about the manually configurable settings of the
Cable Modem.

=head2 logs

Returns a list of available modem logs.

=head2 signal

Provides information about the current upstream and downstream signal status
of the Cable Modem.

=head2 status

Provides information about the startup process of the Cable Modem.

=head2 versions

Returns a list of hardware/software versions available in the modem.

=head1 MODIFICATION METHODS

=head2 reset

From the modem page:

   Resetting the cable modem to its factory default configuration will remove
   all stored parameters learned by the cable modem during prior
   initializations. The process to get back online from a factory default
   condition could take from 5 to 30 minutes. Please reference the cable
   modem User Guide for details on the power up sequence.

=head2 restart

Restarts the modem. Usually takes 10 seconds.

=head2 set_config

Can be used to alter every setting available via L</config>.

   $m->set_config( FREQ_PLAN     => "EUROPE"  );
   $m->set_config( FREQUENCY_MHZ => 543000001 );

=head1 SEE ALSO

L<Device::CableModem::SURFboard>.

=head1 AUTHOR

Burak GE<252>rsoy, E<lt>burakE<64>cpan.orgE<gt>

=head1 COPYRIGHT

Copyright 2009 Burak GE<252>rsoy. All rights reserved.

=head1 LICENSE

This library is free software; you can redistribute it and/or modify 
it under the same terms as Perl itself, either Perl version 5.8.8 or, 
at your option, any later version of Perl 5 you may have available.

=cut
