package POE::Component::Server::AsyncEndpoint::ChannelAdapter::SOAP;


use warnings;
use strict;
our @EXPORT = ( );
use Switch;

use Carp qw(croak);
use POE;
use base qw(Exporter);
use vars qw($VERSION);
$VERSION = '0.01';

use SOAP::Lite;

sub spawn{

    my $class = shift;
    my $args  = shift;

    # setup arguments
    my $proxy = undef;
    my $service = undef;
    if ( ref($args) eq 'HASH' ){
        $proxy  = $args->{proxy};
        $service  = $args->{service};
    }

    croak "CAERROR||Cannot init SOAP Client without valid proxy and service!"
        unless ($proxy && $service);


    my $soap = SOAP::Lite->new(
        proxy => $proxy,
        service => $service,
    );

    return $soap;

}


1;


__END__

=head1 NAME

package POE::Component::Server::AsyncEndpoint::ChannelAdapter::SOAP;

=head1 SYNOPSIS

When you init your Endpoint:

        my $soc = POE::Component::Server::AsyncEndpoint::ChannelAdapter::SOAP->spawn({
            proxy   => $self->{config}->soap_proxy,
            service => $self->{config}->soap_service,
        });

        # $self->{config}->soap_proxy is defined in your config file
        # and usually has something like: 'http://yourserver.yourdomain/webservices.php'

        # $self->{config}->soap_service is defined in your config file
        # and usually has something like: 'http://yourserver.yourdomain/soapservices.wsdl'

Later in your Endpoint:

        # make a SOAP call as if it were local
        my $call = $soc->yourSOAPCall(
            $self->{config}->socuser,
            $self->{config}->socpass
        );

        unless ( $call->fault ) {

        ...


=head1 DESCRIPTION

At the moment, this class is basically a wrapper around SOAP::Lite
and should eventually simplify you interaction with SOAP in future
versions.

=head2 Methods


=over 4

=item spawn

This sole method requires two parameters: B<proxy>, which should contain
a valid URL to your SOAP server, and B<service>, which should point to a
URL where the WSDL file can be fetched.

=head1 SEE ALSO

L<SOAP::Lite>

L<POE::Component::Server::AsyncEndpoint::ChannelAdapter::Stomp>
L<POE::Component::Server::AsyncEndpoint::ChannelAdapter::Config>

L<POE::Component::Server::AsyncEndpoint>
L<POE>

=head1 AUTHOR

Alejandro Imass <ait@p2ee.org>
Alejandro Imass <aimass@corcaribe.com>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2008 by Alejandro Imass / Corcaribe Tecnología C.A. for the P2EE Project

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.8 or,
at your option, any later version of Perl 5 you may have available.

=cut
